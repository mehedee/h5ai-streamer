#include "LoopbackStream.hpp"
#include <libtorrent/magnet_uri.hpp>
#include <libtorrent/read_resume_data.hpp>
#include <libtorrent/write_resume_data.hpp>
#include <libtorrent/settings_pack.hpp>
#include <libtorrent/torrent_status.hpp>
#include <boost/property_tree/ptree.hpp>
#include <boost/property_tree/json_parser.hpp>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <sstream>
#include <queue>
namespace lt = libtorrent;
using namespace std::chrono_literals;

static std::mutex outputMutex;
static std::string quote(const std::string& value) {
  std::string result = "\"";
  const char* hex = "0123456789abcdef";
  for (unsigned char c : value) {
    if (c == '"' || c == '\\') { result += '\\'; result += c; }
    else if (c < 32) { result += "\\u00"; result += hex[c >> 4]; result += hex[c & 15]; }
    else result += c;
  }
  return result + "\"";
}
static void emit(const std::string& value) {
  std::lock_guard<std::mutex> lock(outputMutex);
  std::cout << value << '\n' << std::flush;
}
static std::vector<char> readFile(const std::filesystem::path& path) {
  if (!std::filesystem::is_regular_file(path) || std::filesystem::is_symlink(path)
      || std::filesystem::file_size(path) > 16 * 1024 * 1024) throw std::runtime_error("Invalid torrent state file.");
  std::ifstream file(path, std::ios::binary);
  if (!file) throw std::runtime_error("Torrent state file is unreadable.");
  return std::vector<char>(std::istreambuf_iterator<char>(file), {});
}
static std::string identity(const lt::info_hash_t& hashes) {
  auto hex = [](const char* bytes, int size) {
    static const char* alphabet = "0123456789abcdef";
    std::string result;
    for (int n = 0; n < size; ++n) { auto c = static_cast<unsigned char>(bytes[n]); result += alphabet[c >> 4]; result += alphabet[c & 15]; }
    return result;
  };
  if (hashes.has_v1()) return "btih-" + hex(hashes.v1.data(), 20);
  if (hashes.has_v2()) return "btmh-" + hex(hashes.v2.data(), 32);
  throw std::runtime_error("Torrent identity is missing.");
}
static bool safePath(const std::string& path) {
  if (path.empty() || path.size() > 4096 || path.front() == '/' || path.find('\\') != std::string::npos) return false;
  for (unsigned char c : path) if (c < 32 || c == 127) return false;
  std::stringstream parts(path);
  std::string part;
  while (std::getline(parts, part, '/')) if (part.empty() || part == "." || part == "..") return false;
  return path.back() != '/';
}
static bool isKnownMacOSPathAlias(const std::filesystem::path& requested,
  const std::filesystem::path& canonical) {
  const auto value = requested.generic_string();
  const auto target = canonical.generic_string();
  for (const std::string prefix : {"/tmp", "/var"}) {
    if ((value == prefix || value.rfind(prefix + "/", 0) == 0)
        && target == "/private" + value) return true;
  }
  return false;
}
static std::string mime(const std::string& path) {
  auto extension = std::filesystem::path(path).extension().string();
  std::transform(extension.begin(), extension.end(), extension.begin(), [](unsigned char c) { return std::tolower(c); });
  if (extension == ".mp4" || extension == ".m4v") return "video/mp4";
  if (extension == ".mkv") return "video/x-matroska";
  if (extension == ".webm") return "video/webm";
  if (extension == ".avi") return "video/x-msvideo";
  if (extension == ".mov") return "video/quicktime";
  if (extension == ".ts" || extension == ".m2ts") return "video/mp2t";
  if (extension == ".mpg" || extension == ".mpeg" || extension == ".vob") return "video/mpeg";
  if (extension == ".wmv" || extension == ".flv" || extension == ".ogv") return "application/octet-stream";
  return "";
}
static std::map<int, myra::StreamFile> metadata(const lt::torrent_info& info) {
  const auto& files = info.files();
  if (files.num_files() > 4096 || info.piece_length() > 16 * 1024 * 1024) throw std::runtime_error("Torrent metadata exceeds supported limits.");
  std::string payload = "{\"event\":\"metadata\",\"identity\":" + quote(identity(info.info_hashes()))
    + ",\"name\":" + quote(info.name()) + ",\"files\":[";
  bool first = true;
  std::map<int, myra::StreamFile> videos;
  for (int n = 0; n < files.num_files(); ++n) {
    auto index = lt::file_index_t(n);
    auto path = files.file_path(index);
    if (!safePath(path) || bool(files.file_flags(index) & lt::file_storage::flag_symlink)) throw std::runtime_error("Unsafe torrent file path or symbolic link.");
    if (files.pad_file_at(index)) continue;
    auto type = mime(path);
    if (type.empty() || files.file_size(index) <= 0) continue;
    if (!first) payload += ',';
    first = false;
    payload += "{\"index\":" + std::to_string(n) + ",\"path\":" + quote(path)
      + ",\"size\":" + std::to_string(files.file_size(index)) + ",\"isSymlink\":false}";
    videos.emplace(n, myra::StreamFile{n, files.file_offset(index), files.file_size(index), type, std::filesystem::path(path).extension().string()});
  }
  if (videos.empty()) throw std::runtime_error("This torrent has no supported video files.");
  emit(payload + "]}");
  return videos;
}
static lt::add_torrent_params source(const std::string& input) {
  lt::error_code error;
  lt::add_torrent_params parameters;
  if (input.rfind("magnet:", 0) == 0) parameters = lt::parse_magnet_uri(input, error);
  else {
    auto bytes = readFile(input);
    parameters.ti = std::make_shared<lt::torrent_info>(lt::span<const char>(bytes.data(), bytes.size()), lt::from_span);
    parameters.info_hashes = parameters.ti->info_hashes();
  }
  if (error) throw std::runtime_error("Invalid magnet or torrent metadata.");
  return parameters;
}
int main(int argc, char** argv) {
  try {
    if (argc == 3 && std::string(argv[1]) == "inspect") {
      auto parameters = source(argv[2]);
      if (!parameters.ti) throw std::runtime_error("Inspect requires a torrent file.");
      metadata(*parameters.ti); return 0;
    }
    if (argc < 5 || std::string(argv[1]) != "run") throw std::runtime_error("Invalid engine invocation.");
    std::filesystem::path root(argv[3]), resumePath(argv[4]);
    if (!root.is_absolute()) throw std::runtime_error("Cache root must be absolute.");
    if (!std::filesystem::is_directory(root)) throw std::runtime_error("Cache root is not a directory.");
    const auto canonicalRoot = std::filesystem::canonical(root);
    if (canonicalRoot != root && !isKnownMacOSPathAlias(root, canonicalRoot)) {
      throw std::runtime_error("Cache root is not canonical: " + root.string() + " != " + canonicalRoot.string());
    }
    if (resumePath.filename() != "resume.dat"
        || std::filesystem::canonical(resumePath.parent_path()) != canonicalRoot) {
      throw std::runtime_error("Resume file is outside cache root: " + resumePath.parent_path().string() + " != " + root.string());
    }
    root = canonicalRoot;
    resumePath = root / "resume.dat";
    for (const auto& file : std::filesystem::recursive_directory_iterator(root))
      if (file.is_symlink()) throw std::runtime_error("Symbolic link in torrent cache.");
    auto parameters = source(argv[2]);
    const auto expectedIdentity = identity(parameters.info_hashes);
    if (std::filesystem::exists(resumePath)) {
      lt::error_code error;
      auto bytes = readFile(resumePath);
      auto saved = lt::read_resume_data(bytes, error);
      if (!error && identity(saved.info_hashes) == expectedIdentity) {
        // Never trust persisted renames or save paths to choose a write destination.
        saved.renamed_files.clear();
        if (parameters.ti) saved.ti = parameters.ti;
        parameters = std::move(saved);
      }
    }
    parameters.save_path = root.string();
    parameters.flags &= ~(lt::torrent_flags::paused | lt::torrent_flags::auto_managed | lt::torrent_flags::seed_mode);
    parameters.flags |= lt::torrent_flags::default_dont_download;
    if (parameters.ti) parameters.file_priorities.assign(parameters.ti->num_files(), lt::dont_download);
    lt::settings_pack settings;
    const bool loopback = argc >= 6 && std::string(argv[5]) == "loopback";
    settings.set_str(lt::settings_pack::listen_interfaces, loopback ? "127.0.0.1:0" : "0.0.0.0:0");
    if (loopback) settings.set_str(lt::settings_pack::outgoing_interfaces, "127.0.0.1");
    settings.set_bool(lt::settings_pack::enable_dht, !loopback);
    settings.set_bool(lt::settings_pack::enable_lsd, false);
    settings.set_bool(lt::settings_pack::enable_upnp, false);
    settings.set_bool(lt::settings_pack::enable_natpmp, false);
    settings.set_int(lt::settings_pack::min_reconnect_time, 3);
    settings.set_int(lt::settings_pack::connections_limit, 80);
    settings.set_int(lt::settings_pack::alert_mask, static_cast<int>(static_cast<std::uint32_t>(lt::alert_category::error | lt::alert_category::status | lt::alert_category::storage)));
    lt::session session(settings);
    auto handle = session.add_torrent(parameters);
    if (loopback && argc >= 7) handle.connect_peer({lt::make_address("127.0.0.1"), static_cast<unsigned short>(std::stoi(argv[6]))});
    std::atomic<bool> quit{false};
    std::mutex commandMutex;
    std::queue<std::string> commands;
    std::thread input([&] {
      std::string line;
      char byte;
      while (std::cin.get(byte)) {
        if (byte == '\n') { std::lock_guard<std::mutex> lock(commandMutex); if (commands.size() < 64) commands.push(line); line.clear(); }
        else if (line.size() < 8192) line += byte;
        else { quit = true; return; }
      }
      quit = true;
    });
    // The app owns stdin. EOF requests graceful teardown; it never waits for a detached daemon.
    std::unique_ptr<myra::VerifiedPieceBroker> broker;
    std::unique_ptr<myra::LoopbackStream> stream;
    std::map<int, myra::StreamFile> videos;
    bool seed = false, completeNotice = false;
    int selected = -1;
    int requestedSelection = -1;
    auto lastStatus = std::chrono::steady_clock::now();
    auto lastSave = lastStatus;
    std::atomic<bool> saveComplete{false};
    auto alert = [&](lt::alert* value) {
      if (auto* saved = lt::alert_cast<lt::save_resume_data_alert>(value)) {
        auto bytes = lt::write_resume_data_buf(saved->params);
        const auto temporary = resumePath.string() + ".tmp";
        std::ofstream output(temporary, std::ios::binary | std::ios::trunc);
        output.write(bytes.data(), bytes.size()); output.close();
        if (output) { std::filesystem::rename(temporary, resumePath); saveComplete = true; }
      }
      if (lt::alert_cast<lt::torrent_error_alert>(value)) emit("{\"event\":\"error\",\"message\":\"The torrent engine encountered a storage or network error.\"}");
    };
    try {
      while (!quit) {
        if (!broker && handle.status().has_metadata) {
          auto info = handle.torrent_file();
          if (identity(info->info_hashes()) != expectedIdentity) throw std::runtime_error("Metadata identity mismatch.");
          videos = metadata(*info);
          handle.prioritize_files(std::vector<lt::download_priority_t>(info->num_files(), lt::dont_download));
          broker = std::make_unique<myra::VerifiedPieceBroker>(session, handle, alert);
          stream = std::make_unique<myra::LoopbackStream>(*broker, info->piece_length(), videos);
        }
        if (!broker) { std::vector<lt::alert*> alerts; session.pop_alerts(&alerts); for (auto* value : alerts) alert(value); }
        std::queue<std::string> pending;
        { std::lock_guard<std::mutex> lock(commandMutex); pending.swap(commands); }
        while (!pending.empty()) {
          boost::property_tree::ptree command;
          std::istringstream json(pending.front()); pending.pop();
          boost::property_tree::read_json(json, command);
          const auto operation = command.get<std::string>("op");
          if (operation == "stop") { quit = true; break; }
          if (operation == "pause") handle.pause();
          else if (operation == "resume") handle.resume();
          else if (operation == "preferences") {
            seed = command.get<bool>("seed");
            int upload = command.get<int>("uploadKB");
            if (upload < 0 || upload > 1000000) throw std::runtime_error("Invalid upload limit.");
            handle.set_upload_limit(upload * 1024);
            if (completeNotice) { if (seed) handle.resume(); else handle.pause(); }
          } else if (operation == "select") {
            int index = command.get<int>("index");
            if (index < 0) throw std::runtime_error("Invalid video selection.");
            requestedSelection = index;
          } else if (operation == "deselect" && stream) stream->deselect();
        }
        if (requestedSelection >= 0 && stream) {
          if (!videos.count(requestedSelection)) throw std::runtime_error("Unknown video selection.");
          selected = requestedSelection; requestedSelection = -1; completeNotice = false;
          std::vector<lt::download_priority_t> priorities(handle.torrent_file()->num_files(), lt::dont_download);
          priorities[selected] = lt::default_priority;
          handle.prioritize_files(priorities); handle.resume();
          emit("{\"event\":\"stream\",\"index\":" + std::to_string(selected) + ",\"url\":" + quote(stream->select(selected)) + "}");
        }
        auto now = std::chrono::steady_clock::now();
        if (now - lastStatus > 1s) {
          lastStatus = now;
          auto status = handle.status();
          emit("{\"event\":\"status\",\"downloaded\":" + std::to_string(status.total_wanted_done)
            + ",\"total\":" + std::to_string(status.total_wanted) + ",\"downloadSpeed\":" + std::to_string(status.download_payload_rate)
            + ",\"uploadSpeed\":" + std::to_string(status.upload_payload_rate) + ",\"peers\":" + std::to_string(status.num_peers)
            + ",\"paused\":" + (bool(handle.flags() & lt::torrent_flags::paused) ? "true" : "false") + "}");
          auto progress = handle.file_progress();
          if (selected >= 0 && selected < static_cast<int>(progress.size()) && progress[selected] >= videos.at(selected).size && !completeNotice) {
            completeNotice = true;
            if (!seed) handle.pause();
            emit("{\"event\":\"complete\"}");
          }
        }
        if (broker && now - lastSave > 10s) { lastSave = now; handle.save_resume_data(lt::torrent_handle::save_info_dict); }
        std::this_thread::sleep_for(50ms);
      }
      stream.reset();
      if (broker) {
        saveComplete = false;
        handle.save_resume_data(lt::torrent_handle::save_info_dict);
        auto deadline = std::chrono::steady_clock::now() + 3s;
        while (!saveComplete && std::chrono::steady_clock::now() < deadline) std::this_thread::sleep_for(50ms);
      }
      broker.reset();
    } catch (...) {
      // The parent closes stdin after an error event; avoid blocking teardown
      // on a reader waiting for another command.
      emit("{\"event\":\"error\",\"message\":\"Torrent operation failed. Check the source, file selection and cache.\"}");
      stream.reset(); broker.reset();
    }
    if (input.joinable()) input.join();
    return 0;
  } catch (const std::exception& error) {
    const bool loopbackTest = argc >= 6 && std::string(argv[5]) == "loopback";
    emit(loopbackTest
      ? "{\"event\":\"error\",\"message\":" + quote(error.what()) + "}"
      : "{\"event\":\"error\",\"message\":\"The torrent engine could not initialize safely.\"}");
    return 1;
  } catch (...) {
    emit("{\"event\":\"error\",\"message\":\"The torrent engine could not initialize safely.\"}");
    return 1;
  }
}

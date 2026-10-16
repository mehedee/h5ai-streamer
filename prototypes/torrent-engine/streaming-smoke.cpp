// Isolated libtorrent feasibility test, not shipped application code.
// Creates synthetic bytes, connects two loopback-only sessions, and requests
// non-sequential verified pieces. It does not contact public trackers or DHT.
#include <libtorrent/session.hpp>
#include <libtorrent/settings_pack.hpp>
#include <libtorrent/create_torrent.hpp>
#include <libtorrent/torrent_info.hpp>
#include <libtorrent/torrent_handle.hpp>
#include <libtorrent/torrent_status.hpp>
#include <libtorrent/magnet_uri.hpp>
#include <libtorrent/alert_types.hpp>
#include <libtorrent/bencode.hpp>
#include <libtorrent/read_resume_data.hpp>
#include <libtorrent/write_resume_data.hpp>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <chrono>
#include <thread>
#include <stdexcept>
#include <future>
#include "../../Native/TorrentEngine/VerifiedPieceBroker.hpp"
#include "../../Native/TorrentEngine/HTTPRange.hpp"
#include "../../Native/TorrentEngine/LoopbackStream.hpp"

namespace lt = libtorrent;
using namespace std::chrono_literals;

static void require(bool ok, const char* message) {
  if (!ok) throw std::runtime_error(message);
}
static lt::settings_pack settings() {
  lt::settings_pack result;
  result.set_str(lt::settings_pack::listen_interfaces, "127.0.0.1:0");
  result.set_str(lt::settings_pack::outgoing_interfaces, "127.0.0.1");
  result.set_bool(lt::settings_pack::enable_dht, false);
  result.set_bool(lt::settings_pack::enable_lsd, false);
  result.set_bool(lt::settings_pack::enable_upnp, false);
  result.set_bool(lt::settings_pack::enable_natpmp, false);
  result.set_bool(lt::settings_pack::enable_incoming_utp, false);
  result.set_bool(lt::settings_pack::enable_outgoing_utp, false);
  result.set_int(lt::settings_pack::unchoke_interval, 1);
  result.set_int(lt::settings_pack::optimistic_unchoke_interval, 1);
  // Production default is 60 seconds. The deterministic fixture reconnects
  // its manually supplied loopback peer in one second after pause.
  result.set_int(lt::settings_pack::min_reconnect_time, 1);
  result.set_int(lt::settings_pack::alert_mask,
    static_cast<int>(static_cast<std::uint32_t>(lt::alert_category::error
      | lt::alert_category::status | lt::alert_category::storage)));
  return result;
}
template<typename Predicate>
static void waitUntil(Predicate predicate, const char* message) {
  auto end = std::chrono::steady_clock::now() + 20s;
  while (!predicate()) {
    require(std::chrono::steady_clock::now() < end, message);
    std::this_thread::sleep_for(30ms);
  }
}
static std::vector<char> readVerifiedPiece(lt::session& session,
    lt::torrent_handle handle, lt::piece_index_t piece) {
  // This API returns bytes only after hash-verified download and disk read.
  // Never read a sparse torrent file directly to satisfy a streaming request.
  handle.set_piece_deadline(piece, 0, lt::torrent_handle::alert_when_available);
  auto end = std::chrono::steady_clock::now() + 20s;
  while (std::chrono::steady_clock::now() < end) {
    session.wait_for_alert(200ms);
    std::vector<lt::alert*> alerts;
    session.pop_alerts(&alerts);
    for (auto* alert : alerts) {
      if (auto* read = lt::alert_cast<lt::read_piece_alert>(alert)) {
        if (read->handle != handle || read->piece != piece) continue;
        require(!read->error && read->buffer && read->size > 0,
          "verified piece read failed");
        require(handle.have_piece(piece), "engine returned an unverified piece");
        return {read->buffer.get(), read->buffer.get() + read->size};
      }
      if (auto* error = lt::alert_cast<lt::torrent_error_alert>(alert))
        throw std::runtime_error(error->error.message());
    }
  }
  auto status = handle.status();
  throw std::runtime_error("deadline piece timed out: piece=" + std::to_string(int(piece))
    + " peers=" + std::to_string(status.num_peers)
    + " have=" + std::to_string(handle.have_piece(piece))
    + " error=" + status.errc.message());
}
static bool safeRelativePath(const std::string& raw) {
  if (raw.empty() || raw.find('\\') != std::string::npos
      || raw.find(':') != std::string::npos) return false;
  std::filesystem::path path(raw);
  if (path.is_absolute()) return false;
  for (const auto& component : path)
    if (component == ".." || component == ".") return false;
  return true;
}
int main(int argc, char** argv) {
  try {
    require(argc >= 2 && argc <= 4, "Provide a new fixture directory, optional MP4 and --serve");
    std::filesystem::path root(argv[1]);
    require(!std::filesystem::exists(root), "Fixture directory already exists");
    std::filesystem::create_directories(root / "seed");
    std::filesystem::create_directories(root / "download");
    constexpr int pieceSize = 64 * 1024;
    std::vector<char> expected(8 * 1024 * 1024);
    for (std::size_t i = 0; i < expected.size(); ++i)
      expected[i] = static_cast<char>((i * 31 + (i / pieceSize) * 17) % 251);
    if (argc >= 3) {
      std::ifstream input(argv[2], std::ios::binary);
      require(bool(input), "fixture MP4 unreadable");
      expected = std::vector<char>(std::istreambuf_iterator<char>(input), {});
      require(expected.size() > 4 * pieceSize, "fixture too small for seeking test");
    }
    std::ofstream video(root / "seed" / "sample.mp4", std::ios::binary);
    video.write(expected.data(), expected.size());
    video.close();
    lt::file_storage files;
    files.add_file("sample.mp4", expected.size());
    lt::create_torrent creator(files, pieceSize, lt::create_torrent::v1_only);
    lt::set_piece_hashes(creator, (root / "seed").string());
    std::vector<char> bytes;
    lt::bencode(std::back_inserter(bytes), creator.generate());
    std::ofstream fixtureTorrent(root / "fixture.torrent", std::ios::binary);
    fixtureTorrent.write(bytes.data(), bytes.size()); fixtureTorrent.close();
    auto info = std::make_shared<lt::torrent_info>(
      lt::span<const char>(bytes.data(), bytes.size()), lt::from_span);

    lt::session seeder(settings()), downloader(settings());
    lt::add_torrent_params seed;
    seed.ti = info;
    seed.save_path = (root / "seed").string();
    seed.flags &= ~(lt::torrent_flags::auto_managed | lt::torrent_flags::paused);
    auto seedHandle = seeder.add_torrent(seed);
    waitUntil([&] { return seedHandle.status().is_seeding; }, "fixture seed hash check");
    waitUntil([&] { return seeder.listen_port() > 0; }, "loopback listen port");

    lt::error_code error;
    auto input = lt::parse_magnet_uri(lt::make_magnet_uri(seedHandle), error);
    require(!error, "valid magnet parsing failed");
    input.save_path = (root / "download").string();
    input.flags &= ~(lt::torrent_flags::auto_managed | lt::torrent_flags::paused);
    input.flags |= lt::torrent_flags::default_dont_download;
    auto handle = downloader.add_torrent(input);
    handle.connect_peer(lt::tcp::endpoint(
      lt::make_address("127.0.0.1"), seeder.listen_port()));
    waitUntil([&] { return handle.status().has_metadata; }, "magnet metadata resolution");
    require(handle.torrent_file()->info_hashes() == info->info_hashes(),
      "resolved magnet metadata mismatch");
    require(handle.file_priority(lt::file_index_t(0)) == lt::dont_download,
      "magnet downloaded payload before file selection");
    std::cout << "PASS magnet metadata resolved over loopback; payload default disabled\n";
    // Selecting the video keeps background pieces wanted. Requesting only
    // isolated pieces incorrectly reaches 'finished' between seeks and loses
    // the seed connection. A bounded rate keeps later test pieces missing.
    handle.set_download_limit(128 * 1024);
    handle.prioritize_files({lt::default_priority});

    const int requests[] = {0, info->num_pieces() - 1, info->num_pieces() / 2};
    for (int index : requests) {
      auto piece = lt::piece_index_t(index);
      require(!handle.have_piece(piece), "test requires an initially missing piece");
      auto data = readVerifiedPiece(downloader, handle, piece);
      auto begin = expected.begin() + index * pieceSize;
      require(data.size() == static_cast<std::size_t>(info->piece_size(piece))
        && std::equal(data.begin(), data.end(), begin), "piece byte mismatch");
      std::cout << "PASS verified non-sequential piece " << index
        << " (" << data.size() << " bytes)\n";
    }
    auto cached = readVerifiedPiece(downloader, handle, lt::piece_index_t(requests[1]));
    require(cached.size() == static_cast<std::size_t>(info->piece_size(lt::piece_index_t(requests[1]))),
      "cached seek read mismatch");
    std::cout << "PASS repeated seek reads verified cached bytes\n";
    handle.save_resume_data(lt::torrent_handle::save_info_dict);
    bool restored = false;
    waitUntil([&] {
      std::vector<lt::alert*> alerts;
      downloader.pop_alerts(&alerts);
      for (auto* alert : alerts) {
        if (auto* saved = lt::alert_cast<lt::save_resume_data_alert>(alert)) {
          auto resumeBytes = lt::write_resume_data_buf(saved->params);
          auto parsed = lt::read_resume_data(resumeBytes, error);
          require(!error && parsed.info_hashes == info->info_hashes(),
            "resume identity mismatch");
          require(parsed.have_pieces[lt::piece_index_t(requests[1])],
            "resume state lost verified seek piece");
          restored = true;
        }
        if (lt::alert_cast<lt::save_resume_data_failed_alert>(alert))
          throw std::runtime_error("resume data save failed");
      }
      return restored;
    }, "resume persistence");
    std::cout << "PASS resume data preserves torrent identity and verified pieces\n";

    handle.pause();
    waitUntil([&] { return bool(handle.flags() & lt::torrent_flags::paused); },
      "pause command");
    handle.resume();
    waitUntil([&] { return !bool(handle.flags() & lt::torrent_flags::paused); },
      "resume command");
    std::cout << "PASS pause and resume\n";
    {
      using myra::HTTPRange;
      auto full = HTTPRange::parse(std::nullopt, 1000);
      require(full.begin == 0 && full.end == 999 && !full.partial, "full HTTP range");
      auto suffix = HTTPRange::parse("bytes=-100", 1000);
      require(suffix.begin == 900 && suffix.end == 999 && suffix.partial, "suffix range");
      auto clamped = HTTPRange::parse("bytes=100-9999", 1000);
      require(clamped.begin == 100 && clamped.end == 999, "clamped range");
      auto open = HTTPRange::parse("bytes=500-", 1000);
      require(open.begin == 500 && open.end == 999, "open range");
      for (const auto& invalid : {"bytes=1000-", "bytes=9-2", "bytes=-0", "bytes=0-1,5-9",
          "bytes=999999999999999999999999-", "bytes=abc-", "bytes=1--2", "units=0-9", ""}) {
        bool rejected = false;
        try { HTTPRange::parse(invalid, 1000); } catch (...) { rejected = true; }
        require(rejected, "malformed HTTP range accepted");
      }
      std::cout << "PASS bounded/open/suffix ranges and malformed/overflow/multi-range rejection\n";
      handle.set_download_limit(512 * 1024);
      myra::VerifiedPieceBroker broker(downloader, handle, [](lt::alert* alert) {
        if (lt::alert_cast<lt::torrent_paused_alert>(alert)
            || lt::alert_cast<lt::torrent_resumed_alert>(alert)
            || lt::alert_cast<lt::torrent_error_alert>(alert)
            || lt::alert_cast<lt::state_changed_alert>(alert))
          std::cerr << "BROKER_STATE " << alert->message() << "\n";
      });
      std::atomic<bool> cancelled{false};
      std::vector<std::future<void>> clients;
      // More clients than the four-piece budget, including a shared same-piece read.
      for (int n = 0; n < 8; ++n) {
        int index = n < 2 ? requests[1] : 10 + n;
        clients.push_back(std::async(std::launch::async, [&, index] {
          auto data = broker.read(index, cancelled, 20s);
          require(data->size() == static_cast<std::size_t>(info->piece_size(lt::piece_index_t(index)))
            && std::equal(data->begin(), data->end(), expected.begin() + index * pieceSize),
            "concurrent verified-piece bytes mismatch");
        }));
      }
      for (auto& client : clients) client.get();
      std::cout << "PASS eight concurrent clients share verified reads without alert theft\n";
      {
        myra::LoopbackStream stream(broker, pieceSize, {{0, {0, 0,
          static_cast<std::int64_t>(expected.size()), "video/mp4"}},
          {1, {1, 100000, 150000, "video/x-matroska"}}});
        const auto url = stream.select(0);
        const auto portStart = url.find(':', 7) + 1;
        const auto pathStart = url.find('/', portStart);
        const auto port = static_cast<unsigned short>(std::stoi(url.substr(portStart, pathStart - portStart)));
        const auto route = url.substr(pathStart);
        auto request = [&](const std::string& method, const std::string& path, const std::string& range) {
          boost::asio::io_context io;
          boost::asio::ip::tcp::socket client(io);
          client.connect({lt::make_address("127.0.0.1"), port});
          timeval timeout{5, 0};
          setsockopt(client.native_handle(), SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
          const auto header = method + " " + path + " HTTP/1.1\r\nHost: 127.0.0.1\r\n"
            + (range.empty() ? "" : "Range: " + range + "\r\n") + "\r\n";
          boost::asio::write(client, boost::asio::buffer(header));
          std::string response;
          char chunk[4096];
          for (;;) {
            auto count = ::recv(client.native_handle(), chunk, sizeof(chunk), 0);
            if (count < 0 && errno == EINTR) continue;
            require(count >= 0, "HTTP request timeout");
            if (count == 0) return response;
            response.append(chunk, static_cast<std::size_t>(count));
            require(response.size() < 1024 * 1024, "HTTP response exceeds fixture bound");
          }
        };
        auto rangeResponse = request("GET", route, "bytes=70000-80000");
        const auto bodyStart = rangeResponse.find("\r\n\r\n") + 4;
        require(rangeResponse.rfind("HTTP/1.1 206", 0) == 0
          && rangeResponse.size() - bodyStart == 10001
          && std::equal(rangeResponse.begin() + bodyStart, rangeResponse.end(), expected.begin() + 70000),
          "streamed verified range bytes mismatch");
        auto headResponse = request("HEAD", route, "bytes=0-127");
        require(headResponse.rfind("HTTP/1.1 206", 0) == 0
          && headResponse.find("Content-Length: 128\r\n") != std::string::npos
          && headResponse.size() == headResponse.find("\r\n\r\n") + 4, "HEAD returned video payload");
        require(request("GET", "/wrong-token/0", "bytes=0-127").rfind("HTTP/1.1 404", 0) == 0, "unauthenticated route accepted");
        require(request("GET", route, "bytes=0-1,3-4").rfind("HTTP/1.1 416", 0) == 0, "multi-range accepted");
        std::vector<std::future<void>> ranges;
        for (int n = 0; n < 4; ++n) {
          ranges.push_back(std::async(std::launch::async, [&, n] {
            auto begin = (12 + n) * pieceSize + 3;
            auto response = request("GET", route, "bytes=" + std::to_string(begin) + "-" + std::to_string(begin + 2000));
            auto start = response.find("\r\n\r\n") + 4;
            require(response.rfind("HTTP/1.1 206", 0) == 0 && response.size() - start == 2001
              && std::equal(response.begin() + start, response.end(), expected.begin() + begin), "concurrent HTTP range mismatch");
          }));
        }
        for (auto& result : ranges) result.get();
        // Keep three old full-file requests open without consuming their data.
        // A new seek must have an independent worker, not wait for those clients.
        boost::asio::io_context abandonedIO;
        std::vector<std::unique_ptr<boost::asio::ip::tcp::socket>> abandoned;
        for (int n = 0; n < 3; ++n) {
          auto socket = std::make_unique<boost::asio::ip::tcp::socket>(abandonedIO);
          socket->connect({lt::make_address("127.0.0.1"), port});
          std::string header = "GET " + route + " HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n";
          boost::asio::write(*socket, boost::asio::buffer(header));
          abandoned.push_back(std::move(socket));
        }
        std::this_thread::sleep_for(100ms);
        auto seekStarted = std::chrono::steady_clock::now();
        auto seek = request("GET", route, "bytes=-128");
        require(seek.rfind("HTTP/1.1 206", 0) == 0
          && std::chrono::steady_clock::now() - seekStarted < 2s,
          "abandoned playback clients blocked a new seek");
        auto seekBody = seek.find("\r\n\r\n") + 4;
        require(seek.size() - seekBody == 128
          && std::equal(seek.begin() + seekBody, seek.end(), expected.end() - 128), "suffix seek payload mismatch");
        abandoned.clear();
        // Multi-file offsets must be mapped into torrent pieces, not treated
        // as offsets into the first video in a torrent.
        auto secondURL = stream.select(1);
        auto secondRoute = secondURL.substr(secondURL.find('/', 7));
        auto second = request("GET", secondRoute, "bytes=0-999");
        auto secondBody = second.find("\r\n\r\n") + 4;
        require(second.rfind("HTTP/1.1 206", 0) == 0
          && second.size() - secondBody == 1000
          && std::equal(second.begin() + secondBody, second.end(), expected.begin() + 100000),
          "multi-file stream used the wrong torrent offset");
        require(request("GET", route, "bytes=0-1").rfind("HTTP/1.1 404", 0) == 0, "previous file stayed accessible");
        stream.deselect();
        require(request("GET", route, "bytes=0-1").rfind("HTTP/1.1 404", 0) == 0, "deselected file stayed accessible");
        std::cout << "PASS authenticated loopback GET/HEAD, verified ranges, four concurrent clients and deselection\n";
        std::cout << "PASS abandoned playback does not block seek; multi-file piece offsets preserved\n";
      }
      handle.pause();
      int missing = -1;
      for (int n = info->num_pieces() - 2; n >= 0; --n) {
        if (!handle.have_piece(lt::piece_index_t(n))) { missing = n; break; }
      }
      require(missing >= 0, "cancellation test needs a missing piece");
      auto blocked = std::async(std::launch::async, [&] {
        try { broker.read(missing, cancelled, 20s); return false; }
        catch (...) { return true; }
      });
      std::this_thread::sleep_for(100ms);
      cancelled = true;
      require(blocked.wait_for(1s) == std::future_status::ready && blocked.get(),
        "cancelled seek did not unblock promptly");
      cancelled = false;
      bool timedOut = false;
      try { broker.read(missing, cancelled, 100ms); } catch (...) { timedOut = true; }
      require(timedOut, "missing piece timeout not enforced");
      handle.resume();
      // This fixture has no trackers/DHT/LSD. A pause disconnects its sole
      // manually supplied peer, so explicitly reconnect instead of waiting
      // for public peer-discovery mechanisms deliberately disabled in tests.
      handle.connect_peer(lt::tcp::endpoint(lt::make_address("127.0.0.1"), seeder.listen_port()));
      auto recovered = [&] {
        try { return broker.read(missing, cancelled, 20s); }
        catch (...) {
          const auto status = handle.status();
          std::cerr << "RECOVERY_STATUS missing=" << missing << " peers=" << status.num_peers
            << " progress=" << status.progress << " state=" << status.state
            << " paused=" << bool(handle.flags() & lt::torrent_flags::paused)
            << " have=" << handle.have_piece(lt::piece_index_t(missing))
            << " wanted=" << status.total_wanted << " downloaded=" << status.total_wanted_done << "\n";
          throw;
        }
      }();
      require(std::equal(recovered->begin(), recovered->end(), expected.begin() + missing * pieceSize),
        "read did not recover after cancellation and timeout");
      std::cout << "PASS cancelled and timed-out seeks recover on resumed download\n";
      broker.stop();
      bool stopped = false;
      try { broker.read(0, cancelled); } catch (...) { stopped = true; }
      require(stopped, "stopped broker accepted a new read");
      std::cout << "PASS broker shutdown rejects further reads\n";
    }

    lt::parse_magnet_uri("magnet:?xt=urn:btih:not-a-hash", error);
    require(bool(error), "invalid magnet accepted");
    require(!safeRelativePath("../outside.mp4")
      && !safeRelativePath("/outside.mp4")
      && !safeRelativePath("folder/../../outside.mp4")
      && !safeRelativePath("folder\\outside.mp4")
      && safeRelativePath("Series/Season 1/Episode 01.mkv"), "path policy failed");
    std::cout << "PASS malformed magnet and unsafe path rejection\n";
    std::cout << "Engine prototype passed; UI and packaging remain unverified\n";
    if (argc == 4) {
      require(std::string(argv[3]) == "--serve", "unknown option");
      handle.set_download_limit(512 * 1024);
      myra::VerifiedPieceBroker broker(downloader, handle);
      myra::LoopbackStream stream(broker, pieceSize, {{0, {0, 0,
        static_cast<std::int64_t>(expected.size()), "video/mp4"}}});
      std::cout << "SEEDER_PORT=" << seeder.listen_port() << "\n";
      std::cout << "STREAM_URL=" << stream.select(0) << "\n" << std::flush;
      std::string stop;
      std::getline(std::cin, stop); // Fixture owner stops it over stdin, never an unauthenticated HTTP command.
    }
    return 0;
  } catch (const std::exception& error) {
    std::cerr << "FAIL " << error.what() << "\n";
    return 1;
  }
}

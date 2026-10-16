#pragma once
#include "HTTPRange.hpp"
#include "VerifiedPieceBroker.hpp"
#include <boost/asio.hpp>
#include <array>
#include <deque>
#include <poll.h>
#include <sstream>
#include <set>
#include <sys/socket.h>
#include <unistd.h>

namespace myra {
struct StreamFile {
  int index;
  std::int64_t offset;
  std::int64_t size;
  std::string contentType;
  std::string extension = ".mp4";
};
// Loopback-only, bearer-token routes. Fixed worker/queue bounds prevent abandoned
// VLC connections from serializing a subsequent seek or spawning unbounded work.
class LoopbackStream final {
  using TCP = boost::asio::ip::tcp;
  boost::asio::io_context io_;
  TCP::acceptor acceptor_;
  VerifiedPieceBroker& broker_;
  const int pieceLength_;
  const std::map<int, StreamFile> files_;
  std::string token_;
  std::atomic<bool> stopping_{false};
  std::atomic<int> selected_{-1};
  std::mutex mutex_;
  std::condition_variable ready_;
  std::deque<std::unique_ptr<TCP::socket>> queue_;
  std::set<int> activeSockets_;
  std::thread acceptThread_;
  std::array<std::thread, 4> workers_;

  static bool sendAll(int fd, const char* bytes, std::size_t count) {
    while (count) {
      auto written = ::send(fd, bytes, count, 0);
      if (written < 0 && errno == EINTR) continue;
      if (written <= 0) return false;
      bytes += written; count -= written;
    }
    return true;
  }
  static bool sendText(int fd, const std::string& text) { return sendAll(fd, text.data(), text.size()); }
  static void emptyResponse(int fd, int status, const std::string& label, const std::string& extra = "") {
    sendText(fd, "HTTP/1.1 " + std::to_string(status) + " " + label + "\r\nContent-Length: 0\r\n"
      + extra + "Cache-Control: no-store\r\nConnection: close\r\n\r\n");
  }
  void handle(TCP::socket& socket) noexcept {
    int fd = socket.native_handle();
    timeval receiveTimeout{3, 0}, sendTimeout{1, 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, sizeof(receiveTimeout));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, sizeof(sendTimeout));
    int noSignal = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, sizeof(noSignal));
    std::atomic<bool> cancelled{false}, done{false};
    std::thread watchdog;
    try {
      std::string request;
      char byte;
      auto requestDeadline = std::chrono::steady_clock::now() + std::chrono::seconds(3);
      while (request.find("\r\n\r\n") == std::string::npos) {
        if (stopping_ || request.size() >= 8192 || std::chrono::steady_clock::now() > requestDeadline) {
          emptyResponse(fd, 400, "Bad Request"); return;
        }
        if (::recv(fd, &byte, 1, 0) != 1) return;
        request += byte;
      }
      std::istringstream lines(request);
      std::string firstLine, method, route, protocol;
      std::getline(lines, firstLine);
      std::istringstream start(firstLine);
      start >> method >> route >> protocol;
      if (protocol != "HTTP/1.1" && protocol != "HTTP/1.0") { emptyResponse(fd, 400, "Bad Request"); return; }
      int index = selected_;
      auto found = files_.find(index);
      if (found == files_.end() || route != "/" + token_ + "/" + std::to_string(index) + found->second.extension) {
        emptyResponse(fd, 404, "Not Found"); return;
      }
      if (method != "GET" && method != "HEAD") { emptyResponse(fd, 405, "Method Not Allowed", "Allow: GET, HEAD\r\n"); return; }
      std::optional<std::string> rangeHeader;
      std::string line;
      while (std::getline(lines, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (line.empty()) break;
        auto colon = line.find(':');
        if (colon == std::string::npos) { emptyResponse(fd, 400, "Bad Request"); return; }
        auto name = line.substr(0, colon);
        std::transform(name.begin(), name.end(), name.begin(), [](unsigned char c) { return std::tolower(c); });
        if (name == "range") {
          if (rangeHeader) { emptyResponse(fd, 416, "Range Not Satisfiable"); return; }
          rangeHeader = line.substr(colon + 1);
        }
      }
      const auto file = found->second;
      HTTPRange range;
      try { range = HTTPRange::parse(rangeHeader, file.size); }
      catch (...) { emptyResponse(fd, 416, "Range Not Satisfiable", "Content-Range: bytes */" + std::to_string(file.size) + "\r\n"); return; }
      watchdog = std::thread([&, index] {
        while (!done && !cancelled) {
          if (stopping_ || selected_ != index) { cancelled = true; return; }
          pollfd descriptor{fd, POLLIN, 0};
          auto result = ::poll(&descriptor, 1, 50);
          if (result < 0 && errno == EINTR) continue;
          if (result < 0 || (result > 0 && (descriptor.revents & (POLLHUP | POLLERR | POLLNVAL)))) {
            cancelled = true; return;
          }
          if (result > 0 && (descriptor.revents & POLLIN)) {
            char next;
            auto count = ::recv(fd, &next, 1, MSG_PEEK | MSG_DONTWAIT);
            if (count == 0) { cancelled = true; return; }
            // No request pipelining/body is accepted on a stream connection.
            if (count > 0) { cancelled = true; return; }
          }
        }
      });
      std::shared_ptr<const std::vector<char>> first;
      if (method == "GET") first = broker_.read(static_cast<int>((file.offset + range.begin) / pieceLength_), cancelled);
      std::string header = range.partial ? "HTTP/1.1 206 Partial Content\r\n" : "HTTP/1.1 200 OK\r\n";
      header += "Content-Type: " + file.contentType + "\r\nAccept-Ranges: bytes\r\nContent-Length: "
        + std::to_string(range.end - range.begin + 1) + "\r\nCache-Control: no-store\r\nConnection: close\r\n";
      if (range.partial) header += "Content-Range: bytes " + std::to_string(range.begin) + "-"
        + std::to_string(range.end) + "/" + std::to_string(file.size) + "\r\n";
      bool connected = sendText(fd, header + "\r\n");
      if (method == "GET") {
        for (auto offset = range.begin; connected && !cancelled && offset <= range.end;) {
          auto absolute = file.offset + offset;
          auto piece = static_cast<int>(absolute / pieceLength_);
          auto data = first ? std::move(first) : broker_.read(piece, cancelled);
          auto inPiece = absolute % pieceLength_;
          auto count = std::min<std::int64_t>(static_cast<std::int64_t>(data->size()) - inPiece, range.end - offset + 1);
          if (count <= 0) throw std::runtime_error("Invalid verified piece slice.");
          connected = sendAll(fd, data->data() + inPiece, static_cast<std::size_t>(count));
          offset += count;
        }
      }
    } catch (...) {
      // Headers may already have been sent. Close instead of appending a second
      // HTTP response or unverified bytes to the video stream.
    }
    done = true;
    cancelled = true;
    if (watchdog.joinable()) watchdog.join();
  }
  void work() noexcept {
    for (;;) {
      std::unique_ptr<TCP::socket> socket;
      {
        std::unique_lock<std::mutex> lock(mutex_);
        ready_.wait(lock, [&] { return stopping_ || !queue_.empty(); });
        if (stopping_) return;
        socket = std::move(queue_.front()); queue_.pop_front();
        activeSockets_.insert(socket->native_handle());
      }
      handle(*socket);
      std::lock_guard<std::mutex> lock(mutex_);
      activeSockets_.erase(socket->native_handle());
      // Close under the same lock that protects shutdown, so a reused descriptor
      // cannot be accidentally shut down by the stop operation.
      boost::system::error_code error;
      socket->close(error);
    }
  }
  void accept() noexcept {
    while (!stopping_) {
      auto socket = std::make_unique<TCP::socket>(io_);
      boost::system::error_code error;
      acceptor_.accept(*socket, error);
      if (error == boost::asio::error::would_block || error == boost::asio::error::try_again) {
        std::this_thread::sleep_for(std::chrono::milliseconds(20)); continue;
      }
      if (error) return;
      std::lock_guard<std::mutex> lock(mutex_);
      if (stopping_ || queue_.size() >= 4) continue; // Closing the socket rejects excess work.
      queue_.push_back(std::move(socket)); ready_.notify_one();
    }
  }
public:
  LoopbackStream(VerifiedPieceBroker& broker, int pieceLength, std::map<int, StreamFile> files)
    : acceptor_(io_, TCP::endpoint(boost::asio::ip::make_address("127.0.0.1"), 0)),
      broker_(broker), pieceLength_(pieceLength), files_(std::move(files)) {
    if (pieceLength <= 0 || pieceLength > 16 * 1024 * 1024 || files_.empty()) throw std::invalid_argument("Invalid stream metadata.");
    for (const auto& item : files_) {
      const auto& file = item.second;
      if (file.index != item.first || file.index < 0 || file.offset < 0 || file.size <= 0
          || file.offset > INT64_MAX - file.size
          || file.contentType.find_first_of("\r\n") != std::string::npos
          || file.extension.size() < 2 || file.extension.size() > 10 || file.extension.front() != '.'
          || !std::all_of(file.extension.begin() + 1, file.extension.end(), [](unsigned char c) { return std::isalnum(c); })) throw std::invalid_argument("Invalid stream file.");
    }
    unsigned char random[24]; arc4random_buf(random, sizeof(random));
    constexpr char hex[] = "0123456789abcdef";
    for (auto byte : random) { token_ += hex[byte >> 4]; token_ += hex[byte & 15]; }
    acceptor_.non_blocking(true);
    try {
      for (auto& worker : workers_) worker = std::thread([this] { work(); });
      acceptThread_ = std::thread([this] { accept(); });
    } catch (...) {
      // Resource exhaustion during construction must not destroy a joinable
      // std::thread and terminate the owning engine process.
      stopping_ = true;
      ready_.notify_all();
      for (auto& worker : workers_) if (worker.joinable()) worker.join();
      throw;
    }
  }
  LoopbackStream(const LoopbackStream&) = delete;
  LoopbackStream& operator=(const LoopbackStream&) = delete;
  ~LoopbackStream() {
    stopping_ = true;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      for (int fd : activeSockets_) ::shutdown(fd, SHUT_RDWR);
      queue_.clear(); ready_.notify_all();
    }
    if (acceptThread_.joinable()) acceptThread_.join();
    for (auto& worker : workers_) if (worker.joinable()) worker.join();
  }
  std::string select(int index) {
    if (!files_.count(index)) throw std::invalid_argument("Unknown video file.");
    selected_ = index;
    return "http://127.0.0.1:" + std::to_string(acceptor_.local_endpoint().port()) + "/" + token_ + "/" + std::to_string(index) + files_.at(index).extension;
  }
  void deselect() noexcept { selected_ = -1; }
};
} // namespace myra

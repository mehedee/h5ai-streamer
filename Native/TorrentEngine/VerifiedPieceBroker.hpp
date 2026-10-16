#pragma once
#include <libtorrent/session.hpp>
#include <libtorrent/torrent_handle.hpp>
#include <libtorrent/torrent_info.hpp>
#include <libtorrent/alert_types.hpp>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <thread>
#include <vector>

namespace myra {
// A session must have exactly one alert consumer. All concurrent HTTP clients
// share this broker; no request can steal another request's read_piece_alert.
class VerifiedPieceBroker final {
  struct Pending {
    std::shared_ptr<const std::vector<char>> bytes;
    std::string error;
    unsigned waiters = 0;
  };
  libtorrent::session& session_;
  libtorrent::torrent_handle handle_;
  std::mutex mutex_;
  std::condition_variable changed_;
  std::map<int, std::shared_ptr<Pending>> pending_;
  std::atomic<bool> stopping_{false};
  std::thread dispatcher_;
  std::function<void(libtorrent::alert*)> otherAlert_;
  void dispatch() noexcept {
    try {
      while (!stopping_) {
        session_.wait_for_alert(std::chrono::milliseconds(100));
        std::vector<libtorrent::alert*> alerts;
        session_.pop_alerts(&alerts);
        for (auto* alert : alerts) {
          auto* read = libtorrent::alert_cast<libtorrent::read_piece_alert>(alert);
          if (!read || read->handle != handle_) {
            // Callback consumes the alert synchronously; libtorrent owns its lifetime.
            if (otherAlert_) otherAlert_(alert);
            continue;
          }
          std::lock_guard<std::mutex> lock(mutex_);
          auto found = pending_.find(static_cast<int>(read->piece));
          if (found == pending_.end()) continue;
          auto& request = *found->second;
          // reset_piece_deadline posts an asynchronous operation_canceled
          // alert. It can arrive after a new request for the same piece, so it
          // is housekeeping, not evidence that the new disk read failed.
          if (read->error == boost::system::errc::make_error_code(boost::system::errc::operation_canceled)) continue;
          auto info = handle_.torrent_file();
          if (read->error || !info || !read->buffer || read->size != info->piece_size(read->piece)) {
            request.error = "A verified torrent piece could not be read.";
          } else {
            request.bytes = std::make_shared<const std::vector<char>>(
              read->buffer.get(), read->buffer.get() + read->size);
          }
          changed_.notify_all();
        }
      }
    } catch (...) {
      stopping_ = true;
      changed_.notify_all();
    }
  }
public:
  VerifiedPieceBroker(libtorrent::session& session, libtorrent::torrent_handle handle,
      std::function<void(libtorrent::alert*)> otherAlert = {})
    : session_(session), handle_(handle), otherAlert_(std::move(otherAlert)) {
    dispatcher_ = std::thread([this] { dispatch(); });
  }
  VerifiedPieceBroker(const VerifiedPieceBroker&) = delete;
  VerifiedPieceBroker& operator=(const VerifiedPieceBroker&) = delete;
  ~VerifiedPieceBroker() { stop(); if (dispatcher_.joinable()) dispatcher_.join(); }
  void stop() noexcept { stopping_ = true; changed_.notify_all(); }
  bool stopped() const noexcept { return stopping_; }

  // Libtorrent returns read_piece_alert only after hash verification. Raw
  // sparse-file bytes are deliberately not an allowed fallback.
  std::shared_ptr<const std::vector<char>> read(int index, const std::atomic<bool>& cancelled,
      std::chrono::milliseconds timeout = std::chrono::seconds(60)) {
    auto info = handle_.torrent_file();
    if (!info || index < 0 || index >= info->num_pieces()
        || info->piece_length() > 16 * 1024 * 1024) {
      throw std::runtime_error("Invalid or unsupported torrent piece.");
    }
    auto deadline = std::chrono::steady_clock::now() + timeout;
    std::unique_lock<std::mutex> lock(mutex_);
    // At most four outstanding reads, each at most 16 MB. Returned shared
    // buffers belong to callers; the HTTP transport separately bounds callers.
    while (!pending_.count(index) && pending_.size() >= 4 && !stopping_ && !cancelled) {
      if (std::chrono::steady_clock::now() >= deadline) throw std::runtime_error("Torrent piece request timed out.");
      changed_.wait_for(lock, std::chrono::milliseconds(50));
    }
    if (stopping_ || cancelled) throw std::runtime_error("Torrent read cancelled.");
    bool created = !pending_.count(index);
    auto& slot = pending_[index];
    if (!slot) slot = std::make_shared<Pending>();
    auto request = slot;
    ++request->waiters;
    auto release = [&] {
      if (--request->waiters == 0) {
        auto found = pending_.find(index);
        if (found != pending_.end() && found->second == request) pending_.erase(found);
        // Reset only our own deadline, never clear other clients' seek requests.
        try { handle_.reset_piece_deadline(libtorrent::piece_index_t(index)); } catch (...) {}
        changed_.notify_all();
      }
    };
    try {
      if (created) {
        if (handle_.have_piece(libtorrent::piece_index_t(index))) {
          handle_.read_piece(libtorrent::piece_index_t(index));
        } else {
          handle_.set_piece_deadline(libtorrent::piece_index_t(index), 0,
            libtorrent::torrent_handle::alert_when_available);
        }
      }
      while (!request->bytes && request->error.empty() && !stopping_ && !cancelled) {
        if (std::chrono::steady_clock::now() >= deadline) throw std::runtime_error("Torrent piece request timed out.");
        changed_.wait_for(lock, std::chrono::milliseconds(50));
      }
      if (stopping_ || cancelled) throw std::runtime_error("Torrent read cancelled.");
      if (!request->error.empty()) throw std::runtime_error(request->error);
      auto result = request->bytes;
      release();
      return result;
    } catch (...) { release(); throw; }
  }
};
} // namespace myra

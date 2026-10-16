#pragma once
#include <algorithm>
#include <cctype>
#include <cstdint>
#include <optional>
#include <stdexcept>
#include <string>

namespace myra {
struct HTTPRange {
  std::int64_t begin;
  std::int64_t end;
  bool partial;
  static HTTPRange parse(std::optional<std::string> header, std::int64_t size) {
    if (size <= 0) throw std::invalid_argument("Empty video");
    if (!header) return {0, size - 1, false};
    auto value = *header;
    auto first = value.find_first_not_of(" \t");
    auto last = value.find_last_not_of(" \t");
    if (first == std::string::npos) throw std::invalid_argument("Empty range");
    value = value.substr(first, last - first + 1);
    if (value.rfind("bytes=", 0) != 0 || value.find(',') != std::string::npos) throw std::invalid_argument("Unsupported range");
    value = value.substr(6);
    auto dash = value.find('-');
    if (dash == std::string::npos || value.find('-', dash + 1) != std::string::npos) throw std::invalid_argument("Invalid range");
    auto number = [](const std::string& raw) -> std::int64_t {
      if (raw.empty() || !std::all_of(raw.begin(), raw.end(), [](unsigned char c) { return std::isdigit(c); })) {
        throw std::invalid_argument("Invalid range number");
      }
      return std::stoll(raw);
    };
    if (dash == 0) {
      auto count = number(value.substr(1));
      if (count <= 0) throw std::invalid_argument("Invalid suffix range");
      return {std::max<std::int64_t>(0, size - count), size - 1, true};
    }
    auto begin = number(value.substr(0, dash));
    auto end = dash + 1 == value.size() ? size - 1 : std::min(size - 1, number(value.substr(dash + 1)));
    if (begin >= size || end < begin) throw std::invalid_argument("Unsatisfiable range");
    return {begin, end, true};
  }
};
} // namespace myra

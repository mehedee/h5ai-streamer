import Foundation

enum TorrentError: LocalizedError {
  case invalidIdentity, unsafePath, invalidSettings, protectedDownload
  case quota(required: Int64, available: Int64)
  case database(String)
  var errorDescription: String? {
    switch self {
    case .invalidIdentity: "The magnet does not contain a valid BitTorrent identity."
    case .unsafePath: "This torrent contains an unsafe file path or symbolic link."
    case .invalidSettings:
      "Choose a cache size between 1 and 10,240 GB and a non-negative upload limit."
    case .protectedDownload: "Stop playback and turn off Keep Download before removing this cache."
    case .quota(let required, let available):
      "This torrent needs \(ByteCountFormatter.string(fromByteCount: required, countStyle: .file)); \(ByteCountFormatter.string(fromByteCount: available, countStyle: .file)) is available in the cache. Increase the limit or remove an unused torrent."
    case .database(let message): "Torrent database: \(message)"
    }
  }
}

/// Canonical identity excludes display names, trackers and temporary HTTP stream URLs.
struct TorrentIdentity: Hashable, Codable, Sendable, Identifiable {
  var id: String { rawValue }
  let rawValue: String
  init(rawValue: String) throws {
    let value = rawValue.lowercased()
    let prefix: String
    let count: Int
    if value.hasPrefix("btih-") {
      prefix = "btih-"
      count = 40
    } else if value.hasPrefix("btmh-") {
      prefix = "btmh-"
      count = 64
    } else {
      throw TorrentError.invalidIdentity
    }
    let hash = value.dropFirst(prefix.count)
    guard hash.count == count, hash.allSatisfy({ "0123456789abcdef".contains($0) }) else {
      throw TorrentError.invalidIdentity
    }
    self.rawValue = value
  }
  init(magnet: String) throws {
    guard let components = URLComponents(string: magnet),
      components.scheme?.lowercased() == "magnet"
    else {
      throw TorrentError.invalidIdentity
    }
    let topics = (components.queryItems ?? []).filter { $0.name.lowercased() == "xt" }.compactMap(
      \.value)
    // Prefer the v1 identity for hybrids, consistently with the native engine.
    for topic in topics where topic.lowercased().hasPrefix("urn:btih:") {
      var hash = String(topic.dropFirst(9)).lowercased()
      if hash.count == 32 {
        guard let bytes = Self.base32(hash) else { continue }
        hash = bytes.map { String(format: "%02x", $0) }.joined()
      }
      if let identity = try? Self(rawValue: "btih-" + hash) {
        self = identity
        return
      }
    }
    for topic in topics where topic.lowercased().hasPrefix("urn:btmh:1220") {
      if let identity = try? Self(rawValue: "btmh-" + topic.dropFirst(13)) {
        self = identity
        return
      }
    }
    throw TorrentError.invalidIdentity
  }
  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(rawValue: values.decode(String.self, forKey: .rawValue))
  }
  func fileKey(index: Int) -> String { "myra-torrent:\(rawValue):\(index)" }
  private static func base32(_ raw: String) -> [UInt8]? {
    let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")
    var accumulator: UInt32 = 0
    var bits = 0
    var bytes: [UInt8] = []
    for character in raw {
      guard let value = alphabet.firstIndex(of: character) else { return nil }
      accumulator = (accumulator << 5) | UInt32(value)
      bits += 5
      if bits >= 8 {
        bits -= 8
        bytes.append(UInt8(truncatingIfNeeded: accumulator >> bits))
      }
    }
    return bytes.count == 20 ? bytes : nil
  }
}

struct TorrentFile: Codable, Hashable, Identifiable, Sendable {
  let index: Int
  let path: String
  let size: Int64
  var isSymlink = false
  var id: Int { index }
  var name: String { (path as NSString).lastPathComponent }
  var hasSafePath: Bool {
    guard index >= 0, !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"),
      !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
      !isSymlink
    else { return false }
    return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
      !$0.isEmpty && $0 != "." && $0 != ".."
    }
  }
  var isPlayable: Bool {
    let entry = DirectoryEntry(name: name, url: URL(fileURLWithPath: path), kind: .file)
    return hasSafePath && size > 0 && MediaFileType.isVideo(entry)
  }
  static func playbackOrder(_ files: [Self]) -> [Self] {
    files.filter(\.isPlayable).sorted {
      let comparison = $0.path.localizedStandardCompare($1.path)
      return comparison == .orderedSame ? $0.index < $1.index : comparison == .orderedAscending
    }
  }
}

enum TorrentSource: Codable, Equatable, Sendable {
  case magnet(String)
  // Imported .torrent data is copied into app-owned storage, never an external path.
  case importedTorrent(filename: String)
}

struct TorrentJob: Codable, Identifiable, Sendable {
  let identity: TorrentIdentity
  var name: String
  var source: TorrentSource
  var files: [TorrentFile]
  var selectedFileIndex: Int? = nil
  var keepDownload = false
  var addedAt = Date.now
  var id: String { identity.rawValue }
}

struct TorrentPlaybackProgress: Codable, Equatable, Sendable {
  let seconds: Double
  let duration: Double
  let updatedAt: Date
}

struct TorrentPreferences: Codable, Equatable, Sendable {
  var cacheLimitGB = 10
  var seedAfterCompletion = false
  var uploadLimitKB = 0
  var cacheLimitBytes: Int64 { Int64(cacheLimitGB) * 1024 * 1024 * 1024 }
  func validated() throws -> Self {
    guard (1...10240).contains(cacheLimitGB), (0...1_000_000).contains(uploadLimitKB) else {
      throw TorrentError.invalidSettings
    }
    return self
  }
}

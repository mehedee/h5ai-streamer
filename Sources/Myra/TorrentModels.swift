import Foundation

enum TorrentError: LocalizedError {
  case invalidIdentity, unsafePath, invalidSettings, protectedDownload, consentRequired
  case quota(required: Int64, available: Int64)
  case database(String)
  var errorDescription: String? {
    switch self {
    case .invalidIdentity: "The magnet does not contain a valid BitTorrent identity."
    case .unsafePath: "This torrent contains an unsafe file path or symbolic link."
    case .invalidSettings:
      "Choose a cache size between 1 and 10,240 GB and a non-negative upload limit."
    case .protectedDownload: "Stop playback and turn off Keep Download before removing this cache."
    case .consentRequired:
      "Accept the torrent privacy notice before networking. Torrent networking starts only after you add a link."
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
  /// Season and episode from the file name. Files without markers keep natural path order.
  var episode: TorrentEpisode? { TorrentEpisode(fileName: name) }
  /// Series episodes first in season/episode order, then remaining videos in natural order.
  static func playbackOrder(_ files: [Self]) -> [Self] {
    files.filter(\.isPlayable).sorted { lhs, rhs in
      switch (lhs.episode, rhs.episode) {
      case let (left?, right?) where left != right: return left < right
      case (.some, .none): return true
      case (.none, .some): return false
      default:
        let comparison = lhs.path.localizedStandardCompare(rhs.path)
        return comparison == .orderedSame
          ? lhs.index < rhs.index : comparison == .orderedAscending
      }
    }
  }
  /// The file Play and Download act on before the user picks another one. A series starts at
  /// its first episode; otherwise the largest video is chosen (lowest index breaks ties).
  static func defaultSelection(in files: [Self]) -> Self? {
    let playable = playbackOrder(files)
    if playable.contains(where: { $0.episode != nil }) { return playable.first }
    return playable.sorted { lhs, rhs in
      lhs.size != rhs.size ? lhs.size > rhs.size : lhs.index < rhs.index
    }.first
  }
}

struct TorrentEpisode: Comparable, Sendable {
  let season: Int
  let number: Int
  static func < (lhs: Self, rhs: Self) -> Bool {
    (lhs.season, lhs.number) < (rhs.season, rhs.number)
  }
  /// Recognises S01E02, S1 E2 and 1x02 markers. Numbers are bounded to avoid overflow.
  init?(fileName: String) {
    let pattern = #"(?i)(?:^|[^a-z0-9])s(\d{1,3})[ ._-]?e(\d{1,4})(?!\d)|(?:^|[^0-9])(\d{1,2})x(\d{1,3})(?!\d)"#
    guard let expression = try? NSRegularExpression(pattern: pattern),
      let match = expression.firstMatch(
        in: fileName, range: NSRange(fileName.startIndex..., in: fileName))
    else { return nil }
    func number(_ group: Int) -> Int? {
      let range = match.range(at: group)
      guard range.location != NSNotFound, let swiftRange = Range(range, in: fileName) else {
        return nil
      }
      return Int(fileName[swiftRange])
    }
    guard let season = number(1) ?? number(3), let episode = number(2) ?? number(4) else {
      return nil
    }
    self.season = season
    self.number = episode
  }
}

/// Plain value for Downloads and Transfers screens. Built from controller state only.
struct TorrentTransferRow: Identifiable, Equatable, Sendable {
  let id: String
  let name: String
  let state: String
  let bytesDone: Int64
  let bytesTotal: Int64
  let downloadSpeed: Int64
  let peers: Int
  let isStreaming: Bool
  let isComplete: Bool
  let isPaused: Bool
  let bufferedSeconds: Double

  init(job: TorrentJob, transfer: TorrentTransfer, isStreaming: Bool) {
    id = job.id
    name = job.name
    state = transfer.state
    bytesDone = transfer.downloaded
    bytesTotal = transfer.total
    downloadSpeed = transfer.downloadSpeed
    peers = transfer.peers
    self.isStreaming = isStreaming
    isComplete = transfer.completed
    isPaused = transfer.paused
    bufferedSeconds = transfer.bufferedSeconds
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

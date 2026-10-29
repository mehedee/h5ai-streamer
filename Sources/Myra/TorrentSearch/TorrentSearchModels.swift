import Foundation

/// Where a search result comes from.
enum TorrentIndexerKind: String, Codable, Sendable {
  case internetArchive, blenderOpenMovies, torznab
}

/// One configured search indexer. API keys never live here: they are stored in the Keychain by id.
struct TorrentIndexer: Codable, Identifiable, Equatable, Sendable {
  var id: UUID
  var name: String
  var kind: TorrentIndexerKind
  /// Torznab endpoint. Nil for the built-in sources.
  var url: URL?
  var enabled: Bool
  var isBuiltIn: Bool

  static let internetArchiveID = UUID(uuidString: "6A1D0C0E-0000-4000-8000-000000000001")!
  static let blenderID = UUID(uuidString: "6A1D0C0E-0000-4000-8000-000000000002")!

  static let internetArchive = TorrentIndexer(
    id: internetArchiveID, name: "Internet Archive", kind: .internetArchive, url: nil,
    enabled: true, isBuiltIn: true)
  static let blenderOpenMovies = TorrentIndexer(
    id: blenderID, name: "Blender Open Movies", kind: .blenderOpenMovies, url: nil,
    enabled: true, isBuiltIn: true)
  static let builtIns = [internetArchive, blenderOpenMovies]

  /// One-line description shown in Settings.
  var note: String {
    switch kind {
    case .internetArchive: "Public-domain and openly licensed films"
    case .blenderOpenMovies: "Creative Commons short films (curated list)"
    case .torznab: url.map { Self.display($0) } ?? "Torznab"
    }
  }

  /// Host and path only, so a URL never shows credentials or query strings.
  static func display(_ url: URL) -> String {
    var text = url.host ?? ""
    if let port = url.port { text += ":\(port)" }
    return text + url.path
  }
}

/// Video quality parsed from a release title.
enum TorrentQuality: String, CaseIterable, Comparable, Sendable, Hashable {
  case p2160 = "2160p"
  case p1080 = "1080p"
  case p720 = "720p"
  case p480 = "480p"

  private var rank: Int { Self.allCases.firstIndex(of: self)! }
  static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }

  /// Recognises 2160p/4K/UHD, 1080p/1080i, 720p and 480p/576p. Nil when the title says nothing.
  static func parse(_ title: String) -> TorrentQuality? {
    let patterns: [(String, TorrentQuality)] = [
      (#"(?i)(?<![a-z0-9])(2160p|4k|uhd)(?![a-z0-9])"#, .p2160),
      (#"(?i)(?<![a-z0-9])1080[pi](?![a-z0-9])"#, .p1080),
      (#"(?i)(?<![a-z0-9])720p(?![a-z0-9])"#, .p720),
      (#"(?i)(?<![a-z0-9])(480p|576p|dvdrip)(?![a-z0-9])"#, .p480),
    ]
    for (pattern, quality) in patterns
    where title.range(of: pattern, options: .regularExpression) != nil {
      return quality
    }
    return nil
  }
}

/// One search hit, normalised from any indexer.
struct TorrentSearchResult: Identifiable, Equatable, Sendable {
  var id: String
  var title: String
  var indexerID: UUID
  var indexerName: String
  var size: Int64?
  /// Nil when the indexer does not report swarm health.
  var seeders: Int?
  var leechers: Int?
  /// Lower-case 40-character hex BitTorrent info hash when known.
  var infohash: String?
  var magnet: String?
  /// Download link. It can hold a provider passkey, so it is never shown, copied or stored.
  var torrentURL: URL?
  /// Internet Archive identifier; the torrent link is resolved when the user acts on it.
  var archiveID: String?
  var published: Date?
  var license: String?
  var sourceURL: URL?
  /// Other indexers that returned the same torrent.
  var alsoFrom: [String] = []

  var quality: TorrentQuality? { TorrentQuality.parse(title) }

  /// Identity used for de-duplication: the info hash, else a normalised title and size.
  var dedupeKey: String {
    if let infohash { return "btih:" + infohash }
    if let archiveID { return "archive:" + archiveID }
    let normal = title.lowercased().filter { $0.isLetter || $0.isNumber }
    return "t:" + normal + ":" + String(size ?? 0)
  }

  /// A magnet that can be copied or added: the supplied one, else one built from the info hash.
  var shareableMagnet: String? {
    if let magnet { return magnet }
    guard let infohash else { return nil }
    var components = URLComponents()
    components.scheme = "magnet"
    components.queryItems = [
      URLQueryItem(name: "xt", value: "urn:btih:" + infohash),
      URLQueryItem(name: "dn", value: title),
    ]
    return components.string
  }

  /// True when Play Now / Download has something to start from.
  var isActionable: Bool { shareableMagnet != nil || torrentURL != nil || archiveID != nil }
}

enum TorrentSearchSort: String, CaseIterable, Identifiable, Sendable {
  case seeders, size, name
  var id: String { rawValue }
  var title: String {
    switch self {
    case .seeders: "Most seeders"
    case .size: "Largest"
    case .name: "A to Z"
    }
  }
}

/// Quality and minimum-seeder filters plus ordering. Pure, so it is easy to test.
struct TorrentSearchFilter: Equatable, Sendable {
  var qualities: Set<TorrentQuality> = []
  var minSeeders = 1
  var sort: TorrentSearchSort = .seeders

  var isDefault: Bool { qualities.isEmpty && minSeeders <= 1 }

  /// Results whose seeder count is unknown (Internet Archive web seeds) pass the seeder filter.
  func apply(_ results: [TorrentSearchResult]) -> [TorrentSearchResult] {
    let kept = results.filter { result in
      if !qualities.isEmpty {
        guard let quality = result.quality, qualities.contains(quality) else { return false }
      }
      if let seeders = result.seeders, seeders < minSeeders { return false }
      return true
    }
    return kept.sorted { lhs, rhs in
      switch sort {
      case .seeders:
        let (l, r) = (lhs.seeders ?? -1, rhs.seeders ?? -1)
        if l != r { return l > r }
      case .size:
        let (l, r) = (lhs.size ?? -1, rhs.size ?? -1)
        if l != r { return l > r }
      case .name: break
      }
      let order = lhs.title.localizedStandardCompare(rhs.title)
      return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
    }
  }
}

enum TorrentSearchDeduper {
  /// Keeps one entry per torrent. The entry with more seeders wins; missing links and sizes
  /// are filled from the duplicate, and the other indexer's name is remembered.
  static func merge(_ results: [TorrentSearchResult]) -> [TorrentSearchResult] {
    var order: [String] = []
    var byKey: [String: TorrentSearchResult] = [:]
    for result in results {
      let key = result.dedupeKey
      guard let existing = byKey[key] else {
        order.append(key)
        byKey[key] = result
        continue
      }
      let resultWins = (result.seeders ?? -1) > (existing.seeders ?? -1)
      var winner = resultWins ? result : existing
      let loser = resultWins ? existing : result
      winner.magnet = winner.magnet ?? loser.magnet
      winner.torrentURL = winner.torrentURL ?? loser.torrentURL
      winner.size = winner.size ?? loser.size
      winner.infohash = winner.infohash ?? loser.infohash
      var names = winner.alsoFrom
      for name in loser.alsoFrom + [loser.indexerName]
      where name != winner.indexerName && !names.contains(name) {
        names.append(name)
      }
      winner.alsoFrom = names
      byKey[key] = winner
    }
    return order.compactMap { byKey[$0] }
  }
}

/// Why one indexer failed, in terms the user can act on.
enum TorrentSearchFailure: Error, Equatable, Sendable {
  case badKey
  case timeout
  case unreachable
  case notTorznab
  case http(Int)
  case provider(code: Int, text: String)
  case keychain
  case invalidEndpoint
  case tooLarge

  var message: String {
    switch self {
    case .badKey: "The indexer rejected the API key. Check it in Settings > Torrents."
    case .timeout: "The indexer did not answer within 8 seconds."
    case .unreachable: "The indexer could not be reached. Check the address and your network."
    case .notTorznab: "The indexer replied with something that is not a Torznab feed."
    case .http(let code): "The indexer returned HTTP \(code)."
    case .provider(let code, let text):
      text.isEmpty ? "The indexer reported error \(code)." : "The indexer reported: \(text)"
    case .keychain: "The API key could not be read from the Keychain."
    case .invalidEndpoint: "The indexer address is not allowed. Use HTTPS or a local address."
    case .tooLarge: "The indexer response was too large."
    }
  }
}

enum IndexerRunState: Equatable, Sendable {
  case pending
  case searching
  case finished(count: Int)
  case failed(TorrentSearchFailure)
}

struct IndexerStatus: Identifiable, Equatable, Sendable {
  var indexerID: UUID
  var name: String
  var state: IndexerRunState
  var id: UUID { indexerID }
}

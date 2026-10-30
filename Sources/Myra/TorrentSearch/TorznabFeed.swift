import Foundation

/// What a Torznab response contained: search results, or the advertised capabilities.
struct TorznabFeed: Equatable, Sendable {
  var results: [TorrentSearchResult] = []
  /// Human-readable capabilities from a `t=caps` reply, e.g. "search", "TV", "movies".
  var capabilities: [String] = []
  /// True when the feed was cut off but earlier items were kept.
  var truncated = false
}

/// Parses Torznab/Newznab XML. Malformed items are skipped, a provider `<error>` becomes a
/// typed failure, and DTDs and entities are refused outright.
enum TorznabParser {
  static let maxBytes = 2 * 1024 * 1024
  static let maxItems = 100

  static func parse(_ data: Data, indexer: TorrentIndexer) throws -> TorznabFeed {
    guard data.count <= maxBytes else { throw TorrentSearchFailure.tooLarge }
    let head = String(decoding: data.prefix(maxBytes), as: UTF8.self).uppercased()
    guard !head.contains("<!DOCTYPE"), !head.contains("<!ENTITY") else {
      throw TorrentSearchFailure.notTorznab
    }
    let delegate = Delegate(indexer: indexer)
    let parser = XMLParser(data: data)
    parser.shouldResolveExternalEntities = false
    parser.delegate = delegate
    let completed = parser.parse()
    if let error = delegate.providerError { throw error }
    guard delegate.root == "rss" || delegate.root == "caps" else {
      throw TorrentSearchFailure.notTorznab
    }
    if !completed {
      // A feed cut off after some good items still helps; anything else is not usable.
      guard !delegate.feed.results.isEmpty else { throw TorrentSearchFailure.notTorznab }
      delegate.feed.truncated = true
    }
    return delegate.feed
  }

  /// Normalises a 40-hex or 32-character base32 info hash to lower-case hex. Nil when invalid.
  static func normalizedInfohash(_ raw: String) -> String? {
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if value.count == 40, value.allSatisfy({ "0123456789abcdef".contains($0) }) { return value }
    if value.count == 32,
      let identity = try? TorrentIdentity(magnet: "magnet:?xt=urn:btih:" + value),
      identity.rawValue.hasPrefix("btih-")
    {
      return String(identity.rawValue.dropFirst(5))
    }
    return nil
  }

  private static func allowedDownload(_ text: String) -> URL? {
    guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
      url.user == nil, url.password == nil, let host = url.host,
      url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host))
    else { return nil }
    return url
  }

  nonisolated(unsafe) private static let dateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
    return formatter
  }()

  private final class Delegate: NSObject, XMLParserDelegate {
    let indexer: TorrentIndexer
    var feed = TorznabFeed()
    var providerError: TorrentSearchFailure?
    var root: String?
    private var inItem = false
    private var element = ""
    private var title = "", link = "", guid = "", pubDate = ""
    private var enclosureURL = "", enclosureLength: Int64?
    private var attributes: [String: String] = [:]
    private var index = 0

    init(indexer: TorrentIndexer) { self.indexer = indexer }

    func parser(
      _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
      qualifiedName qName: String?, attributes attrs: [String: String]
    ) {
      let name = elementName.lowercased()
      if root == nil { root = name }
      element = name
      switch name {
      case "error":
        let code = attrs["code"].flatMap(Int.init) ?? 0
        let text = String((attrs["description"] ?? "").prefix(160))
        providerError = (100...102).contains(code) ? .badKey : .provider(code: code, text: text)
      case "item":
        inItem = true
        title = ""; link = ""; guid = ""; pubDate = ""
        enclosureURL = ""; enclosureLength = nil
        attributes = [:]
      case "enclosure" where inItem:
        enclosureURL = attrs["url"] ?? ""
        enclosureLength = attrs["length"].flatMap(Int64.init)
      case "search" where root == "caps", "tv-search", "movie-search", "audio-search",
        "book-search":
        guard attrs["available"]?.lowercased() == "yes" else { break }
        let label =
          ["search": "search", "tv-search": "TV", "movie-search": "movies",
            "audio-search": "music", "book-search": "books"][name] ?? name
        if !feed.capabilities.contains(label) { feed.capabilities.append(label) }
      default:
        if inItem, name.hasSuffix(":attr") || name == "attr", let key = attrs["name"],
          let value = attrs["value"]
        {
          attributes[key.lowercased()] = value
        }
      }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
      guard inItem else { return }
      switch element {
      case "title": title += string
      case "link": link += string
      case "guid": guid += string
      case "pubdate": pubDate += string
      default: break
      }
    }

    func parser(
      _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
      qualifiedName qName: String?
    ) {
      defer { element = "" }
      guard elementName.lowercased() == "item" else { return }
      inItem = false
      guard feed.results.count < TorznabParser.maxItems, let result = makeResult() else { return }
      feed.results.append(result)
    }

    private func makeResult() -> TorrentSearchResult? {
      let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !name.isEmpty else { return nil }
      var magnet: String?
      for candidate in [attributes["magneturl"] ?? "", enclosureURL, link]
      where magnet == nil {
        let text = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("magnet:"), (try? TorrentIdentity(magnet: text)) != nil {
          magnet = text
        }
      }
      var infohash = attributes["infohash"].flatMap(TorznabParser.normalizedInfohash)
      if infohash == nil, let magnet, let identity = try? TorrentIdentity(magnet: magnet),
        identity.rawValue.hasPrefix("btih-")
      {
        infohash = String(identity.rawValue.dropFirst(5))
      }
      let download = TorznabParser.allowedDownload(enclosureURL) ?? TorznabParser.allowedDownload(link)
      guard magnet != nil || infohash != nil || download != nil else { return nil }
      let seeders = attributes["seeders"].flatMap { Int($0) }.map { max(0, $0) }
      var leechers = attributes["leechers"].flatMap { Int($0) }.map { max(0, $0) }
      if leechers == nil, let peers = attributes["peers"].flatMap({ Int($0) }), let seeders {
        leechers = max(0, peers - seeders)
      }
      let size = attributes["size"].flatMap { Int64($0) } ?? enclosureLength
      index += 1
      let key = infohash ?? (guid.isEmpty ? name : guid)
      return TorrentSearchResult(
        id: indexer.id.uuidString + ":" + String(index) + ":" + key,
        title: name, indexerID: indexer.id, indexerName: indexer.name,
        size: size.map { max(0, $0) }, seeders: seeders, leechers: leechers, infohash: infohash,
        magnet: magnet, torrentURL: download, archiveID: nil,
        published: TorznabParser.dateFormatter.date(
          from: pubDate.trimmingCharacters(in: .whitespacesAndNewlines)),
        license: nil, sourceURL: indexer.url)
    }
  }
}

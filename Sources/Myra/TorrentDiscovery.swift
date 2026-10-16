import Foundation
import Security

struct TorznabSource: Codable, Identifiable, Equatable, Sendable {
  var id = UUID()
  var name: String
  var endpoint: URL
  static func validatedEndpoint(_ text: String) throws -> URL {
    guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
      let host = url.host, url.user == nil, url.password == nil, url.fragment == nil,
      url.scheme == "https"
        || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)),
      URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: {
        $0.name.lowercased().contains("key")
      }) != true
    else {
      throw TorrentError.database(
        "Use HTTPS (or local loopback HTTP) and enter the API key separately.")
    }
    return url
  }
}

struct TorrentDiscoveryItem: Identifiable, Sendable {
  var id: String
  var title: String
  var provider: String
  var sourceURL: URL
  var license: String
  var torrentURL: URL?
  var magnet: String?
  var archiveID: String?
  var size: Int64?
  var seeders: Int?
}

enum TorznabKeyStore {
  private static func query(_ id: UUID) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "com.mehedee.Myra.torznab",
      kSecAttrAccount as String: id.uuidString,
    ]
  }
  static func read(_ id: UUID) throws -> String {
    var request = query(id)
    request[kSecReturnData as String] = true
    request[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(request as CFDictionary, &result)
    if status == errSecItemNotFound { return "" }
    guard status == errSecSuccess, let data = result as? Data,
      let value = String(data: data, encoding: .utf8)
    else { throw TorrentError.database("Could not access the source API key in Keychain.") }
    return value
  }
  static func save(_ value: String, id: UUID) throws {
    let query = query(id)
    if value.isEmpty {
      let status = SecItemDelete(query as CFDictionary)
      guard status == errSecSuccess || status == errSecItemNotFound else {
        throw TorrentError.invalidSettings
      }
      return
    }
    let attributes = [kSecValueData as String: Data(value.utf8)]
    let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if status == errSecItemNotFound {
      var item = query.merging(attributes) { _, new in new }
      item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
        throw TorrentError.invalidSettings
      }
    } else if status != errSecSuccess {
      throw TorrentError.invalidSettings
    }
  }
}

private final class TorrentRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  let origin: URL
  init(origin: URL) { self.origin = origin }
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    let archiveRedirect =
      origin.host == "archive.org" && request.url?.host?.hasSuffix(".archive.org") == true
      && origin.query == nil
    guard let url = request.url, url.host == origin.host || archiveRedirect,
      url.port == origin.port,
      url.scheme == origin.scheme, url.user == nil, url.password == nil
    else {
      completionHandler(nil)
      return
    }
    completionHandler(request)
  }
}

enum TorrentDiscoveryService {
  static let openMovies: [TorrentDiscoveryItem] = [
    ("Big Buck Bunny", "big-buck-bunny"), ("Cosmos Laundromat", "cosmos-laundromat"),
    ("Sintel", "sintel"), ("Tears of Steel", "tears-of-steel"),
  ].map { title, slug in
    TorrentDiscoveryItem(
      id: "open:" + slug, title: title, provider: "Open Movies",
      sourceURL: URL(string: "https://webtorrent.io/free-torrents")!,
      license: "Creative Commons — verify the source license",
      torrentURL: URL(string: "https://webtorrent.io/torrents/" + slug + ".torrent")!)
  }

  static func fetch(_ url: URL, limit: Int = 2 * 1024 * 1024) async throws -> Data {
    guard
      url.scheme == "https"
        || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(url.host ?? "")),
      url.user == nil, url.password == nil
    else { throw TorrentError.unsafePath }
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 25
    config.timeoutIntervalForResource = 45
    config.httpCookieStorage = nil
    config.urlCredentialStorage = nil
    config.urlCache = nil
    let session = URLSession(
      configuration: config, delegate: TorrentRedirectPolicy(origin: url), delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    let (bytes, response) = try await session.bytes(from: url)
    guard let response = response as? HTTPURLResponse, response.statusCode == 200,
      response.expectedContentLength <= Int64(limit)
    else { throw TorrentError.database("Source is unavailable or its response is too large.") }
    var data = Data()
    for try await byte in bytes {
      try Task.checkCancellation()
      guard data.count < limit else {
        throw TorrentError.database("Source response exceeds the size limit.")
      }
      data.append(byte)
    }
    return data
  }
  static func archiveURL(query: String, page: Int) -> URL {
    // Quoted literal title matching prevents user text from changing the license filter.
    let escaped = query.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(
      of: "\"", with: "\\\"")
    var url = URLComponents(string: "https://archive.org/advancedsearch.php")!
    url.queryItems = [
      .init(name: "q", value: "mediatype:movies AND licenseurl:* AND title:\"" + escaped + "\""),
      .init(name: "fl[]", value: "identifier"), .init(name: "fl[]", value: "title"),
      .init(name: "fl[]", value: "licenseurl"), .init(name: "rows", value: "20"),
      .init(name: "page", value: String(max(1, page))), .init(name: "output", value: "json"),
    ]
    return url.url!
  }
  static func parseArchive(_ data: Data) throws -> [TorrentDiscoveryItem] {
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let response = root["response"] as? [String: Any],
      let docs = response["docs"] as? [[String: Any]]
    else { throw TorrentError.invalidSettings }
    return docs.prefix(20).compactMap { doc in
      guard let id = doc["identifier"] as? String, !id.isEmpty,
        id.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil,
        let title = doc["title"] as? String
      else { return nil }
      let license = (doc["licenseurl"] as? String) ?? (doc["licenseurl"] as? [String])?.first ?? ""
      guard let licenseURL = URL(string: license),
        licenseURL.host?.lowercased() == "creativecommons.org",
        licenseURL.path.hasPrefix("/licenses/") || licenseURL.path.hasPrefix("/publicdomain/")
      else { return nil }
      return TorrentDiscoveryItem(
        id: "archive:" + id, title: title, provider: "Internet Archive",
        sourceURL: URL(string: "https://archive.org/details/" + id)!,
        license: license, archiveID: id)
    }
  }
  static func archiveTorrent(_ id: String) async throws -> URL {
    guard id.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else {
      throw TorrentError.unsafePath
    }
    let data = try await fetch(URL(string: "https://archive.org/metadata/" + id + "/files")!)
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let files = root["result"] as? [[String: Any]],
      let name = files.compactMap({ $0["name"] as? String }).first(where: {
        $0.hasSuffix(".torrent")
      }),
      !name.contains("/"), name != ".."
    else { throw TorrentError.database("This Archive item has no torrent available.") }
    return URL(string: "https://archive.org/download/" + id + "/")!.appendingPathComponent(name)
  }
  static func torznabURL(source: TorznabSource, key: String, query: String, page: Int) throws -> URL
  {
    _ = try TorznabSource.validatedEndpoint(source.endpoint.absoluteString)
    var url = URLComponents(url: source.endpoint, resolvingAgainstBaseURL: false)!
    url.queryItems =
      (url.queryItems ?? []).filter {
        !["t", "q", "apikey", "offset", "limit", "extended"].contains($0.name.lowercased())
      } + [
        .init(name: "t", value: "search"), .init(name: "q", value: query),
        .init(name: "offset", value: String((max(1, page) - 1) * 20)),
        .init(name: "limit", value: "20"),
        .init(name: "extended", value: "1"), .init(name: "apikey", value: key),
      ]
    return url.url!
  }
  static func parseTorznab(_ data: Data, source: TorznabSource) throws -> [TorrentDiscoveryItem] {
    guard data.count <= 2 * 1024 * 1024,
      String(data: data, encoding: .utf8)?.uppercased().contains("<!DOCTYPE") != true,
      String(data: data, encoding: .utf8)?.uppercased().contains("<!ENTITY") != true
    else { throw TorrentError.unsafePath }
    let delegate = TorznabParser(source: source)
    let parser = XMLParser(data: data)
    parser.shouldResolveExternalEntities = false
    parser.delegate = delegate
    guard parser.parse(), !delegate.providerError else {
      throw TorrentError.database(
        "Torznab source returned an invalid response or rejected the request.")
    }
    return delegate.items
  }
}

private final class TorznabParser: NSObject, XMLParserDelegate {
  let source: TorznabSource
  var items: [TorrentDiscoveryItem] = []
  var providerError = false
  private var inItem = false
  private var element = ""
  private var title = "", link = "", magnet = "", enclosure = ""
  private var size: Int64?, seeders: Int?
  init(source: TorznabSource) { self.source = source }
  func parser(
    _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
    qualifiedName qName: String?, attributes: [String: String]
  ) {
    element = elementName
    if elementName == "error" { providerError = true }
    if elementName == "item" {
      inItem = true
      title = ""
      link = ""
      magnet = ""
      enclosure = ""
      size = nil
      seeders = nil
    }
    guard inItem else { return }
    if elementName == "enclosure", attributes["type"]?.hasPrefix("application/x-bittorrent") == true
    {
      enclosure = attributes["url"] ?? ""
      size = attributes["length"].flatMap(Int64.init)
    }
    if elementName.hasSuffix(":attr") || elementName == "attr" {
      switch attributes["name"] {
      case "magneturl": magnet = attributes["value"] ?? ""
      case "size": size = attributes["value"].flatMap(Int64.init)
      case "seeders": seeders = attributes["value"].flatMap(Int.init)
      default: break
      }
    }
  }
  func parser(_ parser: XMLParser, foundCharacters string: String) {
    guard inItem else { return }
    if element == "title" { title += string }
    if element == "link" { link += string }
  }
  func parser(
    _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
    qualifiedName qName: String?
  ) {
    defer { element = "" }
    guard elementName == "item" else { return }
    inItem = false
    if magnet.isEmpty, enclosure.hasPrefix("magnet:") { magnet = enclosure }
    let validMagnet = (try? TorrentIdentity(magnet: magnet)) != nil ? magnet : nil
    let url = URL(string: enclosure)
    let validURL = url.flatMap { candidate -> URL? in
      guard candidate.user == nil, candidate.password == nil,
        candidate.scheme == "https"
          || (candidate.scheme == "http"
            && ["localhost", "127.0.0.1", "::1"].contains(candidate.host ?? ""))
      else { return nil }
      return candidate
    }
    guard items.count < 20, !title.isEmpty, validMagnet != nil || validURL != nil else { return }
    // Download links may contain provider passkeys. Never display or persist them.
    items.append(
      TorrentDiscoveryItem(
        id: source.id.uuidString + ":" + String(items.count) + ":" + title,
        title: title, provider: source.name, sourceURL: source.endpoint,
        license: "Rights depend on your source",
        torrentURL: validURL, magnet: validMagnet, size: size, seeders: seeders))
  }
}

@MainActor
final class TorrentDiscoveryModel: ObservableObject {
  @Published private(set) var sources: [TorznabSource] = []
  @Published private(set) var results: [TorrentDiscoveryItem] = TorrentDiscoveryService.openMovies
  @Published private(set) var failures: [String] = []
  @Published private(set) var searching = false
  @Published var selectedProvider = "open"
  @Published var query = ""
  @Published var error: String?
  @Published private(set) var page = 1
  @Published private(set) var hasMore = false
  var storageURL: URL?
  private var task: Task<Void, Never>?
  private var generation = UUID()
  func load() throws {
    if let storageURL, FileManager.default.fileExists(atPath: storageURL.path) {
      let data = try Data(contentsOf: storageURL)
      guard data.count < 1024 * 1024 else { throw TorrentError.invalidSettings }
      sources = try JSONDecoder().decode([TorznabSource].self, from: data)
      for source in sources {
        _ = try TorznabSource.validatedEndpoint(source.endpoint.absoluteString)
      }
    }
  }
  func addSource(name: String, endpoint: String, key: String) throws {
    guard sources.count < 10, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw TorrentError.invalidSettings
    }
    let source = TorznabSource(
      name: String(name.prefix(100)), endpoint: try TorznabSource.validatedEndpoint(endpoint))
    try TorznabKeyStore.save(key.trimmingCharacters(in: .whitespacesAndNewlines), id: source.id)
    sources.append(source)
    do { try persist() } catch {
      sources.removeAll { $0.id == source.id }
      try? TorznabKeyStore.save("", id: source.id)
      throw error
    }
  }
  func removeSource(_ source: TorznabSource) throws {
    cancel()
    try TorznabKeyStore.save("", id: source.id)
    sources.removeAll { $0.id == source.id }
    try persist()
    if selectedProvider == source.id.uuidString {
      selectedProvider = "open"
      search()
    }
  }
  private func persist() throws {
    guard let storageURL else { throw TorrentError.database("Torrent storage is not ready.") }
    try JSONEncoder().encode(sources).write(to: storageURL, options: .atomic)
  }
  func cancel() {
    generation = UUID()
    task?.cancel()
    task = nil
    searching = false
  }
  func search(more: Bool = false) {
    cancel()
    let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard text.count <= 200 else {
      error = "Keep the query under 200 characters."
      return
    }
    if !more {
      page = 1
      results = []
      failures = []
    } else {
      page += 1
    }
    hasMore = false
    if selectedProvider == "open" {
      results = TorrentDiscoveryService.openMovies.filter {
        text.isEmpty || $0.title.localizedCaseInsensitiveContains(text)
      }
      return
    }
    guard text.count >= 3 else {
      error = "Enter at least three characters and press Return."
      return
    }
    let id = generation
    let currentPage = page
    let provider = selectedProvider
    let configured = sources
    searching = true
    task = Task { [weak self] in
      guard let self else { return }
      let chosen = configured.filter { provider == "all" || provider == $0.id.uuidString }
      if provider == "archive" || provider == "all" {
        do {
          let data = try await TorrentDiscoveryService.fetch(
            TorrentDiscoveryService.archiveURL(query: text, page: currentPage))
          let items = try TorrentDiscoveryService.parseArchive(data)
          guard self.generation == id, !Task.isCancelled else { return }
          self.results += items.filter { item in !self.results.contains { $0.id == item.id } }
          self.hasMore = items.count == 20
        } catch {
          guard self.generation == id, !Task.isCancelled else { return }
          self.failures.append("Internet Archive unavailable. Try again later.")
        }
      }
      for source in chosen {
        do {
          let key = try TorznabKeyStore.read(source.id)
          let url = try TorrentDiscoveryService.torznabURL(
            source: source, key: key, query: text, page: currentPage)
          let data = try await TorrentDiscoveryService.fetch(url)
          let items = try TorrentDiscoveryService.parseTorznab(data, source: source)
          guard self.generation == id, !Task.isCancelled else { return }
          self.results += items.filter { item in !self.results.contains { $0.id == item.id } }
          self.hasMore = self.hasMore || items.count == 20
        } catch {
          guard self.generation == id, !Task.isCancelled else { return }
          self.failures.append(
            source.name + " unavailable. Check its endpoint and API key in Settings.")
        }
      }
      if self.generation == id { self.searching = false }
    }
  }
}

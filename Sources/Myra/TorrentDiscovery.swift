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

final class TorrentRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
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
  static func torznabURL(
    source: TorznabSource, key: String, query: String, page: Int, limit: Int = 20
  ) throws -> URL {
    _ = try TorznabSource.validatedEndpoint(source.endpoint.absoluteString)
    var url = URLComponents(url: source.endpoint, resolvingAgainstBaseURL: false)!
    url.queryItems =
      (url.queryItems ?? []).filter {
        !["t", "q", "apikey", "offset", "limit", "extended"].contains($0.name.lowercased())
      } + [
        .init(name: "t", value: "search"), .init(name: "q", value: query),
        .init(name: "offset", value: String((max(1, page) - 1) * limit)),
        .init(name: "limit", value: String(limit)),
        .init(name: "extended", value: "1"), .init(name: "apikey", value: key),
      ]
    return url.url!
  }
}

import Foundation

@testable import Myra

/// An in-process Apache-style directory server for tests. Each test registers its own host, so
/// fixtures stay isolated even when tests run in parallel. No socket is opened.
final class FixtureDirectoryServer: @unchecked Sendable {
  enum Fault: Sendable {
    case status(Int)
    case offline
  }

  private struct Page {
    var html: String
    var version: Int
  }

  let host: String
  private let lock = NSLock()
  private var pages: [String: Page] = [:]
  private var faults: [String: Fault] = [:]
  private var counts: [String: Int] = [:]
  private var latency: TimeInterval = 0
  private var notModifiedCount = 0
  private var totalRequests = 0

  nonisolated(unsafe) private static var servers: [String: FixtureDirectoryServer] = [:]
  private static let registry = NSLock()

  init(host: String = "fixture-\(UUID().uuidString.prefix(8).lowercased()).example") {
    self.host = host
    Self.registry.lock()
    Self.servers[host] = self
    Self.registry.unlock()
  }

  deinit {
    Self.registry.lock()
    Self.servers[host] = nil
    Self.registry.unlock()
  }

  static func server(for host: String?) -> FixtureDirectoryServer? {
    registry.lock()
    defer { registry.unlock() }
    return host.flatMap { servers[$0] }
  }

  func rootURL(_ name: String) -> URL { URL(string: "https://\(host)/\(name)/")! }

  func session() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [FixtureDirectoryProtocol.self]
    return URLSession(configuration: configuration)
  }

  /// Publishes listings for every folder that contains one of `files` (path relative to the root).
  func publish(root: URL, files: [String]) {
    var folders: [String: (folders: Set<String>, files: [String])] = ["": ([], [])]
    for path in files {
      let parts = path.split(separator: "/").map(String.init)
      var prefix = ""
      for (offset, part) in parts.enumerated() {
        if offset == parts.count - 1 {
          folders[prefix, default: ([], [])].files.append(part)
        } else {
          folders[prefix, default: ([], [])].folders.insert(part)
          prefix += part + "/"
          folders[prefix, default: ([], [])] = folders[prefix] ?? ([], [])
        }
      }
    }
    lock.lock()
    defer { lock.unlock() }
    for (prefix, content) in folders {
      var html = "<html><body><table><tr><td><a href=\"../\">Parent Directory</a></td></tr>"
      for folder in content.folders.sorted() {
        html += "<tr><td><a href=\"\(folder)/\">\(folder)/</a></td><td>2024-01-01 10:00</td><td>-</td></tr>"
      }
      for file in content.files.sorted() {
        html += "<tr><td><a href=\"\(file)\">\(file)</a></td><td>2024-01-01 10:00</td><td>1.2G</td></tr>"
      }
      html += "</table></body></html>"
      let key = root.appending(path: prefix).absoluteString
      pages[key] = Page(html: html, version: (pages[key]?.version ?? 0) + 1)
    }
  }

  func addFile(root: URL, path: String) {
    // Rebuilds only the affected listing: used to model a new file appearing on the server.
    let parts = path.split(separator: "/").map(String.init)
    let folder = parts.dropLast().joined(separator: "/")
    let key = root.appending(path: folder.isEmpty ? "" : folder + "/").absoluteString
    lock.lock()
    defer { lock.unlock() }
    guard var page = pages[key] else { return }
    let name = parts.last ?? path
    page.html = page.html.replacingOccurrences(
      of: "</table>",
      with: "<tr><td><a href=\"\(name)\">\(name)</a></td><td>2024-01-01 10:00</td><td>1.2G</td></tr></table>")
    page.version += 1
    pages[key] = page
  }

  func setFault(_ fault: Fault?, forPrefix prefix: URL) {
    lock.lock()
    defer { lock.unlock() }
    faults[prefix.absoluteString] = fault
  }

  func setLatency(_ seconds: TimeInterval) {
    lock.lock()
    defer { lock.unlock() }
    latency = seconds
  }

  func requests(for url: URL) -> Int {
    lock.lock()
    defer { lock.unlock() }
    return counts[url.absoluteString] ?? 0
  }
  var requestCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return totalRequests
  }
  var notModified: Int {
    lock.lock()
    defer { lock.unlock() }
    return notModifiedCount
  }

  enum Outcome {
    case response(Int, [String: String], Data)
    case offline
  }

  func respond(to request: URLRequest) -> (Outcome, TimeInterval) {
    lock.lock()
    defer { lock.unlock() }
    guard let url = request.url else { return (.response(400, [:], Data()), 0) }
    totalRequests += 1
    counts[url.absoluteString, default: 0] += 1
    for (prefix, fault) in faults where url.absoluteString.hasPrefix(prefix) {
      switch fault {
      case .status(let code): return (.response(code, [:], Data()), latency)
      case .offline: return (.offline, latency)
      }
    }
    guard let page = pages[url.absoluteString] else { return (.response(404, [:], Data()), latency) }
    let tag = "\"v\(page.version)\""
    if request.value(forHTTPHeaderField: "If-None-Match") == tag {
      notModifiedCount += 1
      return (.response(304, ["ETag": tag], Data()), latency)
    }
    return (.response(200, ["ETag": tag, "Content-Type": "text/html"], Data(page.html.utf8)), latency)
  }
}

final class FixtureDirectoryProtocol: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool {
    FixtureDirectoryServer.server(for: request.url?.host) != nil
  }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    guard let url = request.url, let server = FixtureDirectoryServer.server(for: url.host) else {
      client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
      return
    }
    let (outcome, delay) = server.respond(to: request)
    let deliver = { [self] in
      switch outcome {
      case .offline:
        client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
      case .response(let status, let headers, let data):
        let response = HTTPURLResponse(
          url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
      }
    }
    if delay > 0 {
      DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: deliver)
    } else {
      deliver()
    }
  }
  override func stopLoading() {}
}

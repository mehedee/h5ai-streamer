import SwiftUI
import XCTest

@testable import Myra

// MARK: - Test doubles

/// In-memory stand-in for the Keychain. Records whether any read happened on the main thread.
private final class FakeSecrets: IndexerSecretStore, @unchecked Sendable {
  private let lock = NSLock()
  private var values: [UUID: String] = [:]
  private var mainThreadAccess = false
  func key(for id: UUID) throws -> String {
    lock.lock(); defer { lock.unlock() }
    if Thread.isMainThread { mainThreadAccess = true }
    return values[id] ?? ""
  }
  func setKey(_ value: String, for id: UUID) throws {
    lock.lock(); defer { lock.unlock() }
    if Thread.isMainThread { mainThreadAccess = true }
    values[id] = value.isEmpty ? nil : value
  }
  /// Test setup only; not counted as app access.
  func preload(_ value: String, for id: UUID) { lock.lock(); values[id] = value; lock.unlock() }
  var touchedMainThread: Bool { lock.lock(); defer { lock.unlock() }; return mainThreadAccess }
  var stored: [UUID: String] { lock.lock(); defer { lock.unlock() }; return values }
}

private enum StubReply {
  case response(status: Int, body: String)
  case hang
}

/// URLProtocol that answers by host, never touching the network.
private final class StubProtocol: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) private static var handlers: [String: @Sendable (URLRequest) -> StubReply] = [:]
  nonisolated(unsafe) private static var log: [URLRequest] = []
  private static let lock = NSLock()

  static func reset() { lock.lock(); handlers = [:]; log = []; lock.unlock() }
  static func set(_ host: String, _ handler: @escaping @Sendable (URLRequest) -> StubReply) {
    lock.lock(); handlers[host] = handler; lock.unlock()
  }
  static func requests(host: String) -> [URLRequest] {
    lock.lock(); defer { lock.unlock() }
    return log.filter { $0.url?.host == host }
  }
  static var requestCount: Int { lock.lock(); defer { lock.unlock() }; return log.count }
  static func configuration() -> URLSessionConfiguration {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubProtocol.self]
    return config
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    Self.lock.lock()
    Self.log.append(request)
    let handler = Self.handlers[request.url?.host ?? ""]
    Self.lock.unlock()
    guard let handler else {
      client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
      return
    }
    switch handler(request) {
    case .hang: return
    case .response(let status, let body):
      let response = HTTPURLResponse(
        url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: Data(body.utf8))
      client?.urlProtocolDidFinishLoading(self)
    }
  }
  override func stopLoading() {}
}

// MARK: - Fixtures

private enum Feed {
  static let hashA = String(repeating: "a", count: 40)
  static let hashB = String(repeating: "b", count: 40)
  static let hashC = String(repeating: "c", count: 40)

  static func item(
    _ title: String, hash: String? = nil, seeders: Int? = nil, peers: Int? = nil,
    size: Int64? = nil, magnet: String? = nil, link: String? = nil
  ) -> String {
    var xml = "<item><title>\(title)</title><pubDate>Mon, 05 Oct 2026 10:00:00 +0000</pubDate>"
    if let link { xml += "<enclosure url=\"\(link)\" length=\"\(size ?? 0)\" type=\"application/x-bittorrent\"/>" }
    if let hash { xml += "<torznab:attr name=\"infohash\" value=\"\(hash)\"/>" }
    if let magnet { xml += "<torznab:attr name=\"magneturl\" value=\"\(magnet)\"/>" }
    if let seeders { xml += "<torznab:attr name=\"seeders\" value=\"\(seeders)\"/>" }
    if let peers { xml += "<torznab:attr name=\"peers\" value=\"\(peers)\"/>" }
    if let size { xml += "<torznab:attr name=\"size\" value=\"\(size)\"/>" }
    return xml + "</item>"
  }

  static func rss(_ items: String...) -> String {
    "<?xml version=\"1.0\"?><rss version=\"2.0\" xmlns:torznab=\"http://torznab.com/schemas/2015/feed\"><channel><title>x</title>"
      + items.joined() + "</channel></rss>"
  }

  static let valid = rss(
    item("Sintel 2010 1080p BluRay", hash: hashA, seeders: 40, peers: 55, size: 1_500_000_000,
      link: "https://idx.example/dl?id=1&amp;passkey=SECRETPASS"),
    item("Sintel 2010 720p", seeders: 8, peers: 9, size: 700_000_000,
      magnet: "magnet:?xt=urn:btih:\(hashB)&amp;dn=Sintel"))

  static let caps =
    "<caps><searching><search available=\"yes\"/><tv-search available=\"yes\"/><movie-search available=\"yes\"/><audio-search available=\"no\"/></searching></caps>"
  static let unauthorized = "<error code=\"100\" description=\"Incorrect user credentials\"/>"
}

private func torznabIndexer(
  _ name: String, host: String, enabled: Bool = true
) -> TorrentIndexer {
  TorrentIndexer(
    id: UUID(), name: name, kind: .torznab, url: URL(string: "https://\(host)/api")!,
    enabled: enabled, isBuiltIn: false)
}

private func result(
  _ title: String, indexer: String = "A", seeders: Int? = nil, size: Int64? = nil,
  hash: String? = nil, id: String? = nil
) -> TorrentSearchResult {
  TorrentSearchResult(
    id: id ?? indexer + title, title: title, indexerID: UUID(), indexerName: indexer, size: size,
    seeders: seeders, infohash: hash)
}

// MARK: - Tests

final class TorrentSearchTests: XCTestCase {
  override func setUp() { StubProtocol.reset() }

  // MARK: Torznab parsing

  func testParsesSeedersPeersSizeInfohashAndMagnet() throws {
    let indexer = torznabIndexer("Fixture", host: "idx.example")
    let feed = try TorznabParser.parse(Data(Feed.valid.utf8), indexer: indexer)
    XCTAssertEqual(feed.results.count, 2)
    let first = feed.results[0]
    XCTAssertEqual(first.seeders, 40)
    XCTAssertEqual(first.leechers, 15)
    XCTAssertEqual(first.size, 1_500_000_000)
    XCTAssertEqual(first.infohash, Feed.hashA)
    XCTAssertNotNil(first.torrentURL)
    XCTAssertNotNil(first.published)
    XCTAssertEqual(first.quality, .p1080)
    // The passkey-bearing link is kept for the fetch only: never in the source link or magnet.
    XCTAssertFalse(first.sourceURL?.absoluteString.contains("SECRET") ?? false)
    XCTAssertFalse(first.shareableMagnet?.contains("SECRET") ?? true)
    XCTAssertTrue(first.shareableMagnet?.contains("urn:btih:" + Feed.hashA) == true)
    let second = feed.results[1]
    XCTAssertEqual(second.infohash, Feed.hashB, "info hash is taken from the magnet")
    XCTAssertEqual(second.magnet, "magnet:?xt=urn:btih:\(Feed.hashB)&dn=Sintel")
    XCTAssertTrue(feed.results.allSatisfy { $0.indexerName == "Fixture" })
  }

  func testParsesCapabilities() throws {
    let feed = try TorznabParser.parse(
      Data(Feed.caps.utf8), indexer: torznabIndexer("C", host: "idx.example"))
    XCTAssertEqual(feed.capabilities, ["search", "TV", "movies"])
  }

  func testBase32InfohashIsNormalised() {
    // 20 zero bytes in base32.
    let base32 = String(repeating: "a", count: 32)
    XCTAssertEqual(TorznabParser.normalizedInfohash(base32), String(repeating: "0", count: 40))
    XCTAssertNil(TorznabParser.normalizedInfohash("not-a-hash"))
    XCTAssertEqual(
      TorznabParser.normalizedInfohash(Feed.hashA.uppercased()), Feed.hashA)
  }

  func testPartialFeedSkipsBrokenItemsAndKeepsGoodOnes() throws {
    let xml = Feed.rss(
      Feed.item("Good one 1080p", hash: Feed.hashA, seeders: 3),
      "<item><title></title></item>",
      "<item><title>No link at all</title></item>",
      Feed.item("Unsafe link", link: "file:///etc/passwd"),
      Feed.item("Second good", hash: Feed.hashB, seeders: 1))
    let feed = try TorznabParser.parse(
      Data(xml.utf8), indexer: torznabIndexer("P", host: "idx.example"))
    XCTAssertEqual(feed.results.map(\.title), ["Good one 1080p", "Second good"])
    XCTAssertFalse(feed.truncated)
  }

  func testTruncatedFeedKeepsEarlierItemsButEmptyOneFails() throws {
    let full = Feed.rss(Feed.item("Kept", hash: Feed.hashA, seeders: 2), Feed.item("Cut", hash: Feed.hashB))
    let cut = String(full.prefix(full.count - 60))
    let indexer = torznabIndexer("T", host: "idx.example")
    let feed = try TorznabParser.parse(Data(cut.utf8), indexer: indexer)
    XCTAssertEqual(feed.results.map(\.title), ["Kept"])
    XCTAssertTrue(feed.truncated)
    XCTAssertThrowsError(
      try TorznabParser.parse(Data("<rss><channel><item><title>x".utf8), indexer: indexer))
  }

  func testMalformedAndHostileResponsesMapToClearFailures() {
    let indexer = torznabIndexer("M", host: "idx.example")
    func failure(_ body: String) -> TorrentSearchFailure? {
      do { _ = try TorznabParser.parse(Data(body.utf8), indexer: indexer); return nil } catch {
        return error as? TorrentSearchFailure
      }
    }
    XCTAssertEqual(failure("<html><body>Login</body></html>"), .notTorznab)
    XCTAssertEqual(failure("this is not xml"), .notTorznab)
    XCTAssertEqual(failure(""), .notTorznab)
    XCTAssertEqual(failure(Feed.unauthorized), .badKey)
    XCTAssertEqual(
      failure("<error code=\"201\" description=\"Incorrect parameter\"/>"),
      .provider(code: 201, text: "Incorrect parameter"))
    XCTAssertEqual(
      failure("<!DOCTYPE rss [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><rss>&x;</rss>"),
      .notTorznab)
    XCTAssertEqual(
      failure(String(repeating: "x", count: TorznabParser.maxBytes + 1)), .tooLarge)
    for failure in [
      TorrentSearchFailure.badKey, .timeout, .unreachable, .notTorznab, .http(500),
      .provider(code: 1, text: ""), .keychain, .invalidEndpoint, .tooLarge,
    ] {
      XCTAssertFalse(failure.message.isEmpty)
    }
  }

  // MARK: Engine, parallelism, partial results, retry

  @MainActor
  private func makeModel(
    custom: [TorrentIndexer], secrets: FakeSecrets = FakeSecrets(), builtIns: Bool = false,
    timeout: TimeInterval = 0.4
  ) -> (TorrentSearchModel, TorrentIndexerStore, FakeSecrets) {
    let store = TorrentIndexerStore(secrets: secrets)
    var list = builtIns ? TorrentIndexer.builtIns : []
    list += custom
    store.replaceForTesting(list)
    var engine = TorrentSearchEngine(secrets: secrets)
    engine.timeout = timeout
    engine.configuration = { StubProtocol.configuration() }
    return (TorrentSearchModel(store: store, engine: engine), store, secrets)
  }

  @MainActor
  func testNothingIsSentUntilSearchIsPressed() async {
    let idx = torznabIndexer("Quiet", host: "quiet.example")
    StubProtocol.set("quiet.example") { _ in .response(status: 200, body: Feed.valid) }
    let (model, _, _) = makeModel(custom: [idx])
    model.query = "sintel"
    XCTAssertEqual(StubProtocol.requestCount, 0)
    model.query = "x"
    model.search()
    XCTAssertNotNil(model.notice, "a one-character query is refused locally")
    XCTAssertEqual(StubProtocol.requestCount, 0)
    XCTAssertEqual(model.phase, .idle)
  }

  @MainActor
  func testParallelSearchGivesPartialResultsAndPerIndexerStatus() async throws {
    let good = torznabIndexer("Good", host: "good.example")
    let badKey = torznabIndexer("BadKey", host: "badkey.example")
    let slow = torznabIndexer("Slow", host: "slow.example")
    let junk = torznabIndexer("Junk", host: "junk.example")
    StubProtocol.set("good.example") { _ in .response(status: 200, body: Feed.valid) }
    StubProtocol.set("badkey.example") { _ in .response(status: 401, body: "") }
    StubProtocol.set("slow.example") { _ in .hang }
    StubProtocol.set("junk.example") { _ in .response(status: 200, body: "<html>nope</html>") }
    let secrets = FakeSecrets()
    secrets.preload("GOODKEY", for: good.id)
    let (model, _, _) = makeModel(
      custom: [good, badKey, slow, junk], secrets: secrets, builtIns: true)
    model.query = "Sintel"
    let started = Date()
    model.search()
    XCTAssertTrue(model.isSearching)
    await model.waitForSearch()
    // The hung indexer timed out on its own deadline without holding up the others.
    XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    XCTAssertEqual(model.phase, .done)
    func state(_ name: String) -> IndexerRunState? { model.statuses.first { $0.name == name }?.state }
    XCTAssertEqual(state("Good"), .finished(count: 2))
    XCTAssertEqual(state("BadKey"), .failed(.badKey))
    XCTAssertEqual(state("Slow"), .failed(.timeout))
    XCTAssertEqual(state("Junk"), .failed(.notTorznab))
    // Blender (offline curated) and Internet Archive (stubbed as unreachable) are separate rows.
    XCTAssertEqual(state("Blender Open Movies"), .finished(count: 1))
    if case .failed(.unreachable) = state("Internet Archive") {} else {
      XCTFail("Archive should be reported as unreachable")
    }
    XCTAssertEqual(
      Set(model.collected.map(\.indexerName)), ["Good", "Blender Open Movies"])
    XCTAssertEqual(model.failedStatuses.count, 4)
    // The API key travelled as the apikey query item and was read off the main thread.
    let request = try XCTUnwrap(StubProtocol.requests(host: "good.example").first)
    let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
    XCTAssertEqual(items?.first { $0.name == "apikey" }?.value, "GOODKEY")
    XCTAssertEqual(items?.first { $0.name == "q" }?.value, "Sintel")
    XCTAssertFalse(secrets.touchedMainThread)
  }

  @MainActor
  func testRetryRerunsOnlyFailedIndexersAndMergesResults() async {
    let steady = torznabIndexer("Steady", host: "steady.example")
    let flaky = torznabIndexer("Flaky", host: "flaky.example")
    let online = Locked(false)
    StubProtocol.set("steady.example") { _ in
      .response(status: 200, body: Feed.rss(Feed.item("Steady 1080p", hash: Feed.hashA, seeders: 5)))
    }
    StubProtocol.set("flaky.example") { _ in
      online.value
        ? .response(status: 200, body: Feed.rss(Feed.item("Flaky 720p", hash: Feed.hashB, seeders: 9)))
        : .response(status: 503, body: "")
    }
    let (model, _, _) = makeModel(custom: [steady, flaky])
    model.query = "movie"
    model.search()
    await model.waitForSearch()
    XCTAssertEqual(model.collected.map(\.title), ["Steady 1080p"])
    XCTAssertEqual(model.failedStatuses.map(\.name), ["Flaky"])
    XCTAssertEqual(model.failedStatuses.first?.state, .failed(.http(503)))
    online.value = true
    let steadyBefore = StubProtocol.requests(host: "steady.example").count
    model.retryFailed()
    await model.waitForSearch()
    XCTAssertEqual(StubProtocol.requests(host: "steady.example").count, steadyBefore)
    XCTAssertEqual(Set(model.collected.map(\.title)), ["Steady 1080p", "Flaky 720p"])
    XCTAssertTrue(model.failedStatuses.isEmpty)
  }

  @MainActor
  func testDisabledIndexersAreNotQueriedAndNoneEnabledIsReported() async {
    let off = torznabIndexer("Off", host: "off.example", enabled: false)
    StubProtocol.set("off.example") { _ in .response(status: 200, body: Feed.valid) }
    let (model, _, _) = makeModel(custom: [off])
    model.query = "sintel"
    model.search()
    XCTAssertEqual(model.notice, "Turn on at least one indexer to search.")
    XCTAssertEqual(StubProtocol.requestCount, 0)
  }

  @MainActor
  func testInternetArchiveAndBlenderBuiltIns() async {
    StubProtocol.set("archive.org") { request in
      XCTAssertEqual(request.url?.path, "/advancedsearch.php")
      return .response(
        status: 200,
        body:
          #"{"response":{"docs":[{"identifier":"sintel-pd","title":"Sintel (open)","licenseurl":"https://creativecommons.org/licenses/by/3.0/"},{"identifier":"closed","title":"Closed","licenseurl":"https://example.org/x"}]}}"#
      )
    }
    let (model, _, _) = makeModel(custom: [], builtIns: true)
    model.query = "sintel"
    model.search()
    await model.waitForSearch()
    XCTAssertEqual(Set(model.collected.map(\.indexerName)), ["Internet Archive", "Blender Open Movies"])
    let archive = model.collected.first { $0.archiveID == "sintel-pd" }
    XCTAssertNotNil(archive)
    XCTAssertNotNil(archive?.license)
    XCTAssertTrue(archive?.isActionable == true)
    let blender = model.collected.first { $0.indexerName == "Blender Open Movies" }
    XCTAssertEqual(blender?.title, "Sintel")
    XCTAssertEqual(blender?.torrentURL?.host, "webtorrent.io")
    XCTAssertNil(blender?.shareableMagnet)
  }

  func testTestConnectionReportsCapabilitiesAndMapsFailures() async throws {
    StubProtocol.set("ok.example") { request in
      let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
      XCTAssertEqual(query?.first { $0.name == "t" }?.value, "caps")
      return query?.first { $0.name == "apikey" }?.value == "good"
        ? .response(status: 200, body: Feed.caps) : .response(status: 200, body: Feed.unauthorized)
    }
    var engine = TorrentSearchEngine(secrets: FakeSecrets())
    engine.configuration = { StubProtocol.configuration() }
    let endpoint = URL(string: "https://ok.example/api")!
    let outcome = try await engine.test(endpoint: endpoint, key: "good")
    XCTAssertEqual(outcome.capabilities, ["search", "TV", "movies"])
    do {
      _ = try await engine.test(endpoint: endpoint, key: "wrong")
      XCTFail("expected bad key")
    } catch { XCTAssertEqual(error as? TorrentSearchFailure, .badKey) }
    do {
      _ = try await engine.test(endpoint: URL(string: "http://public.example/api")!, key: "x")
      XCTFail("plain http to a public host must be refused")
    } catch { XCTAssertEqual(error as? TorrentSearchFailure, .invalidEndpoint) }
  }

  // MARK: De-duplication, filters, sort

  func testDedupeByInfohashKeepsBestSeedersAndFillsLinks() {
    var a = result("Sintel 1080p", indexer: "A", seeders: 5, hash: Feed.hashA)
    a.torrentURL = URL(string: "https://a.example/dl")
    var b = result("Sintel.1080p.x264", indexer: "B", seeders: 30, hash: Feed.hashA)
    b.magnet = "magnet:?xt=urn:btih:\(Feed.hashA)"
    let c = result("Other", indexer: "A", seeders: 1, hash: Feed.hashC)
    let merged = TorrentSearchDeduper.merge([a, c, b])
    XCTAssertEqual(merged.count, 2)
    let sintel = merged.first { $0.infohash == Feed.hashA }
    XCTAssertEqual(sintel?.indexerName, "B")
    XCTAssertEqual(sintel?.seeders, 30)
    XCTAssertEqual(sintel?.torrentURL?.host, "a.example")
    XCTAssertEqual(sintel?.alsoFrom, ["A"])
    XCTAssertEqual(merged.map(\.infohash), [Feed.hashA, Feed.hashC], "first-seen order is kept")
  }

  func testDedupeFallsBackToTitleAndSizeWithoutHash() {
    let a = result("Some Movie (2020)", indexer: "A", seeders: 2, size: 100)
    let b = result("some.movie.2020", indexer: "B", seeders: 9, size: 100)
    let different = result("some.movie.2020", indexer: "B", seeders: 9, size: 200, id: "x")
    XCTAssertEqual(TorrentSearchDeduper.merge([a, b]).count, 1)
    XCTAssertEqual(TorrentSearchDeduper.merge([a, different]).count, 2)
  }

  func testQualityParsedFromTitle() {
    XCTAssertEqual(TorrentQuality.parse("Movie.2020.2160p.WEB"), .p2160)
    XCTAssertEqual(TorrentQuality.parse("Movie 4K HDR"), .p2160)
    XCTAssertEqual(TorrentQuality.parse("Movie (2020) 1080p"), .p1080)
    XCTAssertEqual(TorrentQuality.parse("Movie_720p_x265"), .p720)
    XCTAssertEqual(TorrentQuality.parse("Movie 480p"), .p480)
    XCTAssertNil(TorrentQuality.parse("Movie 1080 pages"))
    XCTAssertNil(TorrentQuality.parse("Movie 21080p0"))
    XCTAssertNil(TorrentQuality.parse("Sintel"))
  }

  func testFiltersAndSortOrders() {
    let all = [
      result("Alpha 1080p", seeders: 10, size: 500),
      result("Beta 720p", seeders: 100, size: 100),
      result("Gamma 2160p", seeders: 0, size: 900),
      result("Delta", seeders: 50, size: 300),
      result("Open film 1080p", indexer: "Archive", seeders: nil, size: nil),
    ]
    var filter = TorrentSearchFilter()
    XCTAssertEqual(filter.apply(all).map(\.title),
      ["Beta 720p", "Delta", "Alpha 1080p", "Open film 1080p"], "min seeders 1 hides zero; unknown passes")
    filter.sort = .size
    XCTAssertEqual(filter.apply(all).map(\.title),
      ["Alpha 1080p", "Delta", "Beta 720p", "Open film 1080p"])
    filter.sort = .name
    XCTAssertEqual(filter.apply(all).map(\.title),
      ["Alpha 1080p", "Beta 720p", "Delta", "Open film 1080p"])
    filter.minSeeders = 20
    XCTAssertEqual(filter.apply(all).map(\.title), ["Beta 720p", "Delta", "Open film 1080p"])
    filter.qualities = [.p1080]
    XCTAssertEqual(filter.apply(all).map(\.title), ["Open film 1080p"])
    filter.minSeeders = 1
    filter.qualities = [.p1080, .p2160]
    XCTAssertEqual(filter.apply(all).map(\.title), ["Alpha 1080p", "Open film 1080p"])
    XCTAssertFalse(filter.isDefault)
  }

  @MainActor
  func testFilterChangesApplyToCollectedResultsWithoutANewSearch() async {
    let idx = torznabIndexer("F", host: "f.example")
    StubProtocol.set("f.example") { _ in
      .response(status: 200, body: Feed.rss(
        Feed.item("A 1080p", hash: Feed.hashA, seeders: 9), Feed.item("B 720p", hash: Feed.hashB, seeders: 3)))
    }
    let (model, _, _) = makeModel(custom: [idx])
    model.query = "movie"
    model.search()
    await model.waitForSearch()
    let requests = StubProtocol.requestCount
    XCTAssertEqual(model.visible.count, 2)
    model.filter.qualities = [.p720]
    XCTAssertEqual(model.visible.map(\.title), ["B 720p"])
    model.resetFilters()
    XCTAssertEqual(model.visible.count, 2)
    XCTAssertEqual(StubProtocol.requestCount, requests)
  }

  func testMagnetIsBuiltFromInfohashWhenOnlyTheHashIsKnown() {
    let item = result("Sintel & Co", hash: Feed.hashA)
    let magnet = item.shareableMagnet
    XCTAssertTrue(magnet?.hasPrefix("magnet:?xt=urn:btih:" + Feed.hashA) == true)
    XCTAssertNotNil(magnet.flatMap { try? TorrentIdentity(magnet: $0) })
    XCTAssertNil(result("No hash").shareableMagnet)
    XCTAssertFalse(result("No hash").isActionable)
  }

  // MARK: Indexer store and Add Indexer validation

  func testDraftValidation() {
    let existing = TorrentIndexer.builtIns + [torznabIndexer("Mine", host: "mine.example")]
    func problem(_ draft: IndexerDraft) -> IndexerDraft.Problem? {
      do { _ = try draft.validated(existing: existing); return nil } catch {
        return error as? IndexerDraft.Problem
      }
    }
    XCTAssertEqual(problem(IndexerDraft(name: " ", url: "https://x.example/api")), .emptyName)
    XCTAssertEqual(problem(IndexerDraft(name: "N", url: "http://public.example/api")), .invalidURL)
    XCTAssertEqual(problem(IndexerDraft(name: "N", url: "https://x.example/api?apikey=abc")), .invalidURL)
    XCTAssertEqual(problem(IndexerDraft(name: "N", url: "https://u:p@x.example/api")), .invalidURL)
    XCTAssertEqual(problem(IndexerDraft(name: "mine", url: "https://other.example/api")), .duplicate)
    XCTAssertEqual(problem(IndexerDraft(name: "Other", url: "https://mine.example/api")), .duplicate)
    XCTAssertNil(problem(IndexerDraft(name: "Local", url: "http://localhost:9117/api")))
    XCTAssertNil(problem(IndexerDraft(name: "Remote", url: "https://x.example/api")))
    let full = TorrentIndexer.builtIns
      + (0..<IndexerDraft.maxCustom).map { torznabIndexer("N\($0)", host: "h\($0).example") }
    XCTAssertThrowsError(
      try IndexerDraft(name: "One more", url: "https://z.example/api").validated(existing: full))
  }

  func testPresetsOnlyFillLocalhostAddresses() {
    for preset in IndexerDraft.Preset.allCases {
      var draft = IndexerDraft()
      draft.apply(preset)
      XCTAssertEqual(URL(string: draft.url)?.host, "localhost")
      XCTAssertNoThrow(try TorznabSource.validatedEndpoint(draft.url))
      XCTAssertTrue(draft.key.isEmpty)
    }
  }

  @MainActor
  func testAddingStoresKeyOnlyInKeychainAndPersistsTheListWithoutIt() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "Myra-indexers-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let secrets = FakeSecrets()
    let store = TorrentIndexerStore(secrets: secrets)
    store.storageURL = directory.appending(path: "indexers.json")
    try store.load()
    XCTAssertEqual(store.indexers.map(\.name), ["Internet Archive", "Blender Open Movies"])
    let added = try await store.add(
      IndexerDraft(name: "Jackett", url: "http://localhost:9117/api/v2.0/indexers/all/results/torznab/", key: "  TOPSECRET  "))
    XCTAssertEqual(secrets.stored[added.id], "TOPSECRET")
    XCTAssertFalse(secrets.touchedMainThread)
    let json = try String(contentsOf: directory.appending(path: "indexers.json"), encoding: .utf8)
    XCTAssertFalse(json.contains("TOPSECRET"))
    XCTAssertTrue(json.contains("Jackett"))
    do {
      _ = try await store.add(IndexerDraft(name: "jackett", url: "https://other.example/api", key: "k"))
      XCTFail("duplicate name must be refused")
    } catch { XCTAssertEqual(error as? IndexerDraft.Problem, .duplicate) }
    store.setEnabled(false, for: TorrentIndexer.internetArchiveID)
    store.setEnabled(false, for: added.id)

    let reloaded = TorrentIndexerStore(secrets: secrets)
    reloaded.storageURL = store.storageURL
    try reloaded.load()
    XCTAssertEqual(reloaded.indexers.count, 3)
    XCTAssertFalse(reloaded.indexers[0].enabled)
    XCTAssertTrue(reloaded.indexers[1].enabled)
    XCTAssertFalse(reloaded.indexers[2].enabled)
    XCTAssertEqual(reloaded.enabled.map(\.name), ["Blender Open Movies"])

    try await reloaded.remove(added.id)
    XCTAssertNil(secrets.stored[added.id], "removing an indexer deletes its key")
    XCTAssertEqual(reloaded.indexers.count, 2)
    try await reloaded.remove(TorrentIndexer.blenderID)
    XCTAssertEqual(reloaded.indexers.count, 2, "built-ins cannot be removed")
  }

  @MainActor
  func testLegacySourcesAreImportedWithTheirKeychainIds() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "Myra-legacy-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let legacy = [
      TorznabSource(name: "Old", endpoint: URL(string: "https://old.example/api")!),
      TorznabSource(name: "Bad", endpoint: URL(string: "http://public.example/api")!),
    ]
    try JSONEncoder().encode(legacy).write(to: directory.appending(path: "sources.json"))
    let store = TorrentIndexerStore(secrets: FakeSecrets())
    store.storageURL = directory.appending(path: "indexers.json")
    store.legacyURL = directory.appending(path: "sources.json")
    try store.load()
    XCTAssertEqual(store.custom.map(\.name), ["Old"], "unsafe legacy endpoints are dropped")
    XCTAssertEqual(store.custom.first?.id, legacy[0].id)
  }

  /// Renders the Search tab and Add Indexer sheet natively; PNGs are written only when
  /// MYRA_UI_SNAPSHOT_DIR is set.
  @MainActor
  func testSearchTabAndAddSheetRenderNatively() async throws {
    let good = torznabIndexer("Jackett", host: "j.example")
    let down = torznabIndexer("Prowlarr", host: "p.example")
    StubProtocol.set("j.example") { _ in
      .response(status: 200, body: Feed.rss(
        Feed.item("Sintel (2010) 1080p", hash: Feed.hashA, seeders: 212, peers: 230, size: 1_100_000_000),
        Feed.item("Sintel (2010) 4K HDR", hash: Feed.hashB, seeders: 4, peers: 9, size: 11_800_000_000)))
    }
    StubProtocol.set("p.example") { _ in .response(status: 503, body: "") }
    let (model, store, _) = makeModel(custom: [good, down], builtIns: true)
    let controller = TorrentController(
      consent: TorrentConsent(defaults: UserDefaults(suiteName: "Myra-snap-\(UUID())") ?? .standard),
      indexers: store)
    model.query = "Sintel"
    model.search()
    await model.waitForSearch()
    XCTAssertFalse(model.visible.isEmpty)
    func render(_ view: some View, size: NSSize, name: String) throws {
      let host = NSHostingView(rootView: view)
      host.frame = NSRect(origin: .zero, size: size)
      let window = NSWindow(
        contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
      window.contentView = host
      window.isReleasedWhenClosed = false
      window.orderFront(nil)
      host.layoutSubtreeIfNeeded()
      RunLoop.main.run(until: Date().addingTimeInterval(0.3))
      host.layoutSubtreeIfNeeded()
      if let path = ProcessInfo.processInfo.environment["MYRA_UI_SNAPSHOT_DIR"],
        let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)
      {
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
          .write(to: URL(fileURLWithPath: path).appending(path: name))
      }
      window.close()
    }
    try render(
      TorrentSearchView(controller: controller, model: model, store: store, onManageIndexers: {}),
      size: NSSize(width: 980, height: 640), name: "torrent-search.png")
    try render(
      AddIndexerSheet(store: store), size: NSSize(width: 480, height: 420),
      name: "torrent-add-indexer.png")
    controller.shutdown()
  }

  @MainActor
  func testSearchTabCommandSeamSwitchesTabAndRequestsFocus() {
    let controller = TorrentController(
      consent: TorrentConsent(defaults: UserDefaults(suiteName: "Myra-search-\(UUID())") ?? .standard))
    XCTAssertEqual(controller.selectedTab, .transfers)
    controller.showSearch()
    XCTAssertEqual(controller.selectedTab, .search)
    XCTAssertEqual(controller.startIntent, .play)
    controller.shutdown()
  }
}

/// Tiny lock-protected box for values flipped between test and stub threads.
private final class Locked<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Value
  init(_ value: Value) { stored = value }
  var value: Value {
    get { lock.lock(); defer { lock.unlock() }; return stored }
    set { lock.lock(); stored = newValue; lock.unlock() }
  }
}

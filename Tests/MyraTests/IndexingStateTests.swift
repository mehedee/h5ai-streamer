import XCTest

@testable import Myra

/// Phase 1: observable indexing state, per-source health, retry with backoff, pause and cancel.
/// Every test uses its own temporary index and its own in-process server host.
@MainActor
final class IndexingStateTests: XCTestCase {
  private var cleanup: [URL] = []

  override func tearDown() {
    for url in cleanup { try? FileManager.default.removeItem(at: url) }
    cleanup = []
    super.tearDown()
  }

  private func makeIndex() throws -> LibraryIndex {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "Myra-state-test-\(UUID().uuidString)", directoryHint: .isDirectory)
    cleanup.append(directory)
    return try LibraryIndex(url: directory.appending(path: "LibraryIndex.sqlite"))
  }

  private func source(_ server: FixtureDirectoryServer, _ name: String) -> GlobalSearchRoot {
    GlobalSearchRoot(id: UUID(), name: name, url: server.rootURL(name))
  }

  private func controller(
    index: LibraryIndex, server: FixtureDirectoryServer, retry: IndexRetryPolicy = .init(),
    automaticRetry: Bool = false
  ) -> LibraryController {
    LibraryController(
      index: index, directoryService: DirectoryService(session: server.session()),
      retryPolicy: retry, retryDelay: .zero, automaticRetry: automaticRetry)
  }

  private func wait(
    _ description: String, timeout: TimeInterval = 8, _ condition: () -> Bool
  ) async throws {
    let deadline = Date.now.addingTimeInterval(timeout)
    while !condition() {
      if Date.now > deadline { XCTFail("Timed out: \(description)"); return }
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  private func video(_ root: GlobalSearchRoot, _ path: String) -> GlobalSearchResult {
    let url = root.url.appending(path: path)
    return GlobalSearchResult(
      categoryID: root.id, categoryName: root.name, categoryRoot: root.url,
      entry: DirectoryEntry(
        name: (path as NSString).lastPathComponent, url: url, kind: .file, size: 1,
        modifiedAt: Date(timeIntervalSince1970: 100)), relativePath: path, artworkURL: nil)
  }

  // MARK: - Policy

  func testBackoffDoublesAndIsCapped() {
    let policy = IndexRetryPolicy(base: 60, factor: 2, maximum: 1800)
    XCTAssertEqual(policy.delay(afterFailures: 0), 0)
    XCTAssertEqual(policy.delay(afterFailures: 1), 60)
    XCTAssertEqual(policy.delay(afterFailures: 2), 120)
    XCTAssertEqual(policy.delay(afterFailures: 3), 240)
    XCTAssertEqual(policy.delay(afterFailures: 10), 1800)
  }

  // MARK: - Observable state

  func testRunPublishesSourceStateCountsAndLibraryTotal() async throws {
    let server = FixtureDirectoryServer()
    let movies = source(server, "Movies")
    let shows = source(server, "Shows")
    server.publish(
      root: movies.url,
      files: ["Action/First.Film.2020.1080p.mkv", "Action/Second.Film.2021.1080p.mkv"])
    server.publish(root: shows.url, files: ["Show/Show.S01E01.mkv"])
    let index = try makeIndex()
    let library = controller(index: index, server: server)
    XCTAssertEqual(library.refreshState, .noSources)
    library.refresh(roots: [movies, shows], manual: true)
    XCTAssertTrue(library.isRefreshing)
    XCTAssertEqual(library.indexing.sourceCount, 2)
    try await wait("run finishes") { !library.isRefreshing }
    XCTAssertEqual(library.refreshState, .completed)
    XCTAssertEqual(library.sources.map(\.state), [.ok, .ok])
    XCTAssertEqual(library.sources.map(\.videosFound), [2, 1])
    XCTAssertEqual(library.libraryTotal, 3)
    XCTAssertNotNil(library.lastRefresh)
    XCTAssertNotNil(library.sources[0].lastScan)
    XCTAssertNotNil(library.sources[0].lastSuccess)
    XCTAssertNil(library.sources[0].lastError)
    XCTAssertEqual(library.indexing, IndexingProgress(), "Idle state clears run progress")
    XCTAssertFalse(library.isCancelled)
  }

  func testProgressReportsCurrentSourceFractionAndVideosWhileRunning() async throws {
    let server = FixtureDirectoryServer()
    let movies = source(server, "Movies")
    let shows = source(server, "Shows")
    server.publish(
      root: movies.url, files: (0..<12).map { "Folder\($0)/Film.Number.\($0).2020.mkv" })
    server.publish(root: shows.url, files: (0..<12).map { "Show\($0)/Show.S01E0\($0 % 9 + 1).mkv" })
    server.setLatency(0.02)
    let library = controller(index: try makeIndex(), server: server)
    library.refresh(roots: [movies, shows], manual: true)
    var sawMidRun = false
    var previousFraction = 0.0
    var monotonic = true
    while library.isRefreshing {
      let value = library.indexing
      if value.sourceCount == 2, value.currentSource >= 1, value.fraction > 0, value.fraction < 1,
        value.videosFound > 0
      {
        sawMidRun = true
      }
      if value.fraction + 0.0001 < previousFraction && value.fraction != 0 { monotonic = false }
      previousFraction = max(previousFraction, value.fraction)
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertTrue(sawMidRun, "A running index exposes source position, fraction and videos so far")
    XCTAssertTrue(monotonic, "The overall fraction never moves backwards")
    XCTAssertEqual(library.libraryTotal, 24)
  }

  // MARK: - Failure isolation, health, retry

  func testFailingSourceNeverBlocksOthersAndKeepsItsSavedTitles() async throws {
    let healthy = FixtureDirectoryServer()
    let broken = FixtureDirectoryServer()
    let good = source(healthy, "Good")
    let bad = source(broken, "Bad")
    healthy.publish(root: good.url, files: ["New.Movie.2022.1080p.mkv"])
    broken.publish(root: bad.url, files: ["Saved.Movie.2019.1080p.mkv"])
    let index = try makeIndex()
    // The broken source indexed fine once, so it has saved titles.
    let seed = LibraryController(
      index: index, directoryService: DirectoryService(session: broken.session()),
      retryDelay: .zero, automaticRetry: false)
    seed.refresh(roots: [bad], manual: true)
    try await wait("seed run") { !seed.isRefreshing }
    XCTAssertEqual(seed.libraryTotal, 1)

    broken.setFault(.offline, forPrefix: bad.url)
    let session = healthy.session()
    let library = LibraryController(
      index: index, directoryService: DirectoryService(session: session), retryDelay: .zero,
      automaticRetry: false)
    // One session serves both hosts: the fixture protocol dispatches by host.
    library.refresh(roots: [good, bad], manual: true)
    try await wait("run finishes") { !library.isRefreshing }
    XCTAssertEqual(library.refreshState, .partial)
    let byName = Dictionary(uniqueKeysWithValues: library.sources.map { ($0.name, $0) })
    XCTAssertEqual(byName["Good"]?.state, .ok)
    XCTAssertEqual(byName["Bad"]?.state, .failed)
    XCTAssertNotNil(byName["Bad"]?.lastError)
    XCTAssertNotNil(byName["Bad"]?.lastProblem)
    XCTAssertEqual(byName["Bad"]?.consecutiveFailures, 1)
    XCTAssertNotNil(byName["Bad"]?.nextRetry, "A failing source is scheduled for retry")
    let titles = try await index.inventory().map(\.media.entry.name).sorted()
    XCTAssertEqual(titles, ["New.Movie.2022.1080p.mkv", "Saved.Movie.2019.1080p.mkv"])
    XCTAssertTrue(library.hasIssues)
    // Health is persisted for the next launch.
    let reopened = LibraryController(index: index)
    reopened.setRoots([good, bad])
    await reopened.loadSourceStatuses()
    XCTAssertEqual(reopened.sources.first { $0.name == "Bad" }?.state, .failed)
    XCTAssertEqual(reopened.sources.first { $0.name == "Good" }?.state, .ok)
  }

  func testSlowDownSourceDoesNotDelayAHealthySource() async throws {
    let fast = FixtureDirectoryServer()
    let slow = FixtureDirectoryServer()
    let good = source(fast, "Fast")
    let bad = source(slow, "Slow")
    fast.publish(root: good.url, files: ["Quick.Movie.2022.mkv"])
    slow.publish(root: bad.url, files: ["Never.Seen.2022.mkv"])
    slow.setLatency(0.6)
    slow.setFault(.offline, forPrefix: bad.url)
    let library = controller(index: try makeIndex(), server: fast)
    // Sources overlap only in Balanced mode; the saved mode is shared state, so set it here.
    let savedMode = library.indexingMode
    library.indexingMode = .balanced
    defer { library.indexingMode = savedMode }
    library.refresh(roots: [bad, good], manual: true)  // the slow source is first in order
    var fastFinishedWhileSlowRunning = false
    while library.isRefreshing {
      let states = Dictionary(uniqueKeysWithValues: library.sources.map { ($0.name, $0.state) })
      if states["Fast"] == .ok, states["Slow"] == .indexing { fastFinishedWhileSlowRunning = true }
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertTrue(
      fastFinishedWhileSlowRunning, "The healthy source completes while the other is still failing")
  }

  func testRepeatedFolderFailuresStopHammeringADeadSource() async throws {
    let server = FixtureDirectoryServer()
    let dead = source(server, "Dead")
    server.publish(root: dead.url, files: (0..<20).map { "Season\($0)/Episode.S01E01.mkv" })
    // The root answers; every season folder is down.
    for number in 0..<20 {
      server.setFault(.status(503), forPrefix: dead.url.appending(path: "Season\(number)/"))
    }
    let library = controller(index: try makeIndex(), server: server)
    library.refresh(roots: [dead], manual: true)
    try await wait("run finishes") { !library.isRefreshing }
    let attempted = (0..<20).filter {
      server.requests(for: dead.url.appending(path: "Season\($0)/")) > 0
    }.count
    XCTAssertLessThan(attempted, 20, "The breaker skips folders once the source keeps failing")
    XCTAssertEqual(library.sources.first?.state, .failed)
  }

  func testAutomaticRetryRecoversASourceWithBackoff() async throws {
    let server = FixtureDirectoryServer()
    let flaky = source(server, "Flaky")
    server.publish(root: flaky.url, files: ["Recovered.Movie.2020.1080p.mkv"])
    server.setFault(.offline, forPrefix: flaky.url)
    let library = controller(
      index: try makeIndex(), server: server,
      retry: IndexRetryPolicy(base: 0.25, factor: 2, maximum: 5), automaticRetry: true)
    library.refresh(roots: [flaky], manual: false)
    try await wait("first run fails") { !library.isRefreshing }
    XCTAssertEqual(library.sources.first?.state, .failed)
    let firstRetry = try XCTUnwrap(library.sources.first?.nextRetry)
    XCTAssertGreaterThan(firstRetry, Date.now.addingTimeInterval(-0.1))
    // The source stays down for the first retry: the backoff grows.
    try await wait("first retry runs and fails again") {
      !library.isRefreshing && (library.sources.first?.consecutiveFailures ?? 0) >= 2
    }
    let second = try XCTUnwrap(library.sources.first?.nextRetry)
    XCTAssertGreaterThan(second.timeIntervalSinceNow, 0.25 * 1.2, "Backoff doubles after a failure")
    // Back online: the following retry succeeds with no user action.
    server.setFault(nil, forPrefix: flaky.url)
    try await wait("source recovers", timeout: 10) {
      !library.isRefreshing && library.sources.first?.state == .ok
    }
    XCTAssertEqual(library.sources.first?.consecutiveFailures, 0)
    XCTAssertNil(library.sources.first?.nextRetry)
    XCTAssertEqual(library.libraryTotal, 1)
    XCTAssertEqual(library.refreshState, .completed)
  }

  func testLatencyIsMeasuredPerSource() async throws {
    let server = FixtureDirectoryServer()
    let slow = source(server, "Slow")
    server.publish(root: slow.url, files: ["One.Movie.2020.mkv"])
    server.setLatency(0.08)
    let library = controller(index: try makeIndex(), server: server)
    library.refresh(roots: [slow], manual: true)
    try await wait("run finishes") { !library.isRefreshing }
    let latency = try XCTUnwrap(library.sources.first?.latency)
    XCTAssertGreaterThan(latency, 0.06)
    XCTAssertLessThan(latency, 1)
  }

  // MARK: - Manual refresh, pause, resume, cancel

  func testManualRefreshAlwaysChecksSourcesEvenWhenFresh() async throws {
    let server = FixtureDirectoryServer()
    let movies = source(server, "Movies")
    server.publish(root: movies.url, files: ["Fresh.Movie.2020.mkv"])
    let library = controller(index: try makeIndex(), server: server)
    library.refresh(roots: [movies], manual: true)
    try await wait("first run") { !library.isRefreshing }
    let first = server.requests(for: movies.url)
    // A scheduled refresh of fresh folders does not touch the server.
    library.refreshDue()
    try await wait("scheduled run") { !library.isRefreshing }
    XCTAssertEqual(server.requests(for: movies.url), first)
    // A manual refresh always runs, and finds the new file.
    server.addFile(root: movies.url, path: "Added.Movie.2021.mkv")
    library.refresh(roots: [movies], manual: true)
    try await wait("manual run") { !library.isRefreshing }
    XCTAssertGreaterThan(server.requests(for: movies.url), first)
    XCTAssertEqual(library.libraryTotal, 2)
  }

  func testPauseHoldsRequestsAndResumeCompletes() async throws {
    let server = FixtureDirectoryServer()
    let movies = source(server, "Movies")
    server.publish(root: movies.url, files: (0..<30).map { "Folder\($0)/Film.Title.\($0).2020.mkv" })
    server.setLatency(0.03)
    let library = controller(index: try makeIndex(), server: server)
    library.refresh(roots: [movies], manual: true)
    try await wait("some requests") { server.requestCount >= 3 }
    library.pause()
    XCTAssertEqual(library.refreshState, .paused)
    try await Task.sleep(for: .milliseconds(300))  // let in-flight requests finish
    let held = server.requestCount
    try await Task.sleep(for: .milliseconds(500))
    XCTAssertEqual(server.requestCount, held, "No new requests while paused")
    XCTAssertTrue(library.isRefreshing)
    library.resume()
    XCTAssertEqual(library.refreshState, .refreshing)
    try await wait("run completes after resume", timeout: 15) { !library.isRefreshing }
    XCTAssertEqual(library.refreshState, .completed)
    XCTAssertEqual(library.libraryTotal, 30)
  }

  func testCancelKeepsSavedLibraryAndReportsCancelledState() async throws {
    let server = FixtureDirectoryServer()
    let movies = source(server, "Movies")
    server.publish(root: movies.url, files: (0..<40).map { "Folder\($0)/Film.Title.\($0).2020.mkv" })
    let index = try makeIndex()
    try await index.upsert([video(movies, "Saved.Movie.2018.mkv")], generation: UUID())
    server.setLatency(0.05)
    let library = controller(index: index, server: server)
    library.refresh(roots: [movies], manual: true)
    try await wait("started") { server.requestCount >= 2 }
    library.cancel()
    XCTAssertEqual(library.refreshState, .cancelled)
    XCTAssertTrue(library.isCancelled)
    XCTAssertFalse(library.isRefreshing)
    XCTAssertFalse(library.isPaused)
    try await Task.sleep(for: .milliseconds(400))
    let names = try await index.inventory().map(\.media.entry.name)
    XCTAssertTrue(names.contains("Saved.Movie.2018.mkv"), "Cancelling never removes saved titles")
    XCTAssertEqual(library.indexing, IndexingProgress())
    XCTAssertTrue(library.sources.allSatisfy { $0.state != .indexing && $0.state != .queued })
  }
}

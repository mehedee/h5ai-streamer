import Darwin
import XCTest

@testable import Myra

/// Phase 0 measurements on an isolated, generated library. The full 30,000-title run is opt-in:
///
///     MYRA_BENCH=1 MYRA_BENCH_OUT=/path/to/results.txt swift test -c release \
///       -Xswiftc -enable-testing --filter CatalogueBenchmarkTests
///
/// It never opens the personal profile. A 600-title smoke run is part of the normal suite.
final class CatalogueBenchmarkTests: XCTestCase {
  private var lines: [String] = []

  private func report(_ label: String, _ value: String) {
    let line = "\(label): \(value)"
    lines.append(line)
    print("BENCH \(line)")
  }

  private func seconds(_ body: () async throws -> Void) async rethrows -> Double {
    let clock = ContinuousClock()
    let start = clock.now
    try await body()
    let elapsed = start.duration(to: clock.now)
    return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
  }

  private func format(_ value: Double) -> String { String(format: "%.3f s", value) }

  private func peakRSSMegabytes() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_maxrss) / 1_048_576
  }

  private func flush() {
    guard let path = ProcessInfo.processInfo.environment["MYRA_BENCH_OUT"] else { return }
    try? (lines.joined(separator: "\n") + "\n").write(
      toFile: path, atomically: true, encoding: .utf8)
  }

  func testSmokeFixtureProducesExpectedCatalogue() async throws {
    let spec = LibraryFixtureSpec.small(titles: 600)
    let fixture = try await LibraryFixtureBuilder.build(spec: spec)
    defer { fixture.remove() }
    let prepared = try await EntertainmentCatalogueWorker().prepare(
      index: fixture.index, personal: .init())
    XCTAssertEqual(prepared.titles.count, spec.expectedTitles)
    XCTAssertEqual(prepared.titles.reduce(0) { $0 + $1.versions.count }, spec.expectedVideos)
    XCTAssertTrue(prepared.titles.contains { $0.metadata != nil })
  }

  func testThirtyThousandTitleBenchmark() async throws {
    guard ProcessInfo.processInfo.environment["MYRA_BENCH"] == "1" else {
      throw XCTSkip("Opt-in benchmark: set MYRA_BENCH=1")
    }
    let spec = LibraryFixtureSpec()
    var fixture: LibraryFixture?
    let buildSeconds = try await seconds { fixture = try await LibraryFixtureBuilder.build(spec: spec) }
    let library = try XCTUnwrap(fixture)
    defer { library.remove() }
    report("fixture.titles", "\(spec.expectedTitles)")
    report("fixture.videos", "\(library.videos.count)")
    report("fixture.build", format(buildSeconds))
    let index = library.index

    // Cold: no saved catalogue.
    var cold: EntertainmentCatalogueWorker.Prepared?
    let coldSeconds = try await seconds {
      cold = try await EntertainmentCatalogueWorker().prepare(index: index, personal: .init())
    }
    report("catalogue.prepare.cold", format(coldSeconds))
    report("catalogue.titles", "\(cold?.titles.count ?? 0)")
    let cacheURL = index.url.appendingPathExtension("home-cache")
    if let size = (try? FileManager.default.attributesOfItem(atPath: cacheURL.path))?[.size] as? Int {
      report("legacy.json.cache.bytes", "\(size)")
    }
    report("db.bytes", "\((try? FileManager.default.attributesOfItem(atPath: index.url.path))?[.size] ?? 0)")

    // Warm: second launch reads the saved catalogue.
    var warm: [Double] = []
    for _ in 0..<3 {
      warm.append(
        try await seconds {
          _ = try await EntertainmentCatalogueWorker().prepare(index: index, personal: .init())
        })
    }
    report("catalogue.prepare.warm.min", format(warm.min() ?? 0))
    report("catalogue.prepare.warm.median", format(warm.sorted()[warm.count / 2]))

    // What the Home page waits for after launch: store.reload() on a saved catalogue.
    let controller = await MainActor.run { LibraryController(index: index) }
    let store = await MainActor.run {
      EntertainmentStore(
        library: controller,
        storageURL: library.directory.appending(path: "Personal.json"),
        automaticEnrichment: false)
    }
    MyraPerformance.resetFirstShelfForTesting()
    let reloadSeconds = try await seconds { await store.reload() }
    report("store.reload.toFirstShelf", format(reloadSeconds))
    let shelfCount = await MainActor.run { store.homeShelves.count }
    report("store.reload.shelves", "\(shelfCount)")

    // A metadata save used to invalidate the whole saved catalogue.
    let metadataSave = try await seconds {
      try await index.saveMetadata(key: "tmdb-attempt|bench", payload: "ambiguous")
    }
    report("metadata.save", format(metadataSave))
    let afterMetadata = try await seconds {
      _ = try await EntertainmentCatalogueWorker().prepare(index: index, personal: .init())
    }
    report("catalogue.prepare.afterMetadataSave", format(afterMetadata))

    // Ten new files appear in one folder.
    let extra = (0..<10).map { number in
      let root = library.roots[0]
      let name = "Brand.New.Release.Number.\(number).2024.1080p.WEB-DL.x264.mkv"
      let url = root.url.appending(path: "Hollywood/Action/" + name)
      return GlobalSearchResult(
        categoryID: root.id, categoryName: root.name, categoryRoot: root.url,
        entry: DirectoryEntry(name: name, url: url, kind: .file, size: 1, modifiedAt: .now),
        relativePath: "Hollywood/Action/" + name, artworkURL: nil)
    }
    try await index.upsert(extra, generation: UUID())
    var afterNewFiles: EntertainmentCatalogueWorker.Prepared?
    let incremental = try await seconds {
      afterNewFiles = try await EntertainmentCatalogueWorker().prepare(
        index: index, personal: .init())
    }
    report("catalogue.prepare.afterTenNewFiles", format(incremental))
    report("catalogue.titles.afterTenNewFiles", "\(afterNewFiles?.titles.count ?? 0)")

    // Home render preparation.
    let titles = try XCTUnwrap(afterNewFiles).titles
    let personal = EntertainmentPersonalData()
    let shelves = try await seconds { _ = HomeCategoryBuilder.categories(for: titles) }
    report("home.shelves", format(shelves))
    let worker = HomeProjectionWorker()
    let projectionAll = try await seconds {
      _ = try await worker.prepare(
        titles, personal: personal,
        filter: HomeCatalogueFilter(query: "", selection: LibraryFilterSelection(), revision: 0))
    }
    report("home.projection.unfiltered.coldIndex", format(projectionAll))
    let warmAll = try await seconds {
      _ = try await worker.prepare(
        titles, personal: personal,
        filter: HomeCatalogueFilter(query: "", selection: LibraryFilterSelection(), revision: 1))
    }
    report("home.projection.unfiltered.preparedIndex", format(warmAll))
    var filteredCount = 0
    var selection = LibraryFilterSelection()
    selection.toggle("Action", in: .genre)
    let projectionGenre = try await seconds {
      let projection = try await worker.prepare(
        titles, personal: personal,
        filter: HomeCatalogueFilter(query: "", selection: selection, revision: 2))
      filteredCount = projection.filtered.count
    }
    report("home.projection.genreAction.preparedIndex", format(projectionGenre))
    report("home.projection.genreAction.matches", "\(filteredCount)")

    // A complete crawl through the HTTP layer, then an unchanged re-crawl (conditional requests).
    library.publishListings()
    let session = library.server.session()
    defer { session.invalidateAndCancel() }
    let crawlIndex = try LibraryIndex(
      url: library.directory.appending(path: "Crawl/LibraryIndex.sqlite"))
    let service = DirectoryService(session: session)
    let crawlSeconds = try await seconds {
      _ = try await LibraryIndexer(directoryService: service, maximumConcurrentFolders: 4).refresh(
        roots: library.roots, index: crawlIndex, generation: UUID(), full: true, update: { _ in })
    }
    report("index.run.full", format(crawlSeconds))
    report("index.run.full.requests", "\(library.server.requestCount)")
    let crawled = try await crawlIndex.inventory().count
    report("index.run.full.videos", "\(crawled)")
    let before = library.server.requestCount
    let recrawl = try await seconds {
      _ = try await LibraryIndexer(directoryService: service, maximumConcurrentFolders: 4).refresh(
        roots: library.roots, index: crawlIndex, generation: UUID(), update: { _ in })
    }
    report("index.run.unchanged", format(recrawl))
    report("index.run.unchanged.requests", "\(library.server.requestCount - before)")
    report("index.run.unchanged.notModified", "\(library.server.notModified)")
    report("process.peakRSS", String(format: "%.0f MB", peakRSSMegabytes()))
    for sample in MyraPerformance.recorder.snapshot {
      report("signpost.\(sample.name)", "\(format(sample.seconds)) \(sample.detail)")
    }
    flush()
  }
}

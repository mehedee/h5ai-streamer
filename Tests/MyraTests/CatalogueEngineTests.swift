import XCTest

@testable import Myra

/// Phase 2: the compact catalogue, its migration, incremental updates, facets and cleanup.
final class CatalogueEngineTests: XCTestCase {
  private var fixtures: [LibraryFixture] = []

  override func tearDown() {
    fixtures.forEach { $0.remove() }
    fixtures = []
    super.tearDown()
  }

  private func fixture(titles: Int = 200) async throws -> LibraryFixture {
    let built = try await LibraryFixtureBuilder.build(spec: .small(titles: titles))
    fixtures.append(built)
    return built
  }

  private func ids(_ titles: [EntertainmentTitle]) -> [String] { titles.map(\.id) }

  func testBuiltCatalogueMatchesInMemoryGroupingAndVerifies() async throws {
    let library = try await fixture()
    let prepared = try await EntertainmentCatalogueWorker().prepare(
      index: library.index, personal: .init())
    XCTAssertEqual(prepared.route, .built)
    let expected = EntertainmentGrouping.group(
      try await library.index.inventory(), corrections: [:])
    XCTAssertEqual(ids(prepared.titles), ids(expected))
    XCTAssertEqual(
      prepared.titles.map { $0.versions.map(\.id) }, expected.map { $0.versions.map(\.id) })
    let check = try await library.index.verifyCatalogue()
    XCTAssertTrue(check.ok, "\(check)")
    let again = try await EntertainmentCatalogueWorker().prepare(
      index: library.index, personal: .init())
    XCTAssertEqual(again.route, .saved)
    XCTAssertEqual(again.metadataQueryCount, 0)
  }

  func testIncrementalUpdateEqualsFullRegroupForAddRemoveAndRename() async throws {
    let library = try await fixture()
    let worker = EntertainmentCatalogueWorker()
    _ = try await worker.prepare(index: library.index, personal: .init())
    let root = library.roots[0]
    func video(_ name: String) -> GlobalSearchResult {
      let url = root.url.appending(path: "Hollywood/Action/" + name)
      return GlobalSearchResult(
        categoryID: root.id, categoryName: root.name, categoryRoot: root.url,
        entry: DirectoryEntry(name: name, url: url, kind: .file, size: 1, modifiedAt: .now),
        relativePath: "Hollywood/Action/" + name, artworkURL: nil)
    }
    let added = [video("Fresh.One.Title.2024.1080p.mkv"), video("Fresh.One.Title.2024.720p.mkv")]
    try await library.index.upsert(added, generation: UUID())
    let removedURL = library.videos[0]
    try await library.index.synchronizeSources(Array(library.roots.dropFirst()))  // drops source 0
    let incremental = try await worker.prepare(index: library.index, personal: .init())
    guard case .incremental = incremental.route else {
      return XCTFail("Expected an incremental route, got \(incremental.route)")
    }
    let expected = EntertainmentGrouping.group(
      try await library.index.inventory(), corrections: [:])
    XCTAssertEqual(ids(incremental.titles), ids(expected))
    XCTAssertEqual(
      incremental.titles.map { $0.versions.count }, expected.map { $0.versions.count })
    XCTAssertFalse(incremental.titles.flatMap(\.versions).contains { $0.id == removedURL.entry.url.absoluteString })
    let check = try await library.index.verifyCatalogue()
    XCTAssertTrue(check.ok, "\(check)")
  }

  func testMetadataSaveDoesNotInvalidateAndIsVisibleImmediately() async throws {
    let library = try await fixture(titles: 100)
    let worker = EntertainmentCatalogueWorker()
    let first = try await worker.prepare(index: library.index, personal: .init())
    let target = try XCTUnwrap(first.titles.first { $0.metadata == nil })
    let metadata = EntertainmentMetadata(
      providerID: 9, title: "Matched Title", overview: "x", posterURL: nil, rating: 7,
      voteCount: 50, releaseDate: "2020-01-01", genres: ["Drama"], language: "en")
    try await library.index.saveMetadata(
      key: target.metadataCacheKey(),
      payload: String(decoding: try JSONEncoder().encode(metadata), as: UTF8.self))
    let second = try await worker.prepare(index: library.index, personal: .init())
    XCTAssertEqual(second.route, .saved, "A metadata save must not rebuild the catalogue")
    XCTAssertEqual(second.titles.first { $0.id == target.id }?.metadata, metadata)
  }

  func testCorrectionChangeMovesOnlyThatFile() async throws {
    let library = try await fixture(titles: 100)
    let worker = EntertainmentCatalogueWorker()
    let first = try await worker.prepare(index: library.index, personal: .init())
    let victim = try XCTUnwrap(first.titles.first { $0.kind == .movie })
    let versionID = try XCTUnwrap(victim.versions.first?.id)
    var personal = EntertainmentPersonalData()
    personal.matchCorrections[versionID] = EntertainmentMatchCorrection(
      title: "Corrected Name", year: "2001", kind: .movie, providerID: nil)
    let second = try await worker.prepare(index: library.index, personal: personal)
    guard case .incremental = second.route else { return XCTFail("\(second.route)") }
    let expected = EntertainmentGrouping.group(
      try await library.index.inventory(), corrections: personal.matchCorrections)
    XCTAssertEqual(ids(second.titles), ids(expected))
    XCTAssertTrue(second.titles.contains { $0.name == "Corrected Name" })
  }

  func testMigrationBacksUpRetiresJSONOnlyAfterVerificationAndKeepsData() async throws {
    let library = try await fixture(titles: 100)
    let legacy = LegacyHomeCache.url(for: library.index)
    try Data("{\"format\":2,\"revision\":0}".utf8).write(to: legacy)
    let before = try await library.index.videoCount()
    _ = try await EntertainmentCatalogueWorker().prepare(index: library.index, personal: .init())
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: LegacyHomeCache.backupURL(for: library.index).path),
      "The original database is backed up before the first build")
    XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: LegacyHomeCache.retiredURL(for: library.index).path),
      "The JSON is retired, not deleted")
    let state = try await library.index.catalogueState()
    XCTAssertEqual(state?.legacyRetired, true)
    let after = try await library.index.videoCount()
    XCTAssertEqual(before, after)
    // The backup opens as a database holding the same videos.
    let backup = try LibraryIndex(url: LegacyHomeCache.backupURL(for: library.index), searchable: false)
    let backedUp = try await backup.videoCount()
    XCTAssertEqual(backedUp, before)
  }

  func testLegacyJSONWithDifferentCountsAtSameRevisionIsKept() async throws {
    let library = try await fixture(titles: 100)
    let revision = try await library.index.revision()
    let legacy = LegacyHomeCache.url(for: library.index)
    try Data("{\"format\":2,\"revision\":\(revision),\"titles\":[{\"kind\":\"movie\",\"versions\":[{\"relativePath\":\"a\"}]}]}".utf8)
      .write(to: legacy)
    _ = try await EntertainmentCatalogueWorker().prepare(index: library.index, personal: .init())
    XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path), "Mismatching counts keep the JSON")
  }

  func testFiltersWorkFromFoldersAndFileNamesWithoutMetadata() async throws {
    let library = try await LibraryFixtureBuilder.build(spec: .small(titles: 300), withMetadata: false)
    fixtures.append(library)
    let prepared = try await EntertainmentCatalogueWorker().prepare(
      index: library.index, personal: .init())
    XCTAssertTrue(prepared.titles.allSatisfy { $0.metadata == nil })
    let options = CatalogueFacetProvider().options(for: prepared.titles)
    XCTAssertTrue(options.genres.contains { $0.value == "Action" && $0.count > 0 })
    XCTAssertTrue(options.languages.contains { $0.value == "hi" })
    XCTAssertTrue(options.languages.contains { $0.value == "ko" })
    XCTAssertTrue(options.qualities.contains { $0.value == "1080p" })
    XCTAssertEqual(Set(options.sources.map(\.value)), ["Movies", "Series"])
    XCTAssertFalse(options.years.isEmpty)
    var selection = LibraryFilterSelection()
    selection.toggle("Action", in: .genre)
    selection.toggle("hi", in: .language)
    let projection = try await HomeProjectionWorker().prepare(
      prepared.titles, personal: .init(),
      filter: HomeCatalogueFilter(query: "", selection: selection, revision: 1))
    XCTAssertFalse(projection.filtered.isEmpty)
    XCTAssertTrue(projection.filtered.allSatisfy { title in
      title.versions.contains { $0.media.relativePath.hasPrefix("Bollywood/Action/") }
    })
    XCTAssertEqual(projection.options, options, "Home and the provider share one list")
  }

  func testFolderWordsNeedToBeWholeComponentsToCountAsGenres() {
    func traits(_ path: String) -> TitleTraits {
      let root = URL(string: "https://x.example/M/")!
      let title = EntertainmentTitle(
        id: "t", name: "T", year: nil, kind: .movie,
        versions: [
          EntertainmentVersion(
            media: GlobalSearchResult(
              categoryID: UUID(), categoryName: "Library", categoryRoot: root,
              entry: DirectoryEntry(name: "T.mkv", url: root.appending(path: path), kind: .file),
              relativePath: path, artworkURL: nil),
            firstDiscovered: .now)
        ])
      var cache: [String: FolderFacts] = [:]
      return TitleFacetDerivation.traits(for: title, cache: &cache)
    }
    XCTAssertEqual(traits("Family Guy/T.mkv").genres, [])
    XCTAssertEqual(traits("Hindi Action Movies/T.mkv").genres, ["Action"])
    XCTAssertEqual(traits("Hindi Action Movies/T.mkv").language, "hi")
    XCTAssertEqual(traits("Sci-Fi/2019/T.mkv").genres, ["Science Fiction"])
    XCTAssertEqual(traits("Sci-Fi/2019/T.mkv").years, ["2019"])
  }

  func testSearchAliasesSyncRunsOnlyWhenCatalogueChanged() async throws {
    let library = try await fixture(titles: 80)
    _ = try await EntertainmentCatalogueWorker().prepare(index: library.index, personal: .init())
    _ = try await library.index.syncSearchAliasesIfNeeded()
    let second = try await library.index.syncSearchAliasesIfNeeded()
    XCTAssertEqual(second, 0)
    let state = try await library.index.catalogueState()
    XCTAssertEqual(state?.aliasesSynced, true)
  }

  func testCleanupRemovesOnlyRegenerableCachesAndNeverTheDatabase() async throws {
    let library = try await fixture(titles: 60)
    _ = try await EntertainmentCatalogueWorker().prepare(index: library.index, personal: .init())
    let directory = library.index.url.deletingLastPathComponent()
    let newest = library.index.url.appendingPathExtension("pre-4.1-backup")
    let older = library.index.url.appendingPathExtension("v2-backup")
    try Data("old".utf8).write(to: older)
    try FileManager.default.setAttributes(
      [.modificationDate: Date.now.addingTimeInterval(-86400)], ofItemAtPath: older.path)
    try Data("json".utf8).write(to: LegacyHomeCache.url(for: library.index))
    let settings = directory.appending(path: "EntertainmentPersonal.json")
    try Data("{}".utf8).write(to: settings)
    let candidates = LibraryCleanup.plan(
      libraryIndexURL: library.index.url, catalogueVerified: true,
      temporaryDirectory: directory.appending(path: "no-temp"))
    XCTAssertEqual(Set(candidates.map(\.url.lastPathComponent)),
      Set([older.lastPathComponent, LegacyHomeCache.url(for: library.index).lastPathComponent,
           LegacyHomeCache.retiredURL(for: library.index).lastPathComponent].filter {
        FileManager.default.fileExists(atPath: directory.appending(path: $0).path)
      }))
    let report = LibraryCleanup.perform(candidates)
    XCTAssertTrue(report.failed.isEmpty)
    XCTAssertTrue(FileManager.default.fileExists(atPath: library.index.url.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: settings.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: newest.path), "The newest backup stays")
    XCTAssertFalse(FileManager.default.fileExists(atPath: older.path))
    let unverified = LibraryCleanup.plan(
      libraryIndexURL: library.index.url, catalogueVerified: false,
      temporaryDirectory: directory.appending(path: "no-temp"))
    XCTAssertFalse(unverified.contains { $0.kind == .legacyHomeCache })
  }

  @MainActor
  func testSeamsReflectRealEngineState() async throws {
    let server = FixtureDirectoryServer()
    let root = GlobalSearchRoot(id: UUID(), name: "Movies", url: server.rootURL("Movies"))
    server.publish(root: root.url, files: ["A.Film.2020.mkv", "B.Film.2021.mkv"])
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "Myra-seam-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let index = try LibraryIndex(url: directory.appending(path: "LibraryIndex.sqlite"))
    let library = LibraryController(
      index: index, directoryService: DirectoryService(session: server.session()),
      automaticRetry: false)
    let category = Category(name: "Movies", rootURLString: root.url.absoluteString)
    let rooted = GlobalSearchRoot(id: category.id, name: "Movies", url: root.url)
    server.publish(root: rooted.url, files: ["A.Film.2020.mkv", "B.Film.2021.mkv"])
    var refreshed = 0
    let actions = IndexingActions.make(library: library) {
      refreshed += 1
      library.refresh(roots: [rooted], manual: true)
    }
    actions.refreshNow()
    XCTAssertTrue(IndexingSnapshot.make(library: library, catalogueCount: 0, categories: [category]).isRunning)
    actions.pause()
    XCTAssertTrue(IndexingSnapshot.make(library: library, catalogueCount: 0, categories: [category]).isPaused)
    actions.resume()
    for _ in 0..<500 where library.isRefreshing { try await Task.sleep(for: .milliseconds(10)) }
    let snapshot = IndexingSnapshot.make(library: library, catalogueCount: 2, categories: [category])
    XCTAssertFalse(snapshot.isRunning)
    XCTAssertEqual(snapshot.sources.first?.state, .indexed)
    XCTAssertEqual(snapshot.sources.first?.titles, 2)
    XCTAssertNotNil(snapshot.lastScan)
    XCTAssertEqual(snapshot.label, "Up to date")
    XCTAssertEqual(refreshed, 1)
  }
}

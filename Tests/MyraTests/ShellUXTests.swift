import SwiftUI
import XCTest

@testable import Myra

/// The 4.1 shell: indexing indicator values, filters, watchlist, translucency, Ask Myra actions,
/// player episode controls and the sidebar rail. Each fixture is isolated; nothing reads a profile.
@MainActor
final class ShellUXTests: XCTestCase {
  private let helper = HomeCategoryClassifierTests()

  private func title(
    _ name: String, kind: EntertainmentKind = .movie, file: String? = nil, year: String? = nil,
    genres: [String] = [], language: String = "en", source: String = "Home NAS",
    rating: Double = 7
  ) -> EntertainmentTitle {
    var value = helper.makeTitle(
      name, kind: kind, file: file,
      metadata: helper.metadata(name, language: language, genres: genres, rating: rating),
      categoryName: source)
    value.year = year
    return value
  }

  // MARK: Indexing indicator

  func testIndicatorWidthIsFixedAtTheMockValue() {
    XCTAssertEqual(IndexingIndicatorLayout.width, 204)
    XCTAssertEqual(IndexingIndicatorLayout.countColumnWidth, 56)
  }

  func testIdleSnapshotShowsUpToDateAndTheLibraryTotal() {
    let idle = IndexingSnapshot(libraryTotal: 1_284)
    XCTAssertEqual(idle.label, "Up to date")
    XCTAssertEqual(idle.count, 1_284)
    XCTAssertEqual(idle.fraction, 0)
  }

  func testRunningSnapshotShowsSourceProgressAndVideosFound() {
    let running = IndexingSnapshot(
      isRunning: true, currentSource: 2, sourceCount: 3, videosFound: 842, libraryTotal: 1_284)
    XCTAssertEqual(running.label, "Indexing 2/3")
    XCTAssertEqual(running.count, 842)
    XCTAssertEqual(running.fraction, 1.0 / 3.0, accuracy: 0.0001)

    var paused = running
    paused.isPaused = true
    XCTAssertEqual(paused.label, "Paused")
  }

  func testRunningLabelNeverShowsZeroSources() {
    let early = IndexingSnapshot(isRunning: true, currentSource: 0, sourceCount: 0)
    XCTAssertEqual(early.label, "Indexing 1/1")
  }

  func testDefaultBindingReadsTheLibraryController() {
    let library = LibraryController()
    let category = Category(name: "Home NAS", rootURLString: "http://nas.local/movies/")
    let snapshot = IndexingSnapshot.make(
      library: library, catalogueCount: 12, categories: [category])
    XCTAssertFalse(snapshot.isRunning)
    XCTAssertEqual(snapshot.libraryTotal, 12)
    XCTAssertEqual(snapshot.sources.map(\.name), ["Home NAS"])
    XCTAssertEqual(snapshot.sources.first?.host, "nas.local")
    XCTAssertEqual(snapshot.sources.first?.state, .indexed)
  }

  // MARK: Filters

  func testFilterSelectionCombinesFacetsWithAndAndValuesWithOr() {
    let sintel = title("Sintel", genres: ["Animation", "Fantasy"], source: "Home NAS")
    let tears = title("Tears of Steel", genres: ["Sci-Fi"], source: "Media Server")
    var selection = LibraryFilterSelection()
    XCTAssertTrue(selection.matches(sintel, watched: []))

    selection.toggle("Animation", in: .genre)
    selection.toggle("Sci-Fi", in: .genre)
    XCTAssertTrue(selection.matches(sintel, watched: []))
    XCTAssertTrue(selection.matches(tears, watched: []))

    selection.toggle("Home NAS", in: .source)
    XCTAssertTrue(selection.matches(sintel, watched: []))
    XCTAssertFalse(selection.matches(tears, watched: []))
    XCTAssertEqual(selection.activeCount, 3)
  }

  func testKindHideWatchedAndClear() {
    let movie = title("Sintel")
    let show = title("Harbour Watch", kind: .series, file: "Harbour Watch S01E01.mkv")
    var selection = LibraryFilterSelection()
    selection.kind = .series
    XCTAssertFalse(selection.matches(movie, watched: []))
    XCTAssertTrue(selection.matches(show, watched: []))

    selection.kind = .all
    selection.hideWatched = true
    XCTAssertFalse(selection.matches(movie, watched: [movie.id]))
    XCTAssertTrue(selection.matches(movie, watched: []))

    let model = LibraryFilterModel()
    model.selection = selection
    XCTAssertTrue(model.selection.isActive)
    model.clear()
    XCTAssertFalse(model.selection.isActive)
    XCTAssertEqual(model.selection.activeCount, 0)
  }

  func testQualityFacetReadsResolutionFromFileNames() {
    let uhd = title("Iron Valley", file: "Iron Valley (2023) 2160p.mkv")
    let hd = title("Quiet Hours", file: "Quiet Hours (2020) 1080p.mkv")
    let fourK = title("Sarai", file: "Sarai 4K HDR.mkv")
    XCTAssertEqual(LibraryFilter.resolutions(of: uhd), ["2160p"])
    XCTAssertEqual(LibraryFilter.resolutions(of: fourK), ["2160p"])
    var selection = LibraryFilterSelection()
    selection.toggle("2160p", in: .quality)
    XCTAssertTrue(selection.matches(uhd, watched: []))
    XCTAssertTrue(selection.matches(fourK, watched: []))
    XCTAssertFalse(selection.matches(hd, watched: []))
  }

  func testFacetOptionsCarryCountsAndRankByCount() {
    let titles = [
      title("A", file: "A 1080p.mkv", year: "2020", genres: ["Drama"], language: "en"),
      title("B", file: "B 1080p.mkv", year: "2020", genres: ["Drama", "Comedy"], language: "en"),
      title("C", file: "C 720p.mkv", year: "2019", genres: ["Comedy"], language: "hi",
        source: "Media Server"),
    ]
    let options = CatalogueFacetProvider().options(for: titles)
    XCTAssertEqual(options.genres, [.init(value: "Comedy", count: 2), .init(value: "Drama", count: 2)])
    XCTAssertEqual(options.languages.first, .init(value: "en", count: 2))
    XCTAssertEqual(options.years.first, .init(value: "2020", count: 2))
    XCTAssertEqual(options.qualities, [.init(value: "1080p", count: 2), .init(value: "720p", count: 1)])
    XCTAssertEqual(options.sources.first, .init(value: "Home NAS", count: 2))
  }

  func testProjectionAppliesTheSharedSelectionToShelvesAndLists() async throws {
    let drama = title("Drama One", genres: ["Drama"])
    let comedy = title("Comedy One", genres: ["Comedy"])
    var selection = LibraryFilterSelection()
    selection.toggle("Comedy", in: .genre)
    let projection = try await HomeProjectionWorker().prepare(
      [drama, comedy], personal: EntertainmentPersonalData(),
      filter: HomeCatalogueFilter(query: "", selection: selection, revision: 1))
    XCTAssertEqual(projection.filtered.map(\.name), ["Comedy One"])
    // The facet counts come from the whole catalogue, so a chosen facet can still be widened.
    XCTAssertEqual(projection.options.genres.map(\.value).sorted(), ["Comedy", "Drama"])
  }

  // MARK: Watchlist

  func testWatchlistShowsOnlySavedTitlesInTheCatalogueAZ() {
    let a = title("Zulu")
    let b = title("Alpha")
    let c = title("Mid")
    let saved: Set<String> = [a.id, b.id, "movie|Gone"]
    XCTAssertEqual(WatchlistStore.titles(in: [a, b, c], saved: saved).map(\.name), ["Alpha", "Zulu"])
    XCTAssertEqual(WatchlistStore.badgeCount(in: [a, b, c], saved: saved), 2)
    XCTAssertEqual(WatchlistStore.badgeCount(in: [a, b, c], saved: []), 0)
  }

  // MARK: Sidebar and translucency

  func testSidebarWidthsMatchTheMock() {
    XCTAssertEqual(SidebarState.width(collapsed: false), 232)
    XCTAssertEqual(SidebarState.width(collapsed: true), 78)
  }

  func testTranslucencyDefaultsToStrongAndOrdersTheLevels() {
    XCTAssertEqual(MyraTranslucency(storedValue: nil), .strong)
    XCTAssertEqual(MyraTranslucency(storedValue: "bogus"), .strong)
    XCTAssertEqual(MyraTranslucency(storedValue: "subtle"), .subtle)
    XCTAssertEqual(
      MyraTranslucency.allCases.map(\.title), ["Off", "Subtle", "Standard", "Strong"])
    let alphas = MyraTranslucency.allCases.map(\.windowAlpha)
    XCTAssertEqual(alphas, alphas.sorted(by: >), "less translucent levels cover more")
    XCTAssertEqual(MyraTranslucency.strong.windowAlpha, 0.55)
    XCTAssertEqual(MyraTranslucency.strong.sidebarAlpha, 0.5)
    XCTAssertEqual(MyraTranslucency.off.contentAlpha, 1)
    XCTAssertNil(MyraTranslucency.off.material)
    XCTAssertNotNil(MyraTranslucency.strong.material)
  }

  func testReduceTransparencyForcesOpaqueSurfaces() {
    XCTAssertEqual(MyraTranslucency.strong.resolved(reduceTransparency: true), .off)
    XCTAssertEqual(MyraTranslucency.strong.resolved(reduceTransparency: false), .strong)
  }

  // MARK: Ask Myra

  func testAskMyraOffersExactlyThreeContextualActions() {
    let general = MyraAskAction.actions(forTitle: nil)
    XCTAssertEqual(general.count, 3)
    XCTAssertEqual(general.map(\.feature), [.smartPick, .assistant, .collection])
    let forTitle = MyraAskAction.actions(forTitle: title("Sintel"))
    XCTAssertEqual(forTitle.count, 3)
    XCTAssertEqual(forTitle.map(\.feature), [.similar, .summary, .explain])
  }

  // MARK: Player

  func testEpisodeControlsAppearOnlyForSeriesEpisodes() {
    XCTAssertTrue(PlayerBarLayout.showsEpisodeControls(filename: "Harbour.Watch.S01E02.1080p.mkv"))
    XCTAssertFalse(PlayerBarLayout.showsEpisodeControls(filename: "Sintel (2010) 1080p.mkv"))
    XCTAssertEqual(PlayerBarLayout.maxWidth, 960)
  }

  // MARK: See All

  func testSeeAllSortsOrderTitlesAsLabelled() {
    let low = title("Beta", rating: 5)
    let high = title("Alpha", rating: 9)
    XCTAssertEqual(SeeAllSort.rating.sorted([low, high]).map(\.name), ["Alpha", "Beta"])
    XCTAssertEqual(SeeAllSort.name.sorted([low, high]).map(\.name), ["Alpha", "Beta"])
    XCTAssertEqual(SeeAllSort.allCases.map(\.title).count, 4)
  }

  func testGridLeavesRoomForTheHoverRing() {
    // The ring is a 3 pt stroke drawn 3 pt outside the poster: 4.5 pt past the edge at most.
    XCTAssertGreaterThanOrEqual(TitleGridLayout.ringInset, 3 + 3 / 2)
  }
}

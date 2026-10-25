import Foundation
import XCTest

@testable import Myra

/// Home shelves through the store: rebuild after a refresh, pin, hide, reorder and reset.
@MainActor
final class PagesHomeTests: XCTestCase {
  private let helper = HomeCategoryClassifierTests()

  private func fixtureTitles() -> [EntertainmentTitle] {
    let hindi = (0..<8).map { helper.makeTitle("Hindi \($0)", folder: "Hindi") }
    let anime = (0..<8).map { helper.makeTitle("Anime \($0)", kind: .series, folder: "Anime") }
    return hindi + anime
  }

  private func makeStorage() -> URL {
    FileManager.default.temporaryDirectory
      .appending(path: "Myra-pages-home-\(UUID())")
      .appending(path: "personal.json")
  }

  func testRebuildCreatesShelvesAndPreferencesRecord() {
    let storage = makeStorage()
    let store = EntertainmentStore(library: LibraryController(), storageURL: storage)
    XCTAssertNil(store.personal.homeCategories)

    store.rebuildHomeCategories(from: fixtureTitles())

    XCTAssertEqual(store.homeShelves.map(\.kind), [.hindiMovies, .anime])
    XCTAssertNotNil(store.personal.homeCategories)
    XCTAssertEqual(store.arrangedHomeCategories().map(\.id), ["hindi-movies", "anime"])
  }

  func testPinnedShelfLeadsAndSurvivesReopen() throws {
    let storage = makeStorage()
    let store = EntertainmentStore(library: LibraryController(), storageURL: storage)
    store.rebuildHomeCategories(from: fixtureTitles())

    store.setHomeCategoryPinned(HomeCategoryKind.anime.id, true)

    XCTAssertEqual(store.arrangedHomeCategories().map(\.id), ["anime", "hindi-movies"])
    XCTAssertEqual(store.arrangedHomeCategories().first?.isPinned, true)

    let reopened = EntertainmentStore(library: LibraryController(), storageURL: storage)
    reopened.rebuildHomeCategories(from: fixtureTitles())
    XCTAssertEqual(reopened.arrangedHomeCategories().map(\.id), ["anime", "hindi-movies"])
  }

  func testHiddenShelfLeavesHomeButStaysInCustomise() {
    let store = EntertainmentStore(library: LibraryController(), storageURL: makeStorage())
    let titles = fixtureTitles()
    store.rebuildHomeCategories(from: titles)

    store.setHomeCategoryHidden(HomeCategoryKind.hindiMovies.id, true)

    let arranged = store.arrangedHomeCategories()
    XCTAssertEqual(arranged.map(\.id), ["hindi-movies", "anime"])
    XCTAssertEqual(arranged.first?.isHidden, true)
    let home = HomeShelfBuilder.shelves(
      from: titles, preferences: store.personal.homeCategories ?? HomeCategoryPreferences())
    XCTAssertEqual(home.map(\.id), ["anime"])
  }

  func testMoveStoresTheNewOrder() {
    let store = EntertainmentStore(library: LibraryController(), storageURL: makeStorage())
    store.rebuildHomeCategories(from: fixtureTitles())

    store.moveHomeCategory("anime", to: 0)
    XCTAssertEqual(store.arrangedHomeCategories().map(\.id), ["anime", "hindi-movies"])

    store.moveHomeCategory("anime", to: 1)
    XCTAssertEqual(store.arrangedHomeCategories().map(\.id), ["hindi-movies", "anime"])
  }

  func testResetRestoresDefaultOrderPinsAndVisibility() {
    let store = EntertainmentStore(library: LibraryController(), storageURL: makeStorage())
    store.rebuildHomeCategories(from: fixtureTitles())
    store.moveHomeCategory("anime", to: 0)
    store.setHomeCategoryPinned("hindi-movies", true)
    store.setHomeCategoryHidden("anime", true)

    store.resetHomeCategories()

    XCTAssertEqual(store.arrangedHomeCategories().map(\.id), ["hindi-movies", "anime"])
    XCTAssertTrue(store.arrangedHomeCategories().allSatisfy { !$0.isPinned && !$0.isHidden })
  }

  func testShelfTitlesFollowPinnedOrder() {
    let store = EntertainmentStore(library: LibraryController(), storageURL: makeStorage())
    let titles = fixtureTitles()
    store.rebuildHomeCategories(from: titles)
    store.setHomeCategoryPinned("anime", true)

    let shelves = HomeShelfBuilder.shelves(
      from: titles, preferences: store.personal.homeCategories ?? HomeCategoryPreferences())

    XCTAssertEqual(shelves.map(\.id), ["anime", "hindi-movies"])
    XCTAssertEqual(shelves.first?.titles.count, 8)
    XCTAssertTrue(shelves.first?.titles.allSatisfy { $0.kind == .series } ?? false)
    XCTAssertEqual(shelves.first?.subtitle, "Pinned • automatic shelf")
  }

  func testNoShelvesBelowThreshold() {
    let store = EntertainmentStore(library: LibraryController(), storageURL: makeStorage())
    store.rebuildHomeCategories(from: [helper.makeTitle("Lone", folder: "Hindi")])

    XCTAssertTrue(store.homeShelves.isEmpty)
    XCTAssertTrue(store.arrangedHomeCategories().isEmpty)
  }
}

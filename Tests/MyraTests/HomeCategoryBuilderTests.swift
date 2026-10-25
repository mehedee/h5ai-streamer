import Foundation
import XCTest

@testable import Myra

final class HomeCategoryBuilderTests: XCTestCase {
  /// Time budget for classifying and building shelves for 100,000 titles on the test machine.
  static let largeLibraryBudgetSeconds = 4.0

  private let helper = HomeCategoryClassifierTests()

  func testShelfAppearsOnlyAtThreshold() {
    XCTAssertEqual(HomeCategoryRules.minimumTitleCount, 8)
    let seven = (0..<7).map { helper.makeTitle("Film \($0)", folder: "Hindi") }
    XCTAssertTrue(HomeCategoryBuilder.categories(for: seven).isEmpty)

    let eight = (0..<8).map { helper.makeTitle("Film \($0)", folder: "Hindi") }
    let categories = HomeCategoryBuilder.categories(for: eight)
    XCTAssertEqual(categories.map(\.kind), [.hindiMovies])
    XCTAssertEqual(categories.first?.count, 8)
  }

  func testThresholdAppliesPerShelf() {
    let hindi = (0..<8).map { helper.makeTitle("Hindi \($0)", folder: "Hindi") }
    let english = (0..<3).map {
      helper.makeTitle("English \($0)", metadata: helper.metadata("English \($0)", language: "en"))
    }
    let categories = HomeCategoryBuilder.categories(for: hindi + english)
    XCTAssertEqual(categories.map(\.kind), [.hindiMovies])
  }

  func testCategoryIDsAreStableAndDocumented() {
    XCTAssertEqual(
      HomeCategoryKind.allCases.map(\.id),
      [
        "english-movies", "hindi-movies", "anime", "tv-series", "korean-series", "documentaries",
        "kids-and-family",
      ])
    XCTAssertEqual(HomeCategoryKind.allCases.map(\.displayName).count, 7)
    XCTAssertTrue(HomeCategoryKind.allCases.allSatisfy { !$0.rule.isEmpty })
  }

  func testBuildIsDeterministicAcrossInputOrder() {
    let titles = (0..<40).map { index in
      helper.makeTitle(
        "Film \(index % 5)", folder: "Hindi",
        metadata: helper.metadata("Film", language: "hi", rating: Double(index % 3)))
    }
    let forward = HomeCategoryBuilder.categories(for: titles)
    let reversed = HomeCategoryBuilder.categories(for: titles.reversed())
    XCTAssertEqual(forward, reversed)
  }

  func testTitlesSortByRatingThenNameThenID() {
    let titles = [
      helper.makeTitle("Beta", folder: "Hindi", metadata: helper.metadata("Beta", language: "hi", rating: 6)),
      helper.makeTitle("alpha", folder: "Hindi", metadata: helper.metadata("alpha", language: "hi", rating: 6)),
      helper.makeTitle("Gamma", folder: "Hindi", metadata: helper.metadata("Gamma", language: "hi", rating: 9)),
      helper.makeTitle("Delta", folder: "Hindi"),
      helper.makeTitle("Echo", folder: "Hindi"),
      helper.makeTitle("Foxtrot", folder: "Hindi"),
      helper.makeTitle("Golf", folder: "Hindi"),
      helper.makeTitle("Hotel", folder: "Hindi"),
    ]
    let ids = HomeCategoryBuilder.categories(for: titles).first?.titleIDs ?? []
    XCTAssertEqual(
      ids,
      [
        "movie|Gamma",
        "movie|alpha",
        "movie|Beta",
        "movie|Delta",
        "movie|Echo",
        "movie|Foxtrot",
        "movie|Golf",
        "movie|Hotel",
      ])
  }

  func testArrangedAppliesPreferences() {
    let titles = (0..<8).map { helper.makeTitle("Film \($0)", folder: "Hindi") }
      + (0..<8).map { helper.makeTitle("Show \($0)", kind: .series, folder: "Anime") }
    var preferences = HomeCategoryPreferences()
    preferences.setHidden(HomeCategoryKind.hindiMovies.id, true)
    preferences.setPinned(HomeCategoryKind.anime.id, true)
    let arranged = HomeCategoryBuilder.arranged(
      for: titles, preferences: preferences)
    XCTAssertEqual(arranged.map(\.id), ["anime", "hindi-movies"])
    XCTAssertEqual(arranged.map(\.isPinned), [true, false])
    XCTAssertEqual(arranged.map(\.isHidden), [false, true])
  }

  func testLargeLibraryClassifiesWithinBudget() {
    let folders = ["Hindi", "Anime", "K-Drama", "Documentaries", "Kids", "Movies", "TV Shows"]
    let titles: [EntertainmentTitle] = (0..<100_000).map { index in
      let folder = folders[index % folders.count]
      let kind: EntertainmentKind = index % 3 == 0 ? .series : .movie
      let metadata: EntertainmentMetadata? = index % 2 == 0
        ? helper.metadata(
          "T\(index)", language: index % 4 == 0 ? "en" : "hi",
          genres: index % 5 == 0 ? ["Documentary"] : ["Drama"], rating: Double(index % 10))
        : nil
      return helper.makeTitle(
        "Title \(index)", kind: kind, folder: folder, file: "Title.\(index).S01E01.mkv",
        metadata: metadata)
    }
    let start = ContinuousClock.now
    let categories = HomeCategoryBuilder.categories(for: titles)
    let elapsed = start.duration(to: .now)
    let seconds = Double(elapsed.components.seconds)
      + Double(elapsed.components.attoseconds) / 1e18
    print("HomeCategory 100k classify+build: \(String(format: "%.3f", seconds)) s")
    XCTAssertFalse(categories.isEmpty)
    XCTAssertLessThan(seconds, Self.largeLibraryBudgetSeconds)
  }
}

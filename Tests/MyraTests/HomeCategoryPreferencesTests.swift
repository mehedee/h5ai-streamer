import Foundation
import XCTest

@testable import Myra

final class HomeCategoryPreferencesTests: XCTestCase {
  private func category(_ kind: HomeCategoryKind, count: Int = 8) -> HomeCategory {
    HomeCategory(kind: kind, titleIDs: (0..<count).map { "\(kind.rawValue)-\($0)" })
  }

  func testRoundTripPreservesChoices() throws {
    var preferences = HomeCategoryPreferences()
    preferences.setHidden("anime", true)
    preferences.setPinned("korean-series", true)
    preferences.setOrder(["tv-series", "anime"])
    let data = try JSONEncoder().encode(preferences)
    let decoded = try JSONDecoder().decode(HomeCategoryPreferences.self, from: data)
    XCTAssertEqual(decoded, preferences)
    XCTAssertEqual(decoded.version, HomeCategoryPreferences.currentVersion)
  }

  func testEmptyObjectDecodesWithDefaults() throws {
    let decoded = try JSONDecoder().decode(HomeCategoryPreferences.self, from: Data("{}".utf8))
    XCTAssertEqual(decoded, HomeCategoryPreferences())
    XCTAssertEqual(decoded.version, 1)
  }

  func testPartialObjectKeepsPresentFieldsAndDefaultsTheRest() throws {
    let json = Data(#"{"version":1,"hidden":["anime"]}"#.utf8)
    let decoded = try JSONDecoder().decode(HomeCategoryPreferences.self, from: json)
    XCTAssertEqual(decoded.hidden, ["anime"])
    XCTAssertEqual(decoded.order, [])
    XCTAssertEqual(decoded.pinned, [])
  }

  func testCorruptFieldFallsBackToDefaultWithoutThrowing() throws {
    let json = Data(#"{"version":"x","order":42,"pinned":["anime"]}"#.utf8)
    let decoded = try JSONDecoder().decode(HomeCategoryPreferences.self, from: json)
    XCTAssertEqual(decoded.version, HomeCategoryPreferences.currentVersion)
    XCTAssertEqual(decoded.order, [])
    XCTAssertEqual(decoded.pinned, ["anime"])
  }

  func testPersonalDataWithoutHomeCategoriesStillDecodes() throws {
    var personal = EntertainmentPersonalData()
    personal.homeCategories = HomeCategoryPreferences(pinned: ["anime"])
    let encoded = try JSONEncoder().encode(personal)
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    XCTAssertNotNil(object["homeCategories"])

    // Personal data written before shelves existed has no homeCategories key.
    object.removeValue(forKey: "homeCategories")
    let legacy = try JSONSerialization.data(withJSONObject: object)
    let decoded = try JSONDecoder().decode(EntertainmentPersonalData.self, from: legacy)
    XCTAssertNil(decoded.homeCategories)

    let roundTrip = try JSONDecoder().decode(
      EntertainmentPersonalData.self, from: JSONEncoder().encode(personal))
    XCTAssertEqual(roundTrip.homeCategories?.pinned, ["anime"])
  }

  func testArrangePutsPinnedFirstThenOrderThenDefault() {
    let categories = [
      category(.englishMovies), category(.hindiMovies), category(.anime), category(.tvSeries),
    ]
    var preferences = HomeCategoryPreferences()
    preferences.setOrder(["tv-series", "anime"])
    preferences.setPinned("hindi-movies", true)
    let arranged = preferences.arrange(categories).map(\.id)
    XCTAssertEqual(arranged, ["hindi-movies", "tv-series", "anime", "english-movies"])
  }

  func testArrangeKeepsHiddenCategoriesForRestoring() {
    let categories = [category(.englishMovies), category(.anime)]
    var preferences = HomeCategoryPreferences()
    preferences.setHidden("anime", true)
    let arranged = preferences.arrange(categories)
    XCTAssertEqual(arranged.map(\.isHidden), [false, true])
    preferences.setHidden("anime", false)
    XCTAssertEqual(preferences.arrange(categories).map(\.isHidden), [false, false])
  }

  func testArrangeIgnoresUnknownIDsInOrder() {
    var preferences = HomeCategoryPreferences()
    preferences.setOrder(["gone", "anime", "anime"])
    XCTAssertEqual(preferences.order, ["gone", "anime"])
    let arranged = preferences.arrange([category(.englishMovies), category(.anime)])
    XCTAssertEqual(arranged.map(\.id), ["anime", "english-movies"])
  }

  func testMoveReordersWithinCurrentArrangement() {
    var preferences = HomeCategoryPreferences()
    let current = ["english-movies", "hindi-movies", "anime"]
    preferences.move("anime", to: 0, in: current)
    XCTAssertEqual(preferences.order, ["anime", "english-movies", "hindi-movies"])
    preferences.move("english-movies", to: 99, in: preferences.order)
    XCTAssertEqual(preferences.order, ["anime", "hindi-movies", "english-movies"])
  }
}

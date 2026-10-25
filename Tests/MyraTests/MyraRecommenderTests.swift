import XCTest

@testable import Myra

final class MyraRecommenderTests: XCTestCase {
  private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }()

  /// Wednesday 2026-10-21 at the given UTC hour.
  private func date(hour: Int, day: Int = 21) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
  }

  private func title(
    _ id: String, genres: [String], runtime: Int?, rating: Double = 7, language: String = "en",
    kind: EntertainmentKind = .movie, overview: String = ""
  ) -> EntertainmentTitle {
    let root = URL(string: "https://media.example/Fixture/")!
    let media = GlobalSearchResult(
      categoryID: UUID(), categoryName: "Fixture", categoryRoot: root,
      entry: DirectoryEntry(name: "\(id).mkv", url: root.appending(path: "\(id).mkv"), kind: .file),
      relativePath: "\(id).mkv", artworkURL: nil)
    return EntertainmentTitle(
      id: id, name: id, year: "2020", kind: kind,
      versions: [EntertainmentVersion(media: media, firstDiscovered: .distantPast)],
      metadata: EntertainmentMetadata(
        providerID: 1, title: id, overview: overview, posterURL: nil, rating: rating,
        voteCount: 100, releaseDate: nil, genres: genres, language: language,
        runtimeMinutes: runtime))
  }

  private var library: [EntertainmentTitle] {
    [
      title("paddington", genres: ["Family", "Comedy"], runtime: 95, overview: "A heartwarming bear"),
      title("hereditary", genres: ["Horror", "Drama"], runtime: 127, rating: 7.3),
      title("arrival", genres: ["Science Fiction", "Drama"], runtime: 116, rating: 8.2),
      title("oppenheimer", genres: ["Drama", "History"], runtime: 180, rating: 8.4),
      title("unknown", genres: ["Comedy"], runtime: nil),
      title("amelie", genres: ["Comedy", "Romance"], runtime: 122, language: "fr"),
    ]
  }

  func testRecommendationsAreGroundedAndExcludeWatchedDislikedDismissed() {
    var personal = EntertainmentPersonalData()
    personal.watched = ["arrival"]
    let context = MyraViewingContext(
      date: date(hour: 15), calendar: calendar, disliked: ["hereditary"], dismissed: ["amelie"])
    let results = MyraRecommender.recommend(titles: library, personal: personal, context: context)
    let ids = Set(results.map(\.id))
    XCTAssertTrue(ids.isSubset(of: Set(library.map(\.id))))
    XCTAssertFalse(ids.contains("arrival"))
    XCTAssertFalse(ids.contains("hereditary"))
    XCTAssertFalse(ids.contains("amelie"))
  }

  func testExplicitBudgetIsNeverExceededAndUnknownRuntimesAreExcluded() {
    let context = MyraViewingContext(date: date(hour: 15), calendar: calendar, availableMinutes: 120)
    let results = MyraRecommender.recommend(
      titles: library, personal: .init(), context: context, limit: 20)
    XCTAssertFalse(results.isEmpty)
    for result in results {
      let runtime = try? XCTUnwrap(MyraAIContext.runtime(result.title))
      XCTAssertNotNil(runtime)
      XCTAssertLessThanOrEqual(runtime ?? .max, 120)
    }
  }

  func testWeeknightLateNightInfersShortBudget() {
    let context = MyraViewingContext(date: date(hour: 23), calendar: calendar)
    XCTAssertEqual(context.dayPart, .lateNight)
    XCTAssertEqual(context.effectiveMinutes?.minutes, 110)
    XCTAssertEqual(context.effectiveMinutes?.explicit, false)
    let ids = MyraRecommender.recommend(
      titles: library, personal: .init(), context: context, limit: 20
    ).map(\.id)
    XCTAssertFalse(ids.contains("oppenheimer"))
    XCTAssertTrue(ids.contains("unknown"), "Inferred budgets keep titles with unknown runtime")
  }

  func testCosyMoodRanksFamilyComedyAboveHorror() {
    let context = MyraViewingContext(date: date(hour: 19), calendar: calendar, mood: .cosy)
    let ids = MyraRecommender.recommend(
      titles: library, personal: .init(), context: context, limit: 20
    ).map(\.id)
    XCTAssertEqual(ids.first, "paddington")
    if let horror = ids.firstIndex(of: "hereditary") {
      XCTAssertGreaterThan(horror, ids.firstIndex(of: "paddington")!)
    }
  }

  func testAvoidedGenresAndLanguageAreHardConstraints() {
    let context = MyraViewingContext(
      date: date(hour: 19), calendar: calendar, avoidGenres: ["drama"], languages: ["en"])
    let results = MyraRecommender.recommend(
      titles: library, personal: .init(), context: context, limit: 20)
    for result in results {
      XCTAssertFalse(result.title.metadata!.genres.contains("Drama"))
      XCTAssertEqual(result.title.metadata?.language, "en")
    }
  }

  func testSeedIsDeterministic() {
    let context = MyraViewingContext(date: date(hour: 19), calendar: calendar, seed: 42)
    let first = MyraRecommender.recommend(titles: library, personal: .init(), context: context)
    let second = MyraRecommender.recommend(titles: library, personal: .init(), context: context)
    XCTAssertEqual(first.map(\.id), second.map(\.id))
  }

  func testLargeLibraryStaysWithinRuntimeBudget() {
    let titles = (0..<20_000).map {
      title("t\($0)", genres: [["Comedy"], ["Drama"], ["Horror"]][$0 % 3], runtime: 80 + $0 % 90)
    }
    let context = MyraViewingContext(date: date(hour: 19), calendar: calendar, mood: .funny)
    let start = Date()
    let results = MyraRecommender.recommend(titles: titles, personal: .init(), context: context)
    XCTAssertEqual(results.count, 8)
    XCTAssertLessThan(Date().timeIntervalSince(start), 2)
  }

  func testProfilesWithoutFeedbackStillDecode() throws {
    let legacy = try JSONEncoder().encode(EntertainmentPersonalData())
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: legacy) as? [String: Any])
    object.removeValue(forKey: "recommendationFeedback")
    let decoded = try JSONDecoder().decode(
      EntertainmentPersonalData.self, from: JSONSerialization.data(withJSONObject: object))
    XCTAssertNil(decoded.recommendationFeedback)
  }

  func testDismissalsExpireAfterOneEvening() {
    let now = date(hour: 21)
    let feedback = MyraRecommendationFeedback(
      dismissed: ["recent": now.addingTimeInterval(-3600), "old": now.addingTimeInterval(-86_400)])
    XCTAssertEqual(feedback.activeDismissals(at: now), ["recent"])
  }

  @MainActor
  func testReactionsPersistToPersonalDataFile() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "Myra-Rec-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = directory.appending(path: "Personal.json")
    let index = try LibraryIndex(url: directory.appending(path: "Index.sqlite"))
    let store = EntertainmentStore(
      library: LibraryController(index: index), storageURL: storage, automaticEnrichment: false)
    store.react(.like, to: "a")
    store.react(.dislike, to: "a")
    store.react(.like, to: "b")
    store.react(.notTonight, to: "c", at: date(hour: 21))
    let saved = try JSONDecoder().decode(
      EntertainmentPersonalData.self, from: Data(contentsOf: storage)
    ).recommendationFeedback
    XCTAssertEqual(saved?.liked, ["b"])
    XCTAssertEqual(saved?.disliked, ["a"], "Like and dislike are mutually exclusive")
    XCTAssertEqual(saved?.dismissed["c"], date(hour: 21))
  }
}

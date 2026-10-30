import XCTest

@testable import Myra

/// Phase 5: smart collections, the best-version picker and the Needs Attention analysis. All
/// inputs are in-memory titles, so no library or profile is opened.
final class LibraryQualityTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_750_000_000)

  // MARK: - Smart collections

  private func sampleTitles() -> [EntertainmentTitle] {
    let uhd = QualityFixture.title(
      "Sintel", versions: [QualityFixture.version("Sintel.2160p.mkv")],
      metadata: QualityFixture.metadata(genres: ["Animation"], runtime: 15))
    let hd = QualityFixture.title(
      "Heist", versions: [QualityFixture.version("Heist.1080p.mkv")],
      metadata: QualityFixture.metadata(genres: ["Thriller"], runtime: 110))
    let series = QualityFixture.title(
      "Show", kind: .series,
      versions: [QualityFixture.version("Show.S01E01.720p.mkv", season: 1, episode: 1)],
      metadata: QualityFixture.metadata(language: "ko", runtime: 45, rating: 8.4))
    return [uhd, hd, series]
  }

  func testRuleValidityRequiresFieldOperatorsAndNumbers() {
    XCTAssertTrue(SmartRule(field: .quality, value: "2160p").isValid)
    XCTAssertFalse(SmartRule(field: .watched, op: .atLeast, value: "yes").isValid)
    XCTAssertFalse(SmartRule(field: .runtime, op: .under, value: "long").isValid)
    XCTAssertFalse(SmartRule(field: .genre, value: "  ").isValid)
  }

  func testCollectionValidityNeedsNameAndCompleteRules() {
    var collection = SmartCollection(name: "Four K", rules: [SmartRule(field: .quality, value: "2160p")])
    XCTAssertTrue(SmartCollectionRules.isValid(collection))
    collection.name = "   "
    XCTAssertFalse(SmartCollectionRules.isValid(collection))
    collection.name = "Empty"
    collection.rules = []
    XCTAssertFalse(SmartCollectionRules.isValid(collection))
  }

  func testQualityAndWatchedRulesCombineWithAnd() {
    let titles = sampleTitles()
    let rules = [SmartRule(field: .quality, value: "2160p"), SmartRule(field: .watched, value: "no")]
    XCTAssertEqual(SmartCollectionRules.titles(matching: rules, in: titles, watched: []).map(\.name), ["Sintel"])
    XCTAssertTrue(
      SmartCollectionRules.titles(matching: rules, in: titles, watched: [titles[0].id]).isEmpty)
  }

  func testFourKIsTreatedAsTwoThousandSixtyPixels() {
    let fourK = QualityFixture.title("Film", versions: [QualityFixture.version("Film.4K.mkv")])
    let rules = [SmartRule(field: .quality, value: "2160p")]
    XCTAssertEqual(SmartCollectionRules.count(matching: rules, in: [fourK], watched: []), 1)
  }

  func testRuntimeUnderAndAtLeast() {
    let titles = sampleTitles()
    let short = [SmartRule(field: .runtime, op: .under, value: "30")]
    XCTAssertEqual(SmartCollectionRules.titles(matching: short, in: titles, watched: []).map(\.name), ["Sintel"])
    let long = [SmartRule(field: .runtime, op: .atLeast, value: "100")]
    XCTAssertEqual(SmartCollectionRules.titles(matching: long, in: titles, watched: []).map(\.name), ["Heist"])
  }

  func testLanguageAndGenreAreCaseInsensitive() {
    let titles = sampleTitles()
    let korean = [SmartRule(field: .language, value: "KO")]
    XCTAssertEqual(SmartCollectionRules.titles(matching: korean, in: titles, watched: []).map(\.name), ["Show"])
    let notAnimation = [SmartRule(field: .genre, op: .isNot, value: "animation")]
    XCTAssertEqual(
      SmartCollectionRules.titles(matching: notAnimation, in: titles, watched: []).map(\.name),
      ["Heist", "Show"])
  }

  func testRatingAndAddedWithinDays() {
    let recent = QualityFixture.title(
      "New", versions: [QualityFixture.version("New.mkv", discovered: now.addingTimeInterval(-3 * 86_400))],
      metadata: QualityFixture.metadata(rating: 6.0))
    let old = QualityFixture.title(
      "Old", versions: [QualityFixture.version("Old.mkv", discovered: now.addingTimeInterval(-90 * 86_400))],
      metadata: QualityFixture.metadata(rating: 9.0))
    let added = [SmartRule(field: .added, value: "7")]
    XCTAssertEqual(SmartCollectionRules.titles(matching: added, in: [recent, old], watched: [], now: now).map(\.name), ["New"])
    let rated = [SmartRule(field: .rating, op: .atLeast, value: "8")]
    XCTAssertEqual(SmartCollectionRules.titles(matching: rated, in: [recent, old], watched: [], now: now).map(\.name), ["Old"])
  }

  func testEmptyRuleSetMatchesNothing() {
    XCTAssertEqual(SmartCollectionRules.count(matching: [], in: sampleTitles(), watched: []), 0)
  }

  func testDefaultsArePinnedAndValid() {
    let defaults = SmartCollectionRules.defaults
    XCTAssertEqual(defaults.filter(\.pinnedToHome).map(\.name), ["Unwatched 4K", "Under 30 minutes"])
    XCTAssertTrue(defaults.allSatisfy(SmartCollectionRules.isValid))
    XCTAssertEqual(Set(defaults.map(\.id)).count, defaults.count)
  }

  func testSmartCollectionRoundTripsThroughJSON() throws {
    let collection = SmartCollection(
      name: "Family", rules: [SmartRule(field: .genre, value: "Family"), SmartRule(field: .runtime, op: .under, value: "120")],
      pinnedToHome: true)
    let decoded = try JSONDecoder().decode(
      SmartCollection.self, from: JSONEncoder().encode(collection))
    XCTAssertEqual(decoded, collection)
  }

  // MARK: - Best version

  private func versions(_ names: [String]) -> [EntertainmentVersion] {
    names.map { QualityFixture.version($0) }
  }

  func testHighestQualityWhenNothingIsPreferred() throws {
    let list = versions(["Film.720p.mkv", "Film.2160p.mkv", "Film.1080p.mkv"])
    let choice = try XCTUnwrap(BestVersionPicker.choose(versions: list, titleQuality: nil, preferredQuality: nil))
    XCTAssertEqual(choice.version.media.entry.name, "Film.2160p.mkv")
    XCTAssertTrue(choice.reason.contains("Highest quality available, 2160p"), choice.reason)
    XCTAssertFalse(choice.followsTitlePreference)
  }

  func testGlobalPreferenceIsExplained() throws {
    let list = versions(["Film.2160p.mkv", "Film.1080p.mkv"])
    let choice = try XCTUnwrap(BestVersionPicker.choose(versions: list, titleQuality: nil, preferredQuality: "1080p"))
    XCTAssertEqual(choice.version.media.entry.name, "Film.1080p.mkv")
    XCTAssertEqual(choice.reason, "Matches your preferred 1080p")
  }

  func testTitlePreferenceWinsOverGlobalAndIsMarked() throws {
    let list = versions(["Film.2160p.mkv", "Film.1080p.mkv"])
    let choice = try XCTUnwrap(BestVersionPicker.choose(versions: list, titleQuality: "2160p", preferredQuality: "1080p"))
    XCTAssertEqual(choice.version.media.entry.name, "Film.2160p.mkv")
    XCTAssertTrue(choice.followsTitlePreference)
    XCTAssertEqual(choice.reason, "Always use 2160p for this title")
  }

  func testMissingPreferredQualityFallsBackBelowThenAbove() throws {
    let below = try XCTUnwrap(
      BestVersionPicker.choose(
        versions: versions(["Film.480p.mkv", "Film.720p.mkv", "Film.2160p.mkv"]), titleQuality: nil,
        preferredQuality: "1080p"))
    XCTAssertEqual(below.version.media.entry.name, "Film.720p.mkv")
    XCTAssertTrue(below.reason.contains("No 1080p release"), below.reason)
    XCTAssertTrue(below.reason.contains("720p"), below.reason)

    let above = try XCTUnwrap(
      BestVersionPicker.choose(
        versions: versions(["Film.2160p.mkv", "Film.4K.Remux.mkv"]), titleQuality: "720p", preferredQuality: nil))
    XCTAssertEqual(above.version.media.entry.name, "Film.2160p.mkv")
  }

  func testUntaggedFilesAreExplainedAndUseFirstFile() throws {
    let list = versions(["zeta.mkv", "alpha.mkv"])
    let choice = try XCTUnwrap(BestVersionPicker.choose(versions: list, titleQuality: nil, preferredQuality: nil))
    XCTAssertEqual(choice.version.media.entry.name, "zeta.mkv")
    XCTAssertTrue(choice.reason.contains("not tagged"), choice.reason)
  }

  func testNoVersionsGivesNoChoice() {
    XCTAssertNil(BestVersionPicker.choose(versions: [], titleQuality: "1080p", preferredQuality: nil))
  }

  // MARK: - Needs Attention

  func testUnmatchedTitleWithoutYearHasLowConfidenceGuess() {
    let title = QualityFixture.title("IMG 4471", versions: [QualityFixture.version("IMG_4471.mov")])
    let items = AttentionAnalysis.items(for: [title])
    XCTAssertEqual(items.map(\.kind), [.unmatched])
    XCTAssertEqual(items.first?.isConfident, false)
    XCTAssertEqual(items.first?.guess?.confidence, 60)
  }

  func testUnmatchedTitleWithYearIsConfidentAndAcceptedInBulk() {
    let year = QualityFixture.title(
      "Hero", versions: [QualityFixture.version("Hero.2018.1080p.mkv")], year: "2018")
    let noYear = QualityFixture.title("Spring", versions: [QualityFixture.version("spring.mp4")])
    let items = AttentionAnalysis.items(for: [year, noYear])
    let confident = AttentionAnalysis.confidentItems(items)
    XCTAssertEqual(confident.map(\.displayName), ["Hero"])
    XCTAssertEqual(confident.first?.guess?.year, "2018")
  }

  func testWrongMatchWhenReleaseYearDisagrees() {
    let title = QualityFixture.title(
      "Charge", versions: [QualityFixture.version("Charge (2022).mkv")],
      metadata: QualityFixture.metadata(title: "Charge", year: "2017"), year: "2022")
    let items = AttentionAnalysis.items(for: [title])
    XCTAssertEqual(items.map(\.kind), [.wrongMatch])
    XCTAssertEqual(items.first?.guess?.year, "2017")
    XCTAssertFalse(items.first?.isConfident ?? true)
  }

  func testMissingPosterIsReportedWhenNoArtworkExists() {
    let title = QualityFixture.title(
      "Safar", versions: [QualityFixture.version("Safar (2020).mkv")],
      metadata: QualityFixture.metadata(poster: false), year: "2020")
    XCTAssertEqual(AttentionAnalysis.items(for: [title]).map(\.kind), [.missingPoster])
  }

  func testTwoFilesForOneMovieAreDuplicates() {
    let title = QualityFixture.title(
      "Sintel", versions: [
        QualityFixture.version("Sintel.2160p.mkv"), QualityFixture.version("Sintel.1080p.mkv"),
      ], metadata: QualityFixture.metadata(year: "2010"), year: "2010")
    let items = AttentionAnalysis.items(for: [title])
    XCTAssertEqual(items.map(\.kind), [.duplicate])
    XCTAssertTrue(items.first?.note.contains("2160p and 1080p") ?? false, items.first?.note ?? "")
  }

  func testDifferentEpisodesAreNotDuplicates() {
    let episodes = QualityFixture.title(
      "Show", kind: .series, versions: [
        QualityFixture.version("Show.S01E01.mkv", season: 1, episode: 1),
        QualityFixture.version("Show.S01E02.mkv", season: 1, episode: 2),
      ], metadata: QualityFixture.metadata(), year: nil)
    XCTAssertFalse(AttentionAnalysis.hasDuplicateEpisodes(episodes.versions))
    XCTAssertFalse(AttentionAnalysis.items(for: [episodes]).contains { $0.kind == .duplicate })
  }

  func testItemsAreOrderedByKindThenName() {
    let titles = [
      QualityFixture.title("Zed", versions: [QualityFixture.version("zed.mkv")]),
      QualityFixture.title("Alpha", versions: [QualityFixture.version("alpha.mkv")]),
    ]
    XCTAssertEqual(AttentionAnalysis.items(for: titles).map(\.displayName), ["Alpha", "Zed"])
  }
}

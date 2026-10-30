import XCTest

@testable import Myra

/// Insights aggregation over fixed watch-history fixtures. The clock and calendar are fixed, so the
/// expected numbers are exact and do not depend on the day the tests run.
final class InsightsTests: XCTestCase {
  private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }

  /// 30 October 2026, noon UTC.
  private var now: Date { date(2026, 10, 30) }

  private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
  }

  private func version(
    _ file: String, played: Date?, progress: Double = 0, duration: Double = 0
  ) -> EntertainmentVersion {
    let root = URL(filePath: "/Fixtures/Insights")
    let url = root.appending(path: file)
    let entry = DirectoryEntry(name: file, url: url, kind: .file)
    let media = GlobalSearchResult(
      categoryID: UUID(uuidString: "00000000-0000-0000-0000-00000000A900")!,
      categoryName: "Fixture", categoryRoot: root, entry: entry, relativePath: file,
      artworkURL: nil)
    var value = EntertainmentVersion(media: media, firstDiscovered: .distantPast)
    value.lastPlayed = played
    value.progressSeconds = progress
    value.duration = duration
    return value
  }

  private func title(
    _ id: String, _ name: String, kind: EntertainmentKind = .movie, genres: [String] = [],
    runtime: Int? = nil, versions: [EntertainmentVersion] = []
  ) -> EntertainmentTitle {
    let metadata: EntertainmentMetadata? =
      genres.isEmpty && runtime == nil
      ? nil
      : EntertainmentMetadata(
        providerID: 1, title: name, overview: "", posterURL: nil, rating: 7, voteCount: 10,
        releaseDate: nil, genres: genres, language: "en", runtimeMinutes: runtime)
    return EntertainmentTitle(
      id: id, name: name, year: "2024", kind: kind, versions: versions, metadata: metadata)
  }

  /// A small history: two episodes of a series (one overshoots its duration), a movie watched
  /// this year, a file opened with no progress, a movie watched last year, and a movie marked
  /// watched with no playback record at all.
  private func fixtureCatalogue() -> [EntertainmentTitle] {
    [
      title(
        "series|harbour|2024", "Harbour Watch", kind: .series, genres: ["Drama"],
        versions: [
          version("harbour-e1.mkv", played: date(2026, 10, 30), progress: 2400, duration: 3000),
          version("harbour-e2.mkv", played: date(2026, 10, 29), progress: 3000, duration: 2800),
        ]),
      title(
        "movie|sintel|2024", "Sintel", genres: ["Animation"],
        versions: [version("sintel.mkv", played: date(2026, 3, 14), progress: 900)]),
      title(
        "movie|opened|2024", "Opened Only", genres: ["Comedy"],
        versions: [version("opened.mkv", played: date(2026, 10, 5), progress: 0)]),
      title(
        "movie|oldfilm|2024", "Old Film", genres: ["Anime"],
        versions: [version("oldfilm.mkv", played: date(2025, 6, 1), progress: 6000, duration: 6000)]),
      title("movie|marked|2024", "Marked Movie", runtime: 100),
    ]
  }

  private let watched: Set<String> = ["series|harbour|2024", "movie|marked|2024"]

  private func samples() -> [InsightsSample] {
    InsightsHistory.samples(
      catalogue: fixtureCatalogue(),
      personal: EntertainmentPersonalData(watched: watched))
  }

  func testSamplesCapProgressAtDurationAndAddUndatedWatchedTitles() {
    let values = samples()
    let episodeTwo = values.first { $0.titleName == "Harbour Watch" && $0.playedAt == date(2026, 10, 29) }
    XCTAssertEqual(episodeTwo?.seconds, 2800, "Progress never exceeds the known duration")

    let undated = values.filter { $0.playedAt == nil }
    XCTAssertEqual(undated.map(\.titleName), ["Marked Movie"])
    XCTAssertEqual(undated.first?.seconds, 6000, "A marked movie uses its metadata runtime")
    XCTAssertFalse(values.contains { $0.titleName == "Harbour Watch" && $0.playedAt == nil },
      "A watched title with playback gets no undated sample")
  }

  func testThisYearTotalsUseOnlyPlaybackInsidePeriod() {
    let summary = InsightsSummary.make(
      samples: samples(), watchedTitleIDs: watched, period: .thisYear, now: now,
      calendar: calendar)

    XCTAssertEqual(summary.periodLabel, "2026")
    // Episode 1 (2400 s) + episode 2 (2800 s capped) + Sintel (900 s) = 6100 s.
    XCTAssertEqual(summary.hoursWatched, 6100.0 / 3600, accuracy: 0.0001)
    XCTAssertEqual(summary.titlesFinished, 1, "Only Harbour Watch is finished within 2026")
    XCTAssertEqual(summary.mostWatched.map(\.name), ["Harbour Watch", "Sintel"])
    XCTAssertEqual(summary.mostWatched.first?.hours ?? 0, 5200.0 / 3600, accuracy: 0.0001)
    XCTAssertEqual(summary.hoursByMonth.count, 12)
    XCTAssertEqual(summary.hoursByMonth[9], 5200.0 / 3600, accuracy: 0.0001, "October")
    XCTAssertEqual(summary.hoursByMonth[2], 900.0 / 3600, accuracy: 0.0001, "March")
  }

  func testTopGenreIsShareOfHoursWithGenreData() throws {
    let summary = InsightsSummary.make(
      samples: samples(), watchedTitleIDs: watched, period: .thisYear, now: now,
      calendar: calendar)
    let genre = try XCTUnwrap(summary.topGenre)
    XCTAssertEqual(genre.name, "Drama")
    // Drama 5200 s of 6100 s with genre data.
    XCTAssertEqual(genre.share, 5200.0 / 6100, accuracy: 0.0001)
  }

  func testLastYearAndAllTimeCoverDifferentHistory() throws {
    let lastYear = InsightsSummary.make(
      samples: samples(), watchedTitleIDs: watched, period: .lastYear, now: now,
      calendar: calendar)
    XCTAssertEqual(lastYear.periodLabel, "2025")
    XCTAssertEqual(lastYear.hoursWatched, 6000.0 / 3600, accuracy: 0.0001)
    XCTAssertEqual(lastYear.titlesFinished, 0)
    XCTAssertEqual(lastYear.topGenre?.name, "Anime")
    XCTAssertEqual(lastYear.hoursByMonth[5], 6000.0 / 3600, accuracy: 0.0001, "June 2025")

    let all = InsightsSummary.make(
      samples: samples(), watchedTitleIDs: watched, period: .allTime, now: now,
      calendar: calendar)
    XCTAssertEqual(all.periodLabel, "All time")
    // 2400 + 2800 + 900 + 6000 (old film) + 6000 (marked movie, undated) = 18100 s.
    XCTAssertEqual(all.hoursWatched, 18100.0 / 3600, accuracy: 0.0001)
    XCTAssertEqual(all.titlesFinished, 2, "Harbour Watch and Marked Movie")
    XCTAssertTrue(all.hoursByMonth.isEmpty, "Monthly hours need a single year")
    let genre = try XCTUnwrap(all.topGenre)
    XCTAssertEqual(genre.name, "Anime", "Old Film (6000 s) outweighs Drama (5200 s)")
  }

  func testCurrentStreakCountsBackFromTodayOrYesterday() {
    let playDays = Set(
      [date(2026, 10, 30), date(2026, 10, 29), date(2026, 10, 27)].map {
        calendar.startOfDay(for: $0)
      })
    XCTAssertEqual(
      InsightsSummary.currentStreak(playDays: playDays, now: now, calendar: calendar), 2,
      "Today and yesterday, the 27th breaks the run")

    let yesterdayOnly = Set([date(2026, 10, 29), date(2026, 10, 28)].map {
      calendar.startOfDay(for: $0)
    })
    XCTAssertEqual(
      InsightsSummary.currentStreak(playDays: yesterdayOnly, now: now, calendar: calendar), 2,
      "A streak still counts when today has no playback yet")

    let stale = Set([date(2026, 10, 27)].map { calendar.startOfDay(for: $0) })
    XCTAssertEqual(
      InsightsSummary.currentStreak(playDays: stale, now: now, calendar: calendar), 0)
  }

  func testStreakIsIndependentOfThePeriod() {
    let thisYear = InsightsSummary.make(
      samples: samples(), watchedTitleIDs: watched, period: .thisYear, now: now,
      calendar: calendar)
    let lastYear = InsightsSummary.make(
      samples: samples(), watchedTitleIDs: watched, period: .lastYear, now: now,
      calendar: calendar)
    XCTAssertEqual(thisYear.currentStreakDays, 2)
    XCTAssertEqual(lastYear.currentStreakDays, 2)
  }

  func testEmptyHistoryHasNoSamplesAndNoGenre() {
    let summary = InsightsSummary.make(
      samples: [], watchedTitleIDs: [], period: .allTime, now: now, calendar: calendar)
    XCTAssertFalse(summary.hasHistory)
    XCTAssertEqual(summary.hoursWatched, 0)
    XCTAssertNil(summary.topGenre)
    XCTAssertTrue(summary.mostWatched.isEmpty)
    XCTAssertEqual(summary.shareText(), "Myra Insights, All time\nNo watch history yet.")
  }

  func testShareTextIsPlainTextWithNoLinks() {
    let summary = InsightsSummary.make(
      samples: samples(), watchedTitleIDs: watched, period: .thisYear, now: now,
      calendar: calendar)
    let text = summary.shareText()

    XCTAssertTrue(text.hasPrefix("Myra Insights, 2026\n"))
    XCTAssertTrue(text.contains("Hours watched: 1.7"))
    XCTAssertTrue(text.contains("Titles finished: 1"))
    XCTAssertTrue(text.contains("Current watch streak: 2 days"))
    XCTAssertTrue(text.contains("Top genre: Drama (85%)"))
    XCTAssertTrue(text.contains("1. Harbour Watch, 1.4 h"))
    XCTAssertFalse(text.contains("http"), "The summary never includes links")
    XCTAssertTrue(text.contains("Nothing was uploaded."))
  }

  func testPeriodYearsFollowTheClock() {
    XCTAssertEqual(InsightsPeriod.thisYear.year(now: now, calendar: calendar), 2026)
    XCTAssertEqual(InsightsPeriod.lastYear.year(now: now, calendar: calendar), 2025)
    XCTAssertNil(InsightsPeriod.allTime.year(now: now, calendar: calendar))
  }
}

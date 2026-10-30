import Foundation
import XCTest

@testable import Myra

final class PlayerPlaybackExtrasTests: XCTestCase {
  // MARK: Subtitle sync

  func testSubtitleSyncClampsAndStepsInMilliseconds() {
    XCTAssertEqual(PlayerSubtitleSync.clamped(40_000), PlayerSubtitleSync.limitMilliseconds)
    XCTAssertEqual(PlayerSubtitleSync.clamped(-40_000), -PlayerSubtitleSync.limitMilliseconds)
    XCTAssertEqual(PlayerSubtitleSync.adjusted(0, by: -100), -100)
    XCTAssertEqual(PlayerSubtitleSync.adjusted(29_950, by: 100), PlayerSubtitleSync.limitMilliseconds)
    XCTAssertEqual(PlayerSubtitleSync.microseconds(250), 250_000)
    XCTAssertEqual(PlayerSubtitleSync.label(250), "+250 ms")
    XCTAssertEqual(PlayerSubtitleSync.label(-100), "−100 ms")
    XCTAssertEqual(PlayerSubtitleSync.label(0), "0 ms")
  }

  func testSubtitleOffsetIsSharedByEpisodesAndVersionsOfOneTitle() {
    let first = PlayerSubtitleSync.titleKey(filename: "Show.S01E01.1080p.WEB-DL.mkv")
    XCTAssertEqual(first, PlayerSubtitleSync.titleKey(filename: "Show.S01E02.720p.mkv"))
    XCTAssertEqual(
      PlayerSubtitleSync.titleKey(filename: "Movie.2025.1080p.mkv"),
      PlayerSubtitleSync.titleKey(filename: "Movie.2025.2160p.BluRay.mkv"))
    XCTAssertNotEqual(first, PlayerSubtitleSync.titleKey(filename: "Other.S01E01.1080p.mkv"))
  }

  func testRememberedSubtitleOffsetPersistsPerTitleAndClearsAtZero() throws {
    var state = PlayerPersonalState()
    let key = PlayerSubtitleSync.titleKey(filename: "Show.S01E01.mkv")
    XCTAssertEqual(PlayerSubtitleSync.stored(key: key, in: state), 0)

    PlayerSubtitleSync.remembered(250, key: key, in: &state)
    XCTAssertEqual(PlayerSubtitleSync.stored(key: key, in: state), 250)
    XCTAssertEqual(state.subtitleSync, [key: 250])

    let defaults = try XCTUnwrap(UserDefaults(suiteName: "Myra.tests.\(UUID())"))
    try state.save(defaults: defaults)
    let reloaded = PlayerPersonalState.load(defaults: defaults)
    XCTAssertEqual(PlayerSubtitleSync.stored(key: key, in: reloaded), 250)

    PlayerSubtitleSync.remembered(0, key: key, in: &state)
    XCTAssertNil(state.subtitleSync)
  }

  func testStatesSavedBeforeSubtitleSyncStillDecode() throws {
    let json = """
      {"speed":1,"audioLanguage":"en","subtitleLanguage":"en","autoplay":true,
       "automaticSkipping":false,"markers":{}}
      """
    let state = try JSONDecoder().decode(PlayerPersonalState.self, from: Data(json.utf8))
    XCTAssertNil(state.subtitleSync)
    XCTAssertEqual(state.speed, 1)
  }

  // MARK: Skip Intro from chapters

  func testIntroChapterOffersSkipOnlyInsideTheOpeningWindow() {
    let chapters = [PlayerChapter(id: 0, name: "Intro", startSeconds: 0, durationSeconds: 90)]
    XCTAssertEqual(
      PlayerIntroSkip.range(in: chapters, elapsed: 10, duration: 1_400),
      PlayerSkipRange(start: 0, end: 90))
    XCTAssertNil(PlayerIntroSkip.range(in: chapters, elapsed: 90, duration: 1_400))
    XCTAssertNil(PlayerIntroSkip.range(in: chapters, elapsed: 151, duration: 1_400))
  }

  func testOpeningChapterWithoutDurationEndsAtTheNextChapter() {
    let chapters = [
      PlayerChapter(id: 0, name: "Opening", startSeconds: 20, durationSeconds: nil),
      PlayerChapter(id: 1, name: "Act 1", startSeconds: 110, durationSeconds: nil),
    ]
    XCTAssertEqual(
      PlayerIntroSkip.range(in: chapters, elapsed: 30, duration: 1_400),
      PlayerSkipRange(start: 20, end: 110))
    XCTAssertNil(PlayerIntroSkip.range(in: chapters, elapsed: 5, duration: 1_400))
  }

  func testChaptersWithoutIntroNamesOrLateIntrosAreIgnored() {
    let unnamed = [
      PlayerChapter(id: 0, name: "Cold Open", startSeconds: 0, durationSeconds: 60),
      PlayerChapter(id: 1, name: "Chapter 2", startSeconds: 60, durationSeconds: 60),
    ]
    XCTAssertNil(PlayerIntroSkip.range(in: unnamed, elapsed: 10, duration: 1_400))
    let late = [PlayerChapter(id: 0, name: "Intro", startSeconds: 200, durationSeconds: 60)]
    XCTAssertNil(PlayerIntroSkip.range(in: late, elapsed: 205, duration: 1_400))
  }

  func testMissingTimingOrImpossibleRangesGiveNoSkip() {
    let untimed = [PlayerChapter(id: 0, name: "Intro")]
    XCTAssertNil(PlayerIntroSkip.range(in: untimed, elapsed: 5, duration: 1_400))
    let overrun = [PlayerChapter(id: 0, name: "Intro", startSeconds: 0, durationSeconds: 300)]
    XCTAssertNil(PlayerIntroSkip.range(in: overrun, elapsed: 5, duration: 200))
    XCTAssertNil(PlayerIntroSkip.range(in: overrun, elapsed: .nan, duration: 1_400))
    XCTAssertNil(PlayerIntroSkip.range(in: overrun, elapsed: 5, duration: 0))
  }

  func testIntroNameMatching() {
    XCTAssertTrue(PlayerIntroSkip.isIntroName("INTRO"))
    XCTAssertTrue(PlayerIntroSkip.isIntroName("Opening Credits"))
    XCTAssertFalse(PlayerIntroSkip.isIntroName("Outro"))
    XCTAssertFalse(PlayerIntroSkip.isIntroName("Credits"))
  }

  // MARK: Picture in Picture and AirPlay

  func testAirPlayIsHiddenWithAReasonBecauseTheEngineIsVLCKit() {
    XCTAssertFalse(PlayerPictureInPictureSupport.airPlayAvailable)
    XCTAssertFalse(PlayerPictureInPictureSupport.airPlayUnavailableReason.isEmpty)
  }

  @MainActor
  func testClosingPictureInPictureWindowIsNotReportedAsUserClose() {
    let model = EmbeddedPlayerModel()
    let window = PlayerPictureInPictureWindow(player: model)
    var reportedUserClose = false
    window.onUserClosed = { reportedUserClose = true }
    window.close()
    XCTAssertFalse(reportedUserClose)
    XCTAssertFalse(model.pictureInPicture)
    // With no media loaded the main window shows the library, not the player.
    XCTAssertFalse(model.showsPlayerInWindow)
  }
}

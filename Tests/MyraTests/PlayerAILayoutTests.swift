import AppKit
import SwiftUI
import XCTest

@testable import Myra

/// Display rules for the player overlay and AI panel. Pure values only: no playback or model calls.
final class PlayerAILayoutTests: XCTestCase {
  func testBufferingCardShowsOnlyForBufferingTorrentStreams() {
    XCTAssertTrue(
      PlayerBufferingPresentation.showsCard(isBuffering: true, isTorrentStream: true))
    XCTAssertFalse(
      PlayerBufferingPresentation.showsCard(isBuffering: true, isTorrentStream: false))
    XCTAssertFalse(
      PlayerBufferingPresentation.showsCard(isBuffering: false, isTorrentStream: true))
    XCTAssertFalse(
      PlayerBufferingPresentation.showsCard(isBuffering: false, isTorrentStream: false))
  }

  func testBufferingPercentClampsAndRoundsSafely() {
    XCTAssertEqual(PlayerBufferingPresentation.percentText(0), "0%")
    XCTAssertEqual(PlayerBufferingPresentation.percentText(41.6), "42%")
    XCTAssertEqual(PlayerBufferingPresentation.percentText(-5), "0%")
    XCTAssertEqual(PlayerBufferingPresentation.percentText(140), "100%")
    XCTAssertEqual(PlayerBufferingPresentation.percentText(.nan), "0%")
  }

  func testSpeedUsesMegabytesAboveOneMegabyteOtherwiseKilobytes() {
    XCTAssertEqual(PlayerBufferingPresentation.speedText(bytesPerSecond: 6_200_000), "6.2 MB/s")
    XCTAssertEqual(PlayerBufferingPresentation.speedText(bytesPerSecond: 512_000), "512 KB/s")
    XCTAssertEqual(PlayerBufferingPresentation.speedText(bytesPerSecond: -10), "0 KB/s")
  }

  func testStatusLineNamesStateAndPeersWithSingularAndPlural() {
    XCTAssertEqual(
      PlayerBufferingPresentation.statusLine(
        state: "Buffering · 3 s ahead", peers: 41, bytesPerSecond: 6_200_000),
      "Buffering · 3 s ahead · 41 peers · 6.2 MB/s")
    XCTAssertEqual(
      PlayerBufferingPresentation.statusLine(state: "Downloading", peers: 1, bytesPerSecond: 0),
      "Downloading · 1 peer · 0 KB/s")
  }

  func testScrubBufferedPartRunsAheadOfPlayheadAndClamps() {
    XCTAssertEqual(
      PlayerScrubLayout.bufferedFraction(position: 0.25, bufferedSeconds: 0, duration: 600),
      0.25, accuracy: 0.0001)
    XCTAssertEqual(
      PlayerScrubLayout.bufferedFraction(position: 0.25, bufferedSeconds: 60, duration: 600),
      0.35, accuracy: 0.0001)
    XCTAssertEqual(
      PlayerScrubLayout.bufferedFraction(position: 0.9, bufferedSeconds: 600, duration: 600),
      1)
    XCTAssertEqual(
      PlayerScrubLayout.bufferedFraction(position: 0.4, bufferedSeconds: 30, duration: 0),
      0.4, accuracy: 0.0001)
    XCTAssertEqual(
      PlayerScrubLayout.bufferedFraction(position: 1.7, bufferedSeconds: 30, duration: 600), 1)
  }

  func testTimingLabelFollowsRunPhases() {
    XCTAssertEqual(
      MyraAIGroundingLine.timingLabel(running: true, secondsToFirstWords: nil, totalSeconds: nil),
      "Thinking…")
    XCTAssertEqual(
      MyraAIGroundingLine.timingLabel(running: true, secondsToFirstWords: 0.62, totalSeconds: nil),
      "First words in 0.6 s")
    XCTAssertEqual(
      MyraAIGroundingLine.timingLabel(
        running: false, secondsToFirstWords: 0.62, totalSeconds: 2.04),
      "Done in 2.0 s")
    XCTAssertNil(
      MyraAIGroundingLine.timingLabel(running: false, secondsToFirstWords: nil, totalSeconds: nil))
  }

  func testGroundingFooterStatesOnDeviceAndCloudPrivacy() {
    let onDevice = MyraAIGroundingLine.footerItems(
      providerName: "Apple On-Device", pickCount: 3, timing: "Done in 1.2 s", provider: .apple)
    XCTAssertEqual(onDevice.first, "Apple On-Device")
    XCTAssertTrue(onDevice.contains("3 picks from your library"))
    XCTAssertTrue(onDevice.contains("Done in 1.2 s"))
    XCTAssertEqual(onDevice.last, "Nothing left this Mac")

    let cloud = MyraAIGroundingLine.footerItems(
      providerName: "Generated with OpenAI", pickCount: 1, timing: nil, provider: .openAI)
    XCTAssertTrue(cloud.contains("1 pick from your library"))
    XCTAssertFalse(cloud.contains("Nothing left this Mac"))
    XCTAssertEqual(cloud.last, "Sent to OpenAI under your AI settings")
  }

  func testRecommendationStatusShowsRuntimeKindEpisodeAndWatchState() {
    XCTAssertEqual(
      MyraAIGroundingLine.recommendationStatus(
        runtimeMinutes: 10, kind: "Movie", episodeLabel: nil, inWatchlist: false, watched: false),
      "10 min · Movie · unwatched")
    XCTAssertEqual(
      MyraAIGroundingLine.recommendationStatus(
        runtimeMinutes: nil, kind: "Series", episodeLabel: "S1 E03", inWatchlist: true,
        watched: true),
      "Series · S1 E03 · in watchlist")
    XCTAssertEqual(
      MyraAIGroundingLine.recommendationStatus(
        runtimeMinutes: 4, kind: "Movie", episodeLabel: nil, inWatchlist: false, watched: true),
      "4 min · Movie · watched")
  }

  func testStreamingCursorBlinksOncePerSecond() {
    let base = Date(timeIntervalSinceReferenceDate: 1_000)
    let first = MyraAIAnswerText.cursorVisible(at: base)
    XCTAssertEqual(MyraAIAnswerText.cursorVisible(at: base.addingTimeInterval(0.6)), !first)
    XCTAssertEqual(MyraAIAnswerText.cursorVisible(at: base.addingTimeInterval(1.1)), first)
  }

  /// Writes PNGs of the new chrome when MYRA_UI_SNAPSHOT_DIR is set; otherwise does nothing.
  @MainActor
  func testWritesPlayerAndAISnapshotsWhenRequested() throws {
    guard let directory = ProcessInfo.processInfo.environment["MYRA_UI_SNAPSHOT_DIR"] else {
      return
    }
    _ = NSApplication.shared
    let cases: [(String, NSAppearance.Name, AnyView)] = [
      (
        "player-buffering-dark", .darkAqua,
        AnyView(
          PlayerBufferingCard(
            status: PlayerStreamStatus(
              isTorrentStream: true, streamingRow: nil, streamPercent: 42)
          )
          .padding(30).background(Color.black))
      ),
      (
        "ai-footer-light", .aqua,
        AnyView(
          MyraAIGroundingFooter(items: [
            "Apple On-Device", "3 picks from your library", "Done in 2.0 s",
            "Nothing left this Mac",
          ])
          .frame(width: 520, alignment: .leading).padding(20))
      ),
      (
        "ai-answer-prompt-light", .aqua,
        AnyView(
          VStack(alignment: .leading, spacing: 14) {
            MyraAIPromptField(
              text: .constant("Something short and funny for tonight"), label: "Request")
            MyraAIAnswerText(text: "Three quick, light picks that all fit in under 30 minutes.",
              streaming: true)
          }
          .frame(width: 520, alignment: .leading).padding(20))
      ),
    ]
    for (name, appearance, view) in cases {
      let host = NSHostingView(rootView: view)
      host.appearance = NSAppearance(named: appearance)
      host.frame = NSRect(x: 0, y: 0, width: 560, height: 200)
      host.layoutSubtreeIfNeeded()
      let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: bitmap)
      let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
      try data.write(to: URL(fileURLWithPath: directory).appending(path: "\(name).png"))
    }
  }

  /// Host the new views in a real window and force layout, so a broken body fails here.
  @MainActor
  func testNewPlayerAndAIViewsLayOutInAHostingView() {
    _ = NSApplication.shared
    let views: [AnyView] = [
      AnyView(PlayerBufferingCard(status: PlayerStreamStatus(isTorrentStream: true))),
      AnyView(PlayerStatusPill(text: "Torrent stream")),
      AnyView(
        MyraAIGroundingFooter(items: [
          "Apple On-Device", "3 picks from your library", "Nothing left this Mac",
        ])
        .frame(width: 420)),
      AnyView(MyraAIAnswerText(text: "Three quick picks.", streaming: true).frame(width: 420)),
      AnyView(
        MyraAIPromptField(text: .constant("Something short"), label: "Request").frame(width: 420)),
    ]
    for view in views {
      let host = NSHostingView(rootView: view.frame(width: 480, height: 320))
      host.frame = NSRect(x: 0, y: 0, width: 480, height: 320)
      host.layoutSubtreeIfNeeded()
      XCTAssertGreaterThan(host.fittingSize.width, 0)
    }
  }
}

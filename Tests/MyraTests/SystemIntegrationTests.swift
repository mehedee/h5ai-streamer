import Foundation
import XCTest

@testable import Myra

/// Menu bar text, Dock badge, notification wording, Spotlight entries and the system switches' defaults.
@MainActor
final class SystemIntegrationTests: XCTestCase {
  private func snapshot(
    nowPlaying: String? = nil, isPlaying: Bool = false, indexing: IndexRefreshState = .notScanned,
    indexedVideos: Int = 0, activeDownloads: Int = 0, bytesPerSecond: Int64 = 0
  ) -> MenuBarSnapshot {
    MenuBarSnapshot(
      nowPlaying: nowPlaying, isPlaying: isPlaying, indexing: indexing,
      indexedVideos: indexedVideos, activeDownloads: activeDownloads,
      downloadBytesPerSecond: bytesPerSecond)
  }

  private func isolatedDefaults() -> UserDefaults {
    let suite = "MyraSystemTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
  }

  // MARK: Switch defaults

  func testSwitchDefaultsMatchTheApprovedPreview() {
    let defaults = isolatedDefaults()
    XCTAssertFalse(MyraSystemPreferences.automaticDownloadsEnabled(defaults))
    XCTAssertTrue(MyraSystemPreferences.menuBarEnabled(defaults))
    XCTAssertTrue(MyraSystemPreferences.spotlightEnabled(defaults))
    XCTAssertTrue(MyraSystemPreferences.dockBadgeEnabled(defaults))
    XCTAssertFalse(MyraSystemPreferences.notificationsEnabled(defaults))
    XCTAssertEqual(MyraSystemPreferences.offPeakWindow(defaults), .standard)
  }

  func testStoredSwitchesAreRead() {
    let defaults = isolatedDefaults()
    defaults.set(false, forKey: MyraSystemPreferences.menuBarKey)
    defaults.set(true, forKey: MyraSystemPreferences.notificationsKey)
    defaults.set(120, forKey: MyraSystemPreferences.windowStartKey)
    defaults.set(360, forKey: MyraSystemPreferences.windowEndKey)
    XCTAssertFalse(MyraSystemPreferences.menuBarEnabled(defaults))
    XCTAssertTrue(MyraSystemPreferences.notificationsEnabled(defaults))
    XCTAssertEqual(MyraSystemPreferences.offPeakWindow(defaults).startMinute, 120)
    XCTAssertEqual(MyraSystemPreferences.offPeakWindow(defaults).endMinute, 360)
  }

  func testInvalidStoredWindowFallsBackToTheStandardWindow() {
    let defaults = isolatedDefaults()
    defaults.set(300, forKey: MyraSystemPreferences.windowStartKey)
    defaults.set(300, forKey: MyraSystemPreferences.windowEndKey)
    XCTAssertEqual(MyraSystemPreferences.offPeakWindow(defaults), .standard)
  }

  // MARK: Menu bar

  func testStatusTitleShowsOnlyActiveDownloadCounts() {
    XCTAssertEqual(MenuBarText.statusTitle(snapshot()), "")
    XCTAssertEqual(MenuBarText.statusTitle(snapshot(activeDownloads: 2)), "2")
  }

  func testNowPlayingLineNamesThePlaybackState() {
    XCTAssertEqual(MenuBarText.nowPlaying(snapshot()), "Nothing playing")
    XCTAssertEqual(
      MenuBarText.nowPlaying(snapshot(nowPlaying: "Sintel", isPlaying: true)),
      "Playing · Sintel")
    XCTAssertEqual(
      MenuBarText.nowPlaying(snapshot(nowPlaying: "Sintel", isPlaying: false)),
      "Paused · Sintel")
  }

  func testIndexingLineFollowsTheRefreshState() {
    XCTAssertEqual(MenuBarText.indexing(snapshot(indexing: .completed)), "Library up to date")
    XCTAssertEqual(MenuBarText.indexing(snapshot(indexing: .paused)), "Indexing paused")
    XCTAssertTrue(
      MenuBarText.indexing(snapshot(indexing: .refreshing, indexedVideos: 1_234))
        .hasPrefix("Indexing · "))
  }

  func testIndexingToggleIsAvailableOnlyDuringARefresh() {
    XCTAssertTrue(MenuBarText.canToggleIndexing(snapshot(indexing: .refreshing)))
    XCTAssertTrue(MenuBarText.canToggleIndexing(snapshot(indexing: .paused)))
    XCTAssertFalse(MenuBarText.canToggleIndexing(snapshot(indexing: .completed)))
    XCTAssertEqual(MenuBarText.pauseIndexingTitle(snapshot(indexing: .paused)), "Resume Indexing")
    XCTAssertEqual(MenuBarText.pauseIndexingTitle(snapshot(indexing: .refreshing)), "Pause Indexing")
  }

  func testDownloadsLinePluralisesAndShowsSpeed() {
    XCTAssertEqual(MenuBarText.downloads(snapshot()), "No active downloads")
    XCTAssertTrue(MenuBarText.downloads(snapshot(activeDownloads: 1)).hasPrefix("1 download"))
    let busy = MenuBarText.downloads(snapshot(activeDownloads: 2, bytesPerSecond: 1_000_000))
    XCTAssertTrue(busy.hasPrefix("2 downloads · "))
    XCTAssertTrue(busy.hasSuffix("/s"))
  }

  // MARK: Dock badge

  func testDockBadgeIsEmptyWithoutActiveDownloads() {
    XCTAssertNil(DockBadge.label(activeDownloads: 0))
    XCTAssertEqual(DockBadge.label(activeDownloads: 3), "3")
  }

  // MARK: Notifications

  func testNoticeWordingCoversTheThreeApprovedEvents() {
    let finished = SystemNoticeFormatter.content(for: .downloadFinished(title: "Sintel"))
    XCTAssertEqual(finished.title, "Download finished")
    XCTAssertEqual(finished.body, "Sintel")

    let indexed = SystemNoticeFormatter.content(for: .indexingFinished)
    XCTAssertEqual(indexed.title, "Library updated")
    XCTAssertEqual(indexed.identifier, "Myra.indexing")

    let failure = SystemNoticeFormatter.content(for: .sourceFailures(summary: ""))
    XCTAssertEqual(failure.title, "Source problem")
    XCTAssertEqual(failure.body, "A source could not be scanned.")
  }

  // MARK: Spotlight

  func testSpotlightEntriesCarryTitlesAndKindOnly() {
    let titles = [
      EntertainmentTitle(
        id: "movie-1", name: "Sintel", year: "2010", kind: .movie, versions: []),
      EntertainmentTitle(
        id: "show-1", name: "Harbour Watch", year: nil, kind: .series, versions: []),
    ]
    let entries = SpotlightTitleIndex.entries(for: titles)
    XCTAssertEqual(entries.map(\.title), ["Sintel", "Harbour Watch"])
    XCTAssertEqual(entries[0].contentDescription, "Myra · Movie · 2010")
    XCTAssertEqual(entries[1].contentDescription, "Myra · TV Series")
    for entry in entries {
      XCTAssertFalse(entry.contentDescription.contains("/"), "No file paths are offered to Spotlight.")
    }
  }

  func testSpotlightIdentifiersRoundTripAndIgnoreOtherPrefixes() {
    let identifier = SpotlightTitleIndex.identifier(for: "movie-1")
    XCTAssertEqual(SpotlightTitleIndex.titleID(from: identifier), "movie-1")
    XCTAssertNil(SpotlightTitleIndex.titleID(from: "com.example.other.movie-1"))
  }

  // MARK: Routes

  func testRoutesRequestedBeforeTheCoordinatorAreDeliveredOnceItIsReady() {
    let router = MyraSystemRouter()
    router.post(.play(title: "Sintel"))
    var delivered: [MyraSystemRoute] = []
    router.handler = { delivered.append($0) }
    XCTAssertEqual(delivered, [.play(title: "Sintel")])
    router.post(.search(query: "harbour"))
    XCTAssertEqual(delivered.count, 2)
  }
}

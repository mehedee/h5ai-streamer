import Foundation
import XCTest

@testable import Myra

@MainActor
final class ShellChromeTests: XCTestCase {
  private func batch(
    _ title: String, _ status: TransferStatus, total: Int64, completed: Int64
  ) -> DownloadBatch {
    let batch = DownloadBatch(title: title, status: status)
    batch.totalBytes = total
    batch.completedBytes = completed
    return batch
  }

  func testOverviewCountsOnlyRunningBatchesInTheRing() {
    let batches = [
      batch("Sintel", .active, total: 1_000, completed: 250),
      batch("Cosmos", .paused, total: 1_000, completed: 250),
      batch("Finished", .completed, total: 1_000, completed: 1_000),
      batch("Failed", .failed, total: 1_000, completed: 0),
    ]

    let overview = DownloadOverview.make(batches: batches, torrents: [])

    XCTAssertTrue(overview.hasDownloads)
    XCTAssertEqual(overview.rows.map(\.title), ["Sintel", "Cosmos"])
    XCTAssertEqual(overview.rows.map(\.tag), ["HTTP", "HTTP"])
    XCTAssertEqual(overview.completedBytes, 500)
    XCTAssertEqual(overview.totalBytes, 2_000)
    XCTAssertEqual(overview.fraction, 0.25, accuracy: 0.0001)
    XCTAssertEqual(overview.rows.last?.details.last, "Paused")
  }

  func testRingFractionIsZeroWithoutDownloads() {
    let overview = DownloadOverview.make(
      batches: [batch("Done", .completed, total: 10, completed: 10)], torrents: [])

    XCTAssertFalse(overview.hasDownloads)
    XCTAssertEqual(overview.fraction, 0)
  }

  func testRingFractionIsClampedToOne() {
    let overview = DownloadOverview.make(
      batches: [batch("Overshoot", .active, total: 100, completed: 150)], torrents: [])

    XCTAssertEqual(overview.fraction, 1)
  }

  func testDownloadBadgeCountsActiveAndQueuedOnly() {
    let batches = [
      batch("A", .active, total: 1, completed: 0),
      batch("B", .queued, total: 1, completed: 0),
      batch("C", .paused, total: 1, completed: 0),
      batch("D", .completed, total: 1, completed: 1),
    ]

    XCTAssertEqual(ShellBadges.downloads(batches), 2)
    XCTAssertEqual(ShellBadges.downloads([]), 0)
  }

  func testFooterReportsUnknownScanTime() {
    XCTAssertEqual(ShellFooterText.scanned(nil), "Not yet scanned")
  }

  func testFooterReportsElapsedScanTime() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let fourMinutesAgo = now.addingTimeInterval(-240)

    let text = ShellFooterText.scanned(fourMinutesAgo, now: now)

    XCTAssertTrue(text.hasPrefix("Scanned "), text)
    XCTAssertNotEqual(text, "Not yet scanned")
  }

  func testHomeToolbarCommandsRoundTrip() {
    XCTAssertEqual(MyraCommand(identifier: "pickSomething"), .pickSomething)
    XCTAssertEqual(MyraCommand(identifier: "askMyra"), .askMyra)
    XCTAssertTrue(MyraCommand.allCommands.contains(.pickSomething))
    XCTAssertTrue(MyraCommand.allCommands.contains(.askMyra))
  }

  func testSidebarSectionsKeepTheirPreviewTitles() {
    XCTAssertEqual(
      AppSection.allCases.map(\.title),
      ["Home", "Watchlist", "Insights", "Sources", "Downloads", "Collections", "Needs Attention", "Transfers"])
    XCTAssertEqual(AppSection.watchlist.icon, "bookmark")
    XCTAssertEqual(AppSection.insights.icon, "chart.bar")
    XCTAssertEqual(AppSection.sources.icon, "server.rack")
  }
}

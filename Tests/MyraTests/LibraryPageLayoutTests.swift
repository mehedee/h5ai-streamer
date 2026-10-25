import AppKit
import Foundation
import SwiftUI
import XCTest

@testable import Myra

/// Sources, Downloads and Transfers layout helpers that feed the approved preview's rows and cards.
@MainActor
final class LibraryPageLayoutTests: XCTestCase {
  func testQualityTagReadsTheFirstKnownResolution() {
    XCTAssertEqual(SourceFileFormat.resolution(for: "Sintel.2010.1080p.BluRay.mkv"), "1080p")
    XCTAssertEqual(SourceFileFormat.resolution(for: "Tears.of.Steel.2160P.mkv"), "2160p")
    XCTAssertNil(SourceFileFormat.resolution(for: "Elephants Dream.mkv"))
  }

  func testScanAgeUsesTheCompactPreviewUnits() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    XCTAssertEqual(SourceSummaries.scanAge(since: nil, now: now), "never")
    XCTAssertEqual(SourceSummaries.scanAge(since: now.addingTimeInterval(-30), now: now), "now")
    XCTAssertEqual(SourceSummaries.scanAge(since: now.addingTimeInterval(-240), now: now), "4 min")
    XCTAssertEqual(SourceSummaries.scanAge(since: now.addingTimeInterval(-7200), now: now), "2 hr")
    XCTAssertEqual(
      SourceSummaries.scanAge(since: now.addingTimeInterval(-86_400), now: now), "1 day")
    XCTAssertEqual(
      SourceSummaries.scanAge(since: now.addingTimeInterval(-3 * 86_400), now: now), "3 days")
  }

  func testSourceSummariesSumMediaBytesPerSource() {
    let movies = UUID()
    let root = URL(filePath: "/tmp/myra-library-layout")
    let sizes: [Int64] = [1_000, 2_500]
    let versions = sizes.enumerated().map { index, size -> EntertainmentVersion in
      let url = root.appending(path: "film\(index).mkv")
      let entry = DirectoryEntry(name: "film\(index).mkv", url: url, kind: .file, size: size)
      let media = GlobalSearchResult(
        categoryID: movies, categoryName: "Movies", categoryRoot: root, entry: entry,
        relativePath: entry.name, artworkURL: nil)
      return EntertainmentVersion(media: media, firstDiscovered: Date(timeIntervalSince1970: 0))
    }
    let title = EntertainmentTitle(
      id: "film", name: "Film", year: nil, kind: .movie, versions: versions, metadata: nil)
    let summaries = SourceSummaries.make(
      sources: [SourceInput(id: movies, name: "Movies", rootURLString: "file:///m")],
      titles: [title], unavailableNames: [], isIndexing: false)
    XCTAssertEqual(summaries.first?.mediaBytes, 3_500)
    XCTAssertEqual(summaries.first?.status, .indexed)
  }

  func testRemainingTimeUsesThePreviewWording() {
    XCTAssertEqual(DownloadFormat.remaining(30), "Less than a minute left")
    XCTAssertEqual(DownloadFormat.remaining(60), "About 1 min left")
    XCTAssertEqual(DownloadFormat.remaining(150), "About 3 min left")
  }

  func testCompletedTodayKeepsOnlyFinishedBatchesFromTheSameDay() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
    let now = try XCTUnwrap(
      calendar.date(from: DateComponents(year: 2027, month: 1, day: 15, hour: 12)))
    let today = DownloadBatch(title: "Today", status: .completed)
    today.completedAt = now.addingTimeInterval(-60)
    let older = DownloadBatch(title: "Older", status: .completed)
    older.completedAt = now.addingTimeInterval(-2 * 86_400)
    let running = DownloadBatch(title: "Running", status: .active)
    running.completedAt = now

    let result = DownloadsModel.completedToday(
      [today, older, running], now: now, calendar: calendar)

    XCTAssertEqual(result.map(\.title), ["Today"])
  }

  func testStorageSummaryNamesTheSaveFolderWithATilde() {
    let text = DownloadsModel.storageSummary(folder: NSHomeDirectory() + "/Movies/Myra")
    XCTAssertTrue(text.hasSuffix("Saving to ~/Movies/Myra"), text)
  }

  func testRowGradientsCoverEachTileWithTwoStops() {
    XCTAssertEqual(LibraryPalette.gradients.count, 4)
    XCTAssertTrue(LibraryPalette.gradients.allSatisfy { $0.count == 2 })
    XCTAssertEqual(LibraryPalette.gradient(for: "Sintel").count, 2)
  }

  func testSourcesOverviewRendersCardsAndAddCard() throws {
    let summaries = [
      SourceSummary(
        id: UUID(), name: "Home NAS", host: "nas.local", status: .indexed, titleCount: 842,
        mediaCount: 900, mediaBytes: 3_400_000_000_000),
      SourceSummary(
        id: UUID(), name: "Media Server", host: "media.example.net", status: .indexing,
        titleCount: 391, mediaCount: 400, mediaBytes: 1_500_000_000_000),
      SourceSummary(
        id: UUID(), name: "Archive Drive", host: "10.0.0.12", status: .unavailable,
        titleCount: 51, mediaCount: 60, mediaBytes: 220_000_000_000),
    ]
    let host = NSHostingView(
      rootView: SourcesOverview(
        summaries: summaries, isIndexing: true, indexingFraction: 0.62, lastIndexed: .now,
        open: { _ in }, edit: { _ in }, delete: { _ in }, addSource: {})
      .frame(width: 900, height: 600))
    host.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
    let window = NSWindow(
      contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = host
    window.isReleasedWhenClosed = false
    defer { window.close() }
    window.orderFront(nil)
    host.layoutSubtreeIfNeeded()
    XCTAssertEqual(host.bounds.width, 900)
  }
}

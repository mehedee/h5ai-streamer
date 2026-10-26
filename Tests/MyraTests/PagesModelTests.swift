import Foundation
import XCTest

@testable import Myra

/// Page-level models: Downloads segments and row actions, Settings tabs and validation,
/// Sources summaries and layout, and the menu commands the pages handle.
@MainActor
final class PagesModelTests: XCTestCase {
  // MARK: Downloads

  func testDownloadsSegmentsDefaultToInProgress() {
    XCTAssertEqual(DownloadsSegment.allCases.map(\.title), ["In Progress", "Library"])
    XCTAssertEqual(DownloadsSegment.defaultSegment, .inProgress)
  }

  func testInProgressExcludesCompletedBatches() {
    let active = DownloadBatch(title: "A", status: .active)
    let paused = DownloadBatch(title: "B", status: .paused)
    let done = DownloadBatch(title: "C", status: .completed)
    let failed = DownloadBatch(title: "D", status: .failed)
    XCTAssertEqual(
      DownloadsModel.inProgress([active, paused, done, failed]).map(\.title), ["A", "B", "D"])
  }

  func testRowActionsFollowStatus() {
    XCTAssertEqual(DownloadsModel.actions(for: .active), [.pause, .cancel, .delete])
    XCTAssertEqual(DownloadsModel.actions(for: .queued), [.pause, .cancel, .delete])
    XCTAssertEqual(DownloadsModel.actions(for: .paused), [.resume, .removeFiles, .delete])
    XCTAssertEqual(DownloadsModel.actions(for: .failed), [.retry, .removeFiles, .delete])
    XCTAssertEqual(DownloadsModel.actions(for: .completed), [.reveal, .delete])
    XCTAssertEqual(DownloadsModel.actions(for: .preparing), [])
  }

  func testRetryIsOfferedForFailedButNotForActive() {
    XCTAssertTrue(DownloadsModel.actions(for: .failed).contains(.retry))
    XCTAssertFalse(DownloadsModel.actions(for: .active).contains(.retry))
  }

  func testDestructiveActionsAreMarked() {
    XCTAssertTrue(DownloadRowAction.cancel.isDestructive)
    XCTAssertTrue(DownloadRowAction.removeFiles.isDestructive)
    XCTAssertTrue(DownloadRowAction.delete.isDestructive)
    XCTAssertFalse(DownloadRowAction.pause.isDestructive)
    XCTAssertFalse(DownloadRowAction.reveal.isDestructive)
  }

  func testSummaryCountsAria2AndTorrentRows() {
    XCTAssertEqual(DownloadsModel.summary([], torrentRows: []), "Nothing is downloading")
    let batches = [DownloadBatch(title: "A", status: .active), DownloadBatch(title: "B", status: .paused)]
    let job = TorrentJob(
      identity: try! TorrentIdentity(magnet: "magnet:?xt=urn:btih:" + String(repeating: "a", count: 40)),
      name: "T", source: .magnet("magnet:?xt=urn:btih:" + String(repeating: "a", count: 40)), files: [])
    let torrent = TorrentTransferRow(job: job, transfer: TorrentTransfer(), isStreaming: false)
    XCTAssertEqual(
      DownloadsModel.summary(batches, torrentRows: [torrent]),
      "3 in progress • 1 active • 1 paused")
  }

  func testDownloadFormatMatchesDrawerStyle() {
    XCTAssertEqual(DownloadFormat.duration(65), "1:05")
    XCTAssertEqual(DownloadFormat.duration(3_725), "1:02:05")
    XCTAssertEqual(DownloadFormat.duration(-4), "0:00")
  }

  // MARK: Settings

  func testSettingsTabsKeepTheApprovedOrder() {
    XCTAssertEqual(
      MyraSettingsTab.allCases.map(\.title),
      ["General", "Library", "Downloads", "Playback", "AI", "Torrents"])
    XCTAssertEqual(MyraSettingsTab.defaultTab, .general)
    XCTAssertEqual(Set(MyraSettingsTab.allCases.map(\.symbol)).count, 6)
  }

  func testSpeedLimitAcceptsAria2Forms() {
    for value in ["0", "500K", "10M", "250k", "1m", "1024"] {
      XCTAssertTrue(MyraSettingsValidation.isValidSpeedLimit(value), value)
      XCTAssertNil(MyraSettingsValidation.speedLimitMessage(value), value)
    }
  }

  func testSpeedLimitRejectsOtherForms() {
    for value in ["", "abc", "10G", "-1", "1.5M", "00", " 5M", "5 M"] {
      XCTAssertFalse(MyraSettingsValidation.isValidSpeedLimit(value), value)
      XCTAssertNotNil(MyraSettingsValidation.speedLimitMessage(value), value)
    }
  }

  func testTokenValidationRejectsWhitespaceInside() {
    XCTAssertNil(MyraSettingsValidation.tokenMessage(""))
    XCTAssertNil(MyraSettingsValidation.tokenMessage("  abc123  "))
    XCTAssertNotNil(MyraSettingsValidation.tokenMessage("abc 123"))
    XCTAssertNotNil(MyraSettingsValidation.tokenMessage("abc\n123"))
  }

  // MARK: Sources

  func testHostNamesForSourceCards() {
    XCTAssertEqual(SourceSummaries.host(for: "file:///Users/me/Movies"), "This Mac")
    XCTAssertEqual(SourceSummaries.host(for: "smb://nas.local/media"), "nas.local")
    XCTAssertEqual(SourceSummaries.host(for: "not a url at all"), "Unknown location")
  }

  func testSourceSummaryCountsTitlesAndVideosPerSource() {
    let movies = UUID()
    let shows = UUID()
    let titles = [
      title("Film", versions: [(movies, "a.mkv")]),
      title("Show", kind: .series, versions: [(shows, "s1.mkv"), (shows, "s2.mkv")]),
      title("Shared", versions: [(movies, "b.mkv"), (shows, "c.mkv")]),
    ]
    let summaries = SourceSummaries.make(
      sources: [
        SourceInput(id: movies, name: "Movies", rootURLString: "file:///m"),
        SourceInput(id: shows, name: "Shows", rootURLString: "smb://nas/shows"),
      ],
      titles: titles, unavailableNames: [], isIndexing: false)

    XCTAssertEqual(summaries.map(\.titleCount), [2, 2])
    XCTAssertEqual(summaries.map(\.mediaCount), [2, 3])
    XCTAssertEqual(summaries.map(\.status), [.indexed, .indexed])
    XCTAssertEqual(summaries.map(\.host), ["This Mac", "nas"])
  }

  func testSourceStatusPrecedenceUnavailableThenIndexingThenIndexed() {
    let id = UUID()
    let sources = [SourceInput(id: id, name: "Disk", rootURLString: "file:///d")]
    let titles = [title("Film", versions: [(id, "f.mkv")])]

    XCTAssertEqual(
      SourceSummaries.make(
        sources: sources, titles: titles, unavailableNames: ["Disk"], isIndexing: true
      ).first?.status, .unavailable)
    XCTAssertEqual(
      SourceSummaries.make(
        sources: sources, titles: titles, unavailableNames: [], isIndexing: true
      ).first?.status, .indexing)
    XCTAssertEqual(
      SourceSummaries.make(
        sources: sources, titles: [], unavailableNames: [], isIndexing: false
      ).first?.status, .notIndexed)
  }

  func testBrowserLayoutDefaultsFollowContent() {
    // The preview's file table is the default; a saved choice wins.
    XCTAssertEqual(SourceBrowserLayout.resolve(stored: ""), .list)
    XCTAssertEqual(SourceBrowserLayout.resolve(stored: "list"), .list)
    XCTAssertEqual(SourceBrowserLayout.resolve(stored: "grid"), .grid)
    XCTAssertEqual(SourceBrowserLayout.resolve(stored: "unknown"), .list)
  }

  // MARK: Menu commands handled by pages

  func testPageCommandsRoundTripThroughIdentifiers() {
    XCTAssertEqual(MyraCommand(identifier: "find"), .find)
    XCTAssertEqual(MyraCommand(identifier: "addSource"), .addSource)
    XCTAssertEqual(MyraCommand(identifier: "refreshLibrary"), .refreshLibrary)
    XCTAssertEqual(MyraCommand(identifier: "pauseAllDownloads"), .pauseAllDownloads)
    XCTAssertEqual(MyraCommand(identifier: "resumeAllDownloads"), .resumeAllDownloads)
    XCTAssertEqual(MyraCommand(identifier: "clearCompletedDownloads"), .clearCompletedDownloads)
  }

  func testPagesReceiveFindAndAddSourceFromTheMenuNotification() {
    let center = NotificationCenter()
    var received: [MyraCommand] = []
    let token = center.addObserver(forName: MyraCommand.notification, object: nil, queue: nil) {
      note in
      if let command = MyraCommand(notification: note) { received.append(command) }
    }
    defer { center.removeObserver(token) }

    MyraCommand.find.post(center: center)
    MyraCommand.addSource.post(center: center)

    XCTAssertEqual(received, [.find, .addSource])
  }

  func testUnknownCommandIdentifiersAreIgnored() {
    let note = Notification(
      name: MyraCommand.notification, object: nil, userInfo: [MyraCommand.identifierKey: "nope"])
    XCTAssertNil(MyraCommand(notification: note))
  }

  // MARK: Helpers

  private func title(
    _ name: String, kind: EntertainmentKind = .movie, versions: [(UUID, String)]
  ) -> EntertainmentTitle {
    let root = URL(filePath: "/tmp/myra-pages")
    let items = versions.map { sourceID, file -> EntertainmentVersion in
      let url = root.appending(path: file)
      let entry = DirectoryEntry(name: file, url: url, kind: .file)
      let media = GlobalSearchResult(
        categoryID: sourceID, categoryName: "Source", categoryRoot: root, entry: entry,
        relativePath: file, artworkURL: nil)
      return EntertainmentVersion(media: media, firstDiscovered: Date(timeIntervalSince1970: 0))
    }
    return EntertainmentTitle(
      id: "\(kind.rawValue)|\(name)", name: name, year: nil, kind: kind, versions: items,
      metadata: nil)
  }
}

import Foundation
import XCTest

@testable import Myra

/// Scheduling rules for automatic downloads, checked with fixed dates and an injected clock.
/// Nothing here starts a real transfer: the queue's download closure is a test double.
@MainActor
final class AutomaticDownloadTests: XCTestCase {
  private var calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }()

  private func date(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
    DateComponents(
      calendar: calendar, timeZone: calendar.timeZone, year: 2026, month: 10, day: day,
      hour: hour, minute: minute
    ).date!
  }

  private func item(
    _ name: String, status: AutomaticDownloadStatus = .pending, foundDay: Int = 1,
    batchID: UUID? = nil
  ) -> AutomaticDownloadItem {
    var value = AutomaticDownloadItem(
      seriesTitle: "Harbour Watch",
      sourceURL: URL(string: "https://media.example.test/harbour/\(name).mkv")!,
      relativePath: "TV/Harbour Watch/\(name).mkv", size: 1_200,
      foundAt: date(foundDay, 9, 0))
    value.status = status
    value.batchID = batchID
    return value
  }

  // MARK: Window

  func testStandardWindowOpensAtOneAndClosesAtSeven() {
    let window = OffPeakWindow.standard
    XCTAssertFalse(window.contains(date(5, 0, 59), calendar: calendar))
    XCTAssertTrue(window.contains(date(5, 1, 0), calendar: calendar))
    XCTAssertTrue(window.contains(date(5, 6, 59), calendar: calendar))
    XCTAssertFalse(window.contains(date(5, 7, 0), calendar: calendar))
    XCTAssertEqual(OffPeakWindow.clockText(window.startMinute), "01:00")
    XCTAssertEqual(OffPeakWindow.clockText(window.endMinute), "07:00")
  }

  func testWindowThatWrapsPastMidnightIsOpenAcrossIt() {
    let window = OffPeakWindow(startMinute: 22 * 60, endMinute: 2 * 60)
    XCTAssertTrue(window.contains(date(5, 23, 0), calendar: calendar))
    XCTAssertTrue(window.contains(date(5, 1, 30), calendar: calendar))
    XCTAssertFalse(window.contains(date(5, 2, 0), calendar: calendar))
    XCTAssertFalse(window.contains(date(5, 12, 0), calendar: calendar))
  }

  func testNextOpeningIsTodayBeforeTheWindowAndTomorrowAfterIt() {
    let window = OffPeakWindow.standard
    XCTAssertEqual(
      window.nextOpening(after: date(5, 0, 30), calendar: calendar), date(5, 1, 0))
    XCTAssertEqual(
      window.nextOpening(after: date(5, 9, 0), calendar: calendar), date(6, 1, 0))
    let inside = date(5, 3, 15)
    XCTAssertEqual(window.nextOpening(after: inside, calendar: calendar), inside)
  }

  func testInvalidWindowIsRejected() {
    XCTAssertFalse(OffPeakWindow(startMinute: 60, endMinute: 60).isValid)
    XCTAssertFalse(OffPeakWindow(startMinute: -1, endMinute: 60).isValid)
    XCTAssertTrue(OffPeakWindow.standard.isValid)
  }

  // MARK: Decisions

  func testNothingStartsWhileDisabledOrOutsideTheWindow() {
    let items = [item("E1"), item("E2", foundDay: 2)]
    XCTAssertEqual(
      AutomaticDownloadPolicy.dueIDs(
        items: items, enabled: false, window: .standard, now: date(5, 2, 0), calendar: calendar),
      [])
    XCTAssertEqual(
      AutomaticDownloadPolicy.dueIDs(
        items: items, enabled: true, window: .standard, now: date(5, 12, 0), calendar: calendar),
      [])
  }

  func testDueItemsAreOldestFirstAndExcludeNonPendingOnes() {
    let older = item("Old", foundDay: 1)
    let newer = item("New", foundDay: 3)
    let skipped = item("Skipped", status: .skipped, foundDay: 2)
    let running = item("Running", status: .running, foundDay: 2)
    let ids = AutomaticDownloadPolicy.dueIDs(
      items: [newer, skipped, older, running], enabled: true, window: .standard,
      now: date(5, 2, 0), calendar: calendar)
    XCTAssertEqual(ids, [older.id, newer.id])
  }

  func testEachSourceIsQueuedAtMostOnce() {
    let candidate = AutomaticDownloadCandidate(
      seriesTitle: "Harbour Watch",
      sourceURL: URL(string: "https://media.example.test/harbour/E1.mkv")!,
      relativePath: "TV/Harbour Watch/E1.mkv", size: 10, foundAt: date(1, 9, 0))
    let first = AutomaticDownloadPolicy.merging([candidate, candidate], into: [])
    XCTAssertEqual(first.count, 1)

    var skipped = first[0]
    skipped.status = .skipped
    let again = AutomaticDownloadPolicy.merging([candidate], into: [skipped])
    XCTAssertEqual(again.count, 1, "A skipped episode must not come back on the next discovery.")
    XCTAssertEqual(again[0].status, .skipped)
  }

  func testRunningItemsFollowTheirBatchToFinishedOrFailed() {
    let done = UUID()
    let broken = UUID()
    let busy = UUID()
    let items = [
      item("A", status: .running, batchID: done),
      item("B", status: .running, batchID: broken),
      item("C", status: .running, batchID: busy),
    ]
    let updated = AutomaticDownloadPolicy.reconciled(
      items, batchStatuses: [done: .completed, broken: .failed, busy: .active])
    XCTAssertEqual(updated[0].status, .finished)
    XCTAssertEqual(updated[1].status, .failed)
    XCTAssertNotNil(updated[1].message)
    XCTAssertEqual(updated[2].status, .running)
  }

  func testPruningKeepsOpenItemsAndTheNewestHistory() {
    var history: [AutomaticDownloadItem] = []
    for day in 0..<60 {
      history.append(item("H\(day)", status: .finished, foundDay: 1))
      history[day].foundAt = date(1, 0, 0).addingTimeInterval(Double(day) * 60)
    }
    let open = [item("P1", status: .pending), item("R1", status: .running)]
    let pruned = AutomaticDownloadPolicy.pruned(open + history, historyLimit: 50)
    XCTAssertEqual(pruned.filter { $0.status == .pending || $0.status == .running }.count, 2)
    XCTAssertEqual(pruned.count, 52)
    let newest = history.sorted { $0.foundAt > $1.foundAt }.prefix(50).map(\.id)
    XCTAssertTrue(newest.allSatisfy { id in pruned.contains { $0.id == id } })
  }

  func testEpisodeNameComesFromTheRelativePath() {
    XCTAssertEqual(item("E6").episodeName, "E6.mkv")
    XCTAssertEqual(item("E6").manifestItem?.relativePath, "TV/Harbour Watch/E6.mkv")
  }

  // MARK: Queue

  private func makeQueue(storageURL: URL? = nil) -> AutomaticDownloadQueue {
    let queue = AutomaticDownloadQueue(storageURL: storageURL)
    queue.calendar = calendar
    return queue
  }

  func testTickStartsOnlyInsideTheWindowAndRecordsTheBatch() async {
    let queue = makeQueue()
    let batch = UUID()
    var started: [String] = []
    queue.startDownload = { item in
      started.append(item.episodeName)
      return batch
    }
    queue.enqueue(
      [
        AutomaticDownloadCandidate(
          seriesTitle: "Harbour Watch",
          sourceURL: URL(string: "https://media.example.test/harbour/E6.mkv")!,
          relativePath: "TV/Harbour Watch/E6.mkv", size: 1, foundAt: date(4, 22, 0))
      ], enabled: true)
    XCTAssertEqual(queue.pendingCount, 1)

    queue.now = { self.date(5, 12, 0) }
    await queue.tick(enabled: true, window: .standard)
    XCTAssertEqual(started, [])

    queue.now = { self.date(5, 1, 30) }
    await queue.tick(enabled: true, window: .standard)
    XCTAssertEqual(started, ["E6.mkv"])
    XCTAssertEqual(queue.items.first?.status, .running)
    XCTAssertEqual(queue.items.first?.batchID, batch)

    await queue.tick(enabled: true, window: .standard)
    XCTAssertEqual(started.count, 1, "A running item must not be started twice.")
  }

  func testRunNowIgnoresTheWindowAndSkipPreventsStart() async {
    let queue = makeQueue()
    var started = 0
    queue.startDownload = { _ in
      started += 1
      return UUID()
    }
    queue.now = { self.date(5, 12, 0) }
    queue.enqueue(
      [
        AutomaticDownloadCandidate(
          seriesTitle: "Harbour Watch",
          sourceURL: URL(string: "https://media.example.test/harbour/E1.mkv")!,
          relativePath: "TV/Harbour Watch/E1.mkv", size: nil, foundAt: date(4, 9, 0)),
        AutomaticDownloadCandidate(
          seriesTitle: "Harbour Watch",
          sourceURL: URL(string: "https://media.example.test/harbour/E2.mkv")!,
          relativePath: "TV/Harbour Watch/E2.mkv", size: nil, foundAt: date(4, 9, 1)),
      ], enabled: true)
    let first = queue.items[0].id
    let second = queue.items[1].id

    queue.skip(second)
    await queue.runNow(first)
    await queue.runNow(second)
    XCTAssertEqual(started, 1)
    XCTAssertEqual(queue.items[1].status, .skipped)
    XCTAssertEqual(queue.items[0].status, .running)
  }

  func testFailedStartIsRecordedWithItsMessage() async {
    struct Failure: LocalizedError {
      var errorDescription: String? { "aria2 is not installed" }
    }
    let queue = makeQueue()
    queue.startDownload = { _ in throw Failure() }
    queue.enqueue(
      [
        AutomaticDownloadCandidate(
          seriesTitle: "Harbour Watch",
          sourceURL: URL(string: "https://media.example.test/harbour/E3.mkv")!,
          relativePath: "TV/Harbour Watch/E3.mkv", size: nil, foundAt: date(4, 9, 0))
      ], enabled: true)
    await queue.runNow(queue.items[0].id)
    XCTAssertEqual(queue.items[0].status, .failed)
    XCTAssertEqual(queue.items[0].message, "aria2 is not installed")
  }

  func testEpisodesFoundWhileDisabledAreNotQueued() {
    let queue = makeQueue()
    queue.enqueue(
      [
        AutomaticDownloadCandidate(
          seriesTitle: "Harbour Watch",
          sourceURL: URL(string: "https://media.example.test/harbour/E4.mkv")!,
          relativePath: "TV/Harbour Watch/E4.mkv", size: nil, foundAt: date(4, 9, 0))
      ], enabled: false)
    XCTAssertTrue(queue.items.isEmpty)
  }

  func testQueueSurvivesARestart() throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "MyraAutomaticTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = directory.appending(path: "AutomaticDownloads.json")
    let queue = makeQueue(storageURL: storage)
    queue.enqueue(
      [
        AutomaticDownloadCandidate(
          seriesTitle: "Harbour Watch",
          sourceURL: URL(string: "https://media.example.test/harbour/E5.mkv")!,
          relativePath: "TV/Harbour Watch/E5.mkv", size: 42, foundAt: date(4, 9, 0))
      ], enabled: true)
    queue.skip(queue.items[0].id)

    let reloaded = makeQueue(storageURL: storage)
    XCTAssertEqual(reloaded.items.count, 1)
    XCTAssertEqual(reloaded.items[0].status, .skipped)
    XCTAssertEqual(reloaded.items[0].size, 42)
  }
}

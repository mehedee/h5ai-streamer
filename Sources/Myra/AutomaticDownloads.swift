import Foundation

/// A daily window in local time when automatic downloads may start. Bounds are minutes after
/// midnight. A window whose end is before its start wraps past midnight.
struct OffPeakWindow: Codable, Equatable, Sendable {
  var startMinute: Int
  var endMinute: Int

  /// The approved default: 01:00 to 07:00.
  static let standard = OffPeakWindow(startMinute: 60, endMinute: 420)

  var isValid: Bool {
    (0..<1_440).contains(startMinute) && (0..<1_440).contains(endMinute)
      && startMinute != endMinute
  }

  /// True when `date` falls inside the window in `calendar`'s time zone.
  func contains(_ date: Date, calendar: Calendar) -> Bool {
    let minute = Self.minuteOfDay(date, calendar: calendar)
    if startMinute < endMinute {
      return minute >= startMinute && minute < endMinute
    }
    return minute >= startMinute || minute < endMinute
  }

  /// The moment the window next opens: `date` itself while the window is open, otherwise the
  /// next occurrence of the start time after `date`.
  func nextOpening(after date: Date, calendar: Calendar) -> Date? {
    if contains(date, calendar: calendar) { return date }
    let components = DateComponents(hour: startMinute / 60, minute: startMinute % 60)
    return calendar.nextDate(after: date, matching: components, matchingPolicy: .nextTime)
  }

  static func minuteOfDay(_ date: Date, calendar: Calendar) -> Int {
    let parts = calendar.dateComponents([.hour, .minute], from: date)
    return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
  }

  /// "01:00" style text for a minute-of-day value.
  static func clockText(_ minute: Int) -> String {
    String(format: "%02d:%02d", minute / 60, minute % 60)
  }
}

enum AutomaticDownloadStatus: String, Codable, Sendable, CaseIterable {
  /// Waiting for the off-peak window, or for "Run now".
  case pending
  /// Handed to the shared download queue; its batch is tracked by `batchID`.
  case running
  case finished
  case failed
  case skipped
}

/// One new episode found for a followed series. The stored strings keep the record Codable
/// without depending on `URL` encoding rules.
struct AutomaticDownloadItem: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  var seriesTitle: String
  var sourceURLString: String
  var relativePath: String
  var size: Int64?
  var foundAt: Date
  var status: AutomaticDownloadStatus
  var batchID: UUID?
  var message: String?

  init(
    id: UUID = UUID(), seriesTitle: String, sourceURL: URL, relativePath: String, size: Int64?,
    foundAt: Date, status: AutomaticDownloadStatus = .pending
  ) {
    self.id = id
    self.seriesTitle = seriesTitle
    self.sourceURLString = sourceURL.absoluteString
    self.relativePath = relativePath
    self.size = size
    self.foundAt = foundAt
    self.status = status
  }

  var sourceURL: URL? { URL(string: sourceURLString) }

  /// The last path component, shown as the episode name.
  var episodeName: String {
    URL(fileURLWithPath: relativePath).lastPathComponent
  }

  var manifestItem: DownloadManifestItem? {
    sourceURL.map {
      DownloadManifestItem(sourceURL: $0, relativePath: relativePath, size: size)
    }
  }

  var isActionable: Bool { status == .pending }
}

/// A new episode reported by episode discovery, before it is queued.
struct AutomaticDownloadCandidate: Equatable, Sendable {
  let seriesTitle: String
  let sourceURL: URL
  let relativePath: String
  let size: Int64?
  let foundAt: Date
}

extension AutomaticDownloadCandidate {
  /// Builds a candidate with the same source URL and safe relative path that a manual download would use.
  static func make(seriesTitle: String, media: GlobalSearchResult, foundAt: Date)
    -> AutomaticDownloadCandidate?
  {
    guard let item = GlobalDownloadManifestBuilder.groups(for: [media]).first?.manifest.first
    else { return nil }
    return AutomaticDownloadCandidate(
      seriesTitle: seriesTitle, sourceURL: item.sourceURL, relativePath: item.relativePath,
      size: item.size, foundAt: foundAt)
  }
}

/// Pure decisions for the automatic download queue. No clock, storage or downloader is touched here.
enum AutomaticDownloadPolicy {
  /// Adds candidates that are not already queued. A source URL is queued at most once, even
  /// after it was skipped or finished, so an episode is never downloaded twice by accident.
  static func merging(
    _ candidates: [AutomaticDownloadCandidate], into items: [AutomaticDownloadItem]
  ) -> [AutomaticDownloadItem] {
    var known = Set(items.map(\.sourceURLString))
    var result = items
    for candidate in candidates {
      let key = candidate.sourceURL.absoluteString
      guard known.insert(key).inserted else { continue }
      result.append(
        AutomaticDownloadItem(
          seriesTitle: candidate.seriesTitle, sourceURL: candidate.sourceURL,
          relativePath: candidate.relativePath, size: candidate.size, foundAt: candidate.foundAt))
    }
    return result
  }

  /// Pending items that may start now. Nothing starts while automatic downloads are off, or
  /// outside the window. The oldest find starts first.
  static func dueIDs(
    items: [AutomaticDownloadItem], enabled: Bool, window: OffPeakWindow, now: Date,
    calendar: Calendar
  ) -> [UUID] {
    guard enabled, window.isValid, window.contains(now, calendar: calendar) else { return [] }
    return
      items
      .filter(\.isActionable)
      .sorted { $0.foundAt < $1.foundAt }
      .map(\.id)
  }

  /// Moves running items to finished or failed once their batch reports a final state.
  static func reconciled(
    _ items: [AutomaticDownloadItem], batchStatuses: [UUID: TransferStatus]
  ) -> [AutomaticDownloadItem] {
    items.map { item in
      guard item.status == .running, let batchID = item.batchID,
        let status = batchStatuses[batchID]
      else { return item }
      var updated = item
      switch status {
      case .completed:
        updated.status = .finished
        updated.message = nil
      case .failed, .cancelled:
        updated.status = .failed
        updated.message = "The download did not finish. Retry it from Downloads."
      case .queued, .active, .paused, .preparing:
        break
      }
      return updated
    }
  }

  /// Keeps every pending or running item and the newest `historyLimit` finished, failed or skipped ones.
  static func pruned(_ items: [AutomaticDownloadItem], historyLimit: Int = 50)
    -> [AutomaticDownloadItem]
  {
    let open = items.filter { $0.status == .pending || $0.status == .running }
    let history = items
      .filter { $0.status != .pending && $0.status != .running }
      .sorted { $0.foundAt > $1.foundAt }
      .prefix(max(0, historyLimit))
    let keep = Set(open.map(\.id) + history.map(\.id))
    return items.filter { keep.contains($0.id) }
  }
}

/// The queue of automatic downloads: persisted as JSON in the active profile folder, started
/// only while Myra is open, and shared with the Downloads page through `items`.
@MainActor
final class AutomaticDownloadQueue: ObservableObject {
  @Published private(set) var items: [AutomaticDownloadItem] = []

  /// Hands one item to the shared download path and returns the batch it created.
  var startDownload: (@MainActor (AutomaticDownloadItem) async throws -> UUID)?
  var now: () -> Date = { .now }
  var calendar: Calendar = .current

  private let storageURL: URL?
  private var timer: Timer?
  private var starting = Set<UUID>()

  /// How often an open Myra checks whether the off-peak window has opened.
  static let checkInterval: TimeInterval = 60

  init(storageURL: URL?) {
    self.storageURL = storageURL
    load()
  }

  var pendingCount: Int { items.filter(\.isActionable).count }

  /// Queues newly found episodes. Ignored while automatic downloads are off, so turning them on
  /// later does not queue episodes that were found in the meantime.
  func enqueue(_ candidates: [AutomaticDownloadCandidate], enabled: Bool) {
    guard enabled, !candidates.isEmpty else { return }
    let merged = AutomaticDownloadPolicy.merging(candidates, into: items)
    guard merged != items else { return }
    commit(merged)
  }

  /// Starts an item now, outside the window. Used by the "Run now" button.
  func runNow(_ id: UUID) async {
    guard let item = items.first(where: { $0.id == id }), item.isActionable else { return }
    await start(id)
  }

  func skip(_ id: UUID) {
    guard let index = items.firstIndex(where: { $0.id == id }), items[index].isActionable else {
      return
    }
    var updated = items
    updated[index].status = .skipped
    commit(updated)
  }

  /// Starts every due item. Called on each timer tick, and once when the queue starts.
  func tick(enabled: Bool, window: OffPeakWindow) async {
    let due = AutomaticDownloadPolicy.dueIDs(
      items: items, enabled: enabled, window: window, now: now(), calendar: calendar)
    for id in due { await start(id) }
  }

  /// Brings running items up to date with the shared download batches.
  func reconcile(batches: [DownloadBatch]) {
    let statuses = Dictionary(uniqueKeysWithValues: batches.map { ($0.id, $0.status) })
    let updated = AutomaticDownloadPolicy.reconciled(items, batchStatuses: statuses)
    if updated != items { commit(updated) }
  }

  /// Starts the periodic check. The check runs only while this process is alive: there is no launch agent.
  func startTimer(
    enabled: @escaping @MainActor () -> Bool, window: @escaping @MainActor () -> OffPeakWindow
  ) {
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) {
      [weak self] _ in
      Task { @MainActor in
        await self?.tick(enabled: enabled(), window: window())
      }
    }
  }

  func stopTimer() {
    timer?.invalidate()
    timer = nil
  }

  private func start(_ id: UUID) async {
    guard !starting.contains(id), let startDownload,
      let index = items.firstIndex(where: { $0.id == id }), items[index].isActionable,
      items[index].manifestItem != nil
    else { return }
    starting.insert(id)
    defer { starting.remove(id) }
    do {
      let batchID = try await startDownload(items[index])
      guard let current = items.firstIndex(where: { $0.id == id }) else { return }
      var updated = items
      updated[current].status = .running
      updated[current].batchID = batchID
      updated[current].message = nil
      commit(updated)
    } catch {
      guard let current = items.firstIndex(where: { $0.id == id }) else { return }
      var updated = items
      updated[current].status = .failed
      updated[current].message = error.localizedDescription
      commit(updated)
    }
  }

  private func commit(_ updated: [AutomaticDownloadItem]) {
    items = AutomaticDownloadPolicy.pruned(updated)
    save()
  }

  private func load() {
    guard let storageURL, let data = try? Data(contentsOf: storageURL),
      let decoded = try? JSONDecoder().decode([AutomaticDownloadItem].self, from: data)
    else { return }
    items = decoded
  }

  private func save() {
    guard let storageURL,
      let data = try? JSONEncoder().encode(items)
    else { return }
    try? FileManager.default.createDirectory(
      at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? data.write(to: storageURL, options: .atomic)
  }
}

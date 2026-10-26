import SwiftUI

/// Byte, time and storage text for download rows. Matches the formatting used by the download drawer.
enum DownloadFormat {
  static func bytes(_ value: Int64) -> String {
    Foundation.ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
  }

  static func duration(_ seconds: TimeInterval) -> String {
    let value = max(0, Int(seconds))
    if value >= 3600 {
      return String(format: "%d:%02d:%02d", value / 3600, (value % 3600) / 60, value % 60)
    }
    return String(format: "%d:%02d", value / 60, value % 60)
  }

  /// The preview's wording for remaining time: "About 1 min left" or "Less than a minute left".
  static func remaining(_ seconds: TimeInterval) -> String {
    if seconds < 60 { return "Less than a minute left" }
    return "About \(Int((seconds / 60).rounded())) min left"
  }
}

/// The two sections of the Downloads page.
enum DownloadsSegment: String, CaseIterable, Identifiable, Sendable {
  case inProgress, library

  static let defaultSegment: DownloadsSegment = .inProgress

  var id: String { rawValue }

  var title: String {
    switch self {
    case .inProgress: "In Progress"
    case .library: "Library"
    }
  }
}

/// A control on a download row.
enum DownloadRowAction: String, CaseIterable, Sendable {
  case pause, resume, cancel, retry, removeFiles, reveal, delete

  var title: String {
    switch self {
    case .pause: "Pause"
    case .resume: "Resume"
    case .cancel: "Cancel"
    case .retry: "Retry"
    case .removeFiles: "Remove Files"
    case .reveal: "Reveal"
    case .delete: "Delete"
    }
  }

  var symbol: String {
    switch self {
    case .pause: "pause.fill"
    case .resume: "play.fill"
    case .cancel: "xmark"
    case .retry: "arrow.clockwise"
    case .removeFiles: "trash.slash"
    case .reveal: "folder"
    case .delete: "trash"
    }
  }

  var isDestructive: Bool {
    switch self {
    case .cancel, .removeFiles, .delete: true
    case .pause, .resume, .retry, .reveal: false
    }
  }
}

/// Stable gradient tiles for row thumbnails, the same colours as the preview's sample rows.
enum LibraryPalette {
  static let gradients: [[Color]] = [
    [libraryHex(0x4B6CB7), libraryHex(0x182848)],
    [libraryHex(0xF7971E), libraryHex(0xA8325E)],
    [libraryHex(0x11998E), libraryHex(0x38EF7D)],
    [libraryHex(0x8E2DE2), libraryHex(0x4A00E0)],
  ]

  /// The same key always gets the same colours, across launches.
  static func gradient(for key: String) -> [Color] {
    let sum = key.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
    return gradients[sum % gradients.count]
  }
}

private func libraryHex(_ value: UInt32) -> Color {
  Color(
    red: Double((value >> 16) & 0xFF) / 255,
    green: Double((value >> 8) & 0xFF) / 255,
    blue: Double(value & 0xFF) / 255)
}

enum DownloadsModel {
  /// Every aria2 batch that is not finished. Completed batches live in the Completed Today and Library sections.
  static func inProgress(_ batches: [DownloadBatch]) -> [DownloadBatch] {
    batches.filter { $0.status != .completed }
  }

  /// Completed batches that finished on the same calendar day as `now`.
  static func completedToday(
    _ batches: [DownloadBatch], now: Date = .now, calendar: Calendar = .current
  ) -> [DownloadBatch] {
    batches.filter { batch in
      batch.status == .completed && calendar.isDate(batch.completedAt ?? batch.createdAt, inSameDayAs: now)
    }
  }

  /// The controls a row offers for a status. Delete is offered for every status except preparing.
  static func actions(for status: TransferStatus) -> [DownloadRowAction] {
    let primary: [DownloadRowAction]
    switch status {
    case .active, .queued: primary = [.pause, .cancel]
    case .paused, .cancelled: primary = [.resume, .removeFiles]
    case .failed: primary = [.retry, .removeFiles]
    case .completed: primary = [.reveal]
    case .preparing: primary = []
    }
    return status == .preparing ? primary : primary + [.delete]
  }

  static func summary(_ batches: [DownloadBatch], torrentRows: [TorrentTransferRow]) -> String {
    let active = batches.filter { $0.status == .active }.count
    let paused = batches.filter { $0.status == .paused }.count
    let total = batches.count + torrentRows.count
    guard total > 0 else { return "Nothing is downloading" }
    return "\(total) in progress • \(active) active • \(paused) paused"
  }

  /// The header text beside the segmented control: free space and the save folder.
  static func storageSummary(folder: String) -> String {
    let location = (folder as NSString).abbreviatingWithTildeInPath
    // The folder may not exist until the first download, so measure its nearest existing parent.
    var url = URL(fileURLWithPath: folder, isDirectory: true)
    while !FileManager.default.fileExists(atPath: url.path), url.pathComponents.count > 1 {
      url = url.deletingLastPathComponent()
    }
    guard
      let free = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        .volumeAvailableCapacityForImportantUsage
    else {
      return "Saving to \(location)"
    }
    return
      "\(Foundation.ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) free · Saving to \(location)"
  }
}

/// The In Progress section: active and failed transfers, then the batches that finished today.
struct DownloadsInProgressView: View {
  @ObservedObject var coordinator: AppCoordinator
  @ObservedObject var torrents: TorrentController
  @State private var partialDataBatch: DownloadBatch?
  @State private var deletingBatch: DownloadBatch?

  /// The shell's toolbar search narrows every list on this page.
  private var query: String { coordinator.searchText.trimmingCharacters(in: .whitespaces) }
  private func matches(_ name: String) -> Bool {
    query.isEmpty || name.localizedCaseInsensitiveContains(query)
  }

  private var batches: [DownloadBatch] {
    DownloadsModel.inProgress(coordinator.batches).filter { matches($0.title) }
  }
  /// Torrent transfers that are not finished. Completed torrents live in the Library section.
  private var torrentRows: [TorrentTransferRow] {
    torrents.transferRows.filter { !$0.isComplete && matches($0.name) }
  }
  private var completedToday: [DownloadBatch] {
    DownloadsModel.completedToday(coordinator.batches).filter { matches($0.title) }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if batches.isEmpty && torrentRows.isEmpty {
        if completedToday.isEmpty {
          ContentUnavailableView(
            "Nothing is downloading", systemImage: "arrow.down.circle",
            description: Text("Downloads you start from Sources will appear here.")
          )
          .frame(maxWidth: .infinity, minHeight: 240)
        }
      } else {
        RowCard(rows: progressRows)
      }
      if !completedToday.isEmpty {
        SectionHeader(
          title: "Completed Today", count: completedToday.count, actionTitle: "Clear",
          action: { coordinator.clearCompleted() })
        RowCard(rows: completedRows)
      }
    }
    .confirmationDialog(
      "Remove partial download data?",
      isPresented: Binding(
        get: { partialDataBatch != nil }, set: { if !$0 { partialDataBatch = nil } })
    ) {
      Button("Remove Partial Data", role: .destructive) {
        if let batch = partialDataBatch { Task { await coordinator.removePartialData(batch) } }
        partialDataBatch = nil
      }
    } message: {
      Text("Downloaded partial files and their queue record will be permanently removed.")
    }
    .confirmationDialog(
      "Delete this download from the queue?",
      isPresented: Binding(get: { deletingBatch != nil }, set: { if !$0 { deletingBatch = nil } })
    ) {
      Button("Delete from Queue", role: .destructive) {
        if let batch = deletingBatch { Task { await coordinator.deleteDownloadRecord(batch) } }
        deletingBatch = nil
      }
    } message: {
      Text("The transfer will stop, but completed and partial files will remain on disk.")
    }
  }

  private var progressRows: [RowCardItem] {
    batches.map(batchRow) + torrentRows.map(torrentRow)
  }

  private var completedRows: [RowCardItem] {
    completedToday.map { batch in
      var actions: [RowCardAction] = []
      if let url = playableURL(for: batch) {
        actions.append(
          RowCardAction(id: "play", title: "Play", systemImage: "play.fill", style: .button) {
            coordinator.playLocal(url: url)
          })
      }
      actions.append(
        RowCardAction(id: "reveal", title: "Show in Finder", systemImage: "folder") {
          coordinator.reveal(batch)
        })
      return RowCardItem(
        id: batch.id.uuidString, title: batch.title,
        thumbnailColors: LibraryPalette.gradient(for: batch.title), tags: ["HTTP"],
        meta: [DownloadFormat.bytes(batch.totalBytes)],
        status: playableURL(for: batch) == nil
          ? StatusPill(text: "Completed", style: .ok) : StatusPill(text: "In Library", style: .ok),
        actions: actions)
    }
  }

  private func batchRow(_ batch: DownloadBatch) -> RowCardItem {
    let failed = batch.status == .failed
    var meta: [String] = []
    if failed {
      meta = [batch.errorMessage ?? "Source unreachable"]
    } else {
      meta.append(
        "\(DownloadFormat.bytes(batch.completedBytes)) of \(DownloadFormat.bytes(batch.totalBytes))")
      if batch.downloadSpeed > 0 {
        meta.append("\(DownloadFormat.bytes(batch.downloadSpeed))/s")
      }
      if let eta = batch.estimatedSecondsRemaining {
        meta.append(DownloadFormat.remaining(eta))
      }
    }
    return RowCardItem(
      id: batch.id.uuidString, title: batch.title,
      thumbnailSymbol: failed ? "exclamationmark.triangle" : "film",
      thumbnailColors: failed ? [] : LibraryPalette.gradient(for: batch.title),
      thumbnailTint: .red, tags: ["HTTP"], meta: meta,
      status: statusPill(for: batch.status),
      progress: failed ? nil : batch.progress,
      actions: DownloadsModel.actions(for: batch.status).map { action in
        RowCardAction(
          id: action.rawValue, title: action.title, systemImage: action.symbol,
          style: action == .retry ? .button : .icon
        ) {
          perform(action, on: batch)
        }
      })
  }

  private func torrentRow(_ row: TorrentTransferRow) -> RowCardItem {
    let fraction = row.bytesTotal > 0 ? Double(row.bytesDone) / Double(row.bytesTotal) : 0
    var meta = ["\(DownloadFormat.bytes(row.bytesDone)) of \(DownloadFormat.bytes(row.bytesTotal))"]
    meta.append("↓ \(DownloadFormat.bytes(row.downloadSpeed))/s")
    meta.append("\(row.peers) peers")
    return RowCardItem(
      id: row.id, title: row.name, thumbnailSymbol: "film",
      thumbnailColors: LibraryPalette.gradient(for: row.name), tags: ["Torrent"], meta: meta,
      status: row.isStreaming
        ? StatusPill(text: "Streaming", style: .live) : StatusPill(text: row.state, style: .neutral),
      progress: fraction)
  }

  private func statusPill(for status: TransferStatus) -> StatusPill {
    switch status {
    case .active: StatusPill(text: "Downloading", style: .live)
    case .queued: StatusPill(text: "Queued", style: .neutral)
    case .preparing: StatusPill(text: "Preparing", style: .neutral)
    case .paused: StatusPill(text: "Paused", style: .warn)
    case .cancelled: StatusPill(text: "Cancelled", style: .warn)
    case .failed: StatusPill(text: "Failed", style: .err)
    case .completed: StatusPill(text: "Completed", style: .ok)
    }
  }

  /// The first completed video file in the batch, if one is still on disk.
  private func playableURL(for batch: DownloadBatch) -> URL? {
    coordinator.itemsForBatch(batch)
      .filter { $0.status == .completed }
      .map { URL(fileURLWithPath: $0.destinationPath) }
      .first { url in
        FileManager.default.fileExists(atPath: url.path)
          && MediaFileType.isVideo(DirectoryEntry(name: url.lastPathComponent, url: url, kind: .file))
      }
  }

  private func perform(_ action: DownloadRowAction, on batch: DownloadBatch) {
    switch action {
    case .pause: Task { await coordinator.pause(batch) }
    case .resume: Task { await coordinator.resume(batch) }
    case .cancel: Task { await coordinator.cancel(batch) }
    case .retry: Task { await coordinator.retry(batch) }
    case .removeFiles: partialDataBatch = batch
    case .reveal: coordinator.reveal(batch)
    case .delete: deletingBatch = batch
    }
  }
}

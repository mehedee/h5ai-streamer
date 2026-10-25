import SwiftUI

/// Byte and time text for download rows. Matches the formatting used by the download drawer.
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

enum DownloadsModel {
  /// Every aria2 batch that is not finished. Completed batches live in the Library section.
  static func inProgress(_ batches: [DownloadBatch]) -> [DownloadBatch] {
    batches.filter { $0.status != .completed }
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
}

/// Aria2 downloads still in progress, with pause, cancel and retry, plus the torrent seam.
struct DownloadsInProgressView: View {
  @ObservedObject var coordinator: AppCoordinator
  @ObservedObject var torrents: TorrentController
  @State private var partialDataBatch: DownloadBatch?
  @State private var deletingBatch: DownloadBatch?

  private var batches: [DownloadBatch] { DownloadsModel.inProgress(coordinator.batches) }
  /// Torrent transfers that are not finished. Completed torrents live in the Library section.
  private var torrentRows: [TorrentTransferRow] { torrents.transferRows.filter { !$0.isComplete } }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 8) {
        Text(DownloadsModel.summary(batches, torrentRows: torrentRows))
          .font(.callout).foregroundStyle(.secondary)
        Spacer()
        Button("Pause All") {
          for batch in coordinator.batches where batch.status == .active {
            Task { await coordinator.pause(batch) }
          }
        }
        .disabled(!coordinator.batches.contains { $0.status == .active })
        Button("Resume All") {
          for batch in coordinator.batches where batch.status == .paused {
            Task { await coordinator.resume(batch) }
          }
        }
        .disabled(!coordinator.batches.contains { $0.status == .paused })
        Button("Clear Completed") { coordinator.clearCompleted() }
          .disabled(!coordinator.batches.contains { $0.status == .completed })
      }
      if batches.isEmpty && torrentRows.isEmpty {
        ContentUnavailableView(
          "Nothing is downloading", systemImage: "arrow.down.circle",
          description: Text("Downloads you start from Sources will appear here."))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        List {
          ForEach(batches) { batch in
            DownloadProgressRow(
              batch: batch, itemCount: coordinator.itemsForBatch(batch).count,
              perform: { perform($0, on: batch) })
          }
          ForEach(torrentRows) { row in
            VStack(alignment: .leading, spacing: 6) {
              HStack {
                Text(row.name).font(.headline).lineLimit(1)
                if row.isStreaming { Text("Streaming").font(.caption).foregroundStyle(.tint) }
              }
              ProgressView(value: row.bytesTotal > 0 ? Double(row.bytesDone) / Double(row.bytesTotal) : 0)
              Text(row.state).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)
          }
        }
        .scrollContentBackground(.hidden)
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

private struct DownloadProgressRow: View {
  let batch: DownloadBatch
  let itemCount: Int
  let perform: (DownloadRowAction) -> Void
  @Environment(\.myraAccent) private var accent

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Image(systemName: statusIcon).foregroundStyle(statusColor)
        Text(batch.title).font(.headline).lineLimit(1)
        Spacer()
        Text(batch.status.rawValue.capitalized).foregroundStyle(.secondary)
      }
      ProgressView(value: batch.progress)
      HStack(spacing: 12) {
        Text(
          "\(DownloadFormat.bytes(batch.completedBytes)) of \(DownloadFormat.bytes(batch.totalBytes))"
        )
        Text("\(DownloadFormat.bytes(batch.downloadSpeed))/s")
        Text("Elapsed \(DownloadFormat.duration(batch.elapsed))")
        if let eta = batch.estimatedSecondsRemaining {
          Text("ETA \(DownloadFormat.duration(eta))")
        }
        Text("\(itemCount) files")
        Spacer()
        HStack(spacing: 6) {
          ForEach(DownloadsModel.actions(for: batch.status), id: \.self) { action in
            Button(role: action.isDestructive ? .destructive : nil) {
              perform(action)
            } label: {
              Label(action.title, systemImage: action.symbol)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("\(action.title) \(batch.title)")
            .accessibilityLabel("\(action.title) \(batch.title)")
          }
        }
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      if let error = batch.errorMessage { Text(error).font(.caption).foregroundStyle(.red) }
    }
    .padding(.vertical, 8)
  }

  private var statusIcon: String {
    switch batch.status {
    case .completed: "checkmark.circle.fill"
    case .failed: "exclamationmark.triangle.fill"
    case .paused: "pause.circle.fill"
    case .cancelled: "xmark.circle"
    default: "arrow.down.circle.fill"
    }
  }

  private var statusColor: Color {
    switch batch.status {
    case .completed: .green
    case .failed: .red
    case .paused, .cancelled: .orange
    default: accent.color
    }
  }
}

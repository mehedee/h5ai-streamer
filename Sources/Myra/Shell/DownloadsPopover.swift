import SwiftUI

/// Overall progress across the downloads that are still running: aria2 batches and torrents.
/// Built only from controller state, so the ring, the popover and the tests read the same numbers.
struct DownloadOverview: Equatable {
  struct Row: Identifiable, Equatable {
    let id: String
    let title: String
    /// "HTTP" for aria2 batches and "Torrent" for torrent transfers.
    let tag: String
    let details: [String]
    let fraction: Double
  }

  let rows: [Row]
  let completedBytes: Int64
  let totalBytes: Int64

  var hasDownloads: Bool { !rows.isEmpty }

  /// Completed bytes over total bytes across every running download, clamped to 0...1.
  var fraction: Double {
    totalBytes > 0 ? min(1, Double(completedBytes) / Double(totalBytes)) : 0
  }

  /// Batch statuses that count as running. Completed, failed and cancelled batches are not downloads now.
  static let runningStatuses: Set<TransferStatus> = [.preparing, .queued, .active, .paused]

  static func make(batches: [DownloadBatch], torrents: [TorrentTransferRow]) -> DownloadOverview {
    var rows: [Row] = []
    var completed: Int64 = 0
    var total: Int64 = 0

    for batch in batches where runningStatuses.contains(batch.status) {
      rows.append(
        Row(
          id: "batch-\(batch.id.uuidString)",
          title: batch.title,
          tag: "HTTP",
          details: details(
            done: batch.completedBytes, total: batch.totalBytes,
            speed: batch.downloadSpeed, paused: batch.status == .paused),
          fraction: batch.progress))
      completed += batch.completedBytes
      total += batch.totalBytes
    }

    for torrent in torrents where !torrent.isComplete {
      rows.append(
        Row(
          id: "torrent-\(torrent.id)",
          title: torrent.name,
          tag: "Torrent",
          details: details(
            done: torrent.bytesDone, total: torrent.bytesTotal,
            speed: torrent.downloadSpeed, paused: torrent.isPaused),
          fraction: torrent.bytesTotal > 0
            ? min(1, Double(torrent.bytesDone) / Double(torrent.bytesTotal)) : 0))
      completed += torrent.bytesDone
      total += torrent.bytesTotal
    }

    return DownloadOverview(rows: rows, completedBytes: completed, totalBytes: total)
  }

  private static func details(done: Int64, total: Int64, speed: Int64, paused: Bool) -> [String] {
    var parts = ["\(DownloadFormat.bytes(done)) of \(DownloadFormat.bytes(total))"]
    if paused {
      parts.append("Paused")
    } else if speed > 0 {
      parts.append("\(DownloadFormat.bytes(speed))/s")
    }
    return parts
  }
}

/// The 46pt toolbar button with a progress ring. It opens `DownloadsPopover`.
/// Callers show it only when `overview.hasDownloads` is true.
struct DownloadsRingButton: View {
  let overview: DownloadOverview
  let onShowAll: () -> Void

  @State private var isShowing = false
  @Environment(\.myraAccent) private var accent

  var body: some View {
    Button {
      isShowing.toggle()
    } label: {
      ZStack {
        Circle()
          .stroke(MyraColor.fill2, lineWidth: 2.5)
        if overview.fraction > 0 {
          Circle()
            .trim(from: 0, to: overview.fraction)
            .stroke(accent.color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            .rotationEffect(.degrees(-90))
        }
        Image(systemName: "arrow.down")
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(MyraColor.text)
      }
      .padding(4)
      .frame(width: 46, height: 46)
      .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .frame(width: 46, height: 46)
    .help("Downloads in progress")
    .accessibilityLabel("Downloads in progress")
    .accessibilityValue("\(Int((overview.fraction * 100).rounded())) percent")
    .popover(isPresented: $isShowing, arrowEdge: .bottom) {
      DownloadsPopover(
        overview: overview,
        onShowAll: {
          isShowing = false
          onShowAll()
        })
    }
  }
}

/// The 340pt "Downloads" popover: one row per running download and a button to the Downloads page.
struct DownloadsPopover: View {
  let overview: DownloadOverview
  let onShowAll: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Downloads")
        .font(.system(size: 13, weight: .bold))
      RowCard(
        rows: overview.rows.map { row in
          RowCardItem(
            id: row.id,
            title: row.title,
            tags: [row.tag],
            meta: row.details,
            progress: row.fraction)
        },
        showsThumbnails: false)
      HStack {
        Spacer()
        Button("Show All Downloads", action: onShowAll)
          .buttonStyle(MyraButtonStyle())
      }
      .padding(.top, 2)
    }
    .padding(12)
    .frame(width: 340)
  }
}

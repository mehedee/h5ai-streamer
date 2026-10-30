import SwiftUI

/// The Downloads > Scheduled section: new episodes of followed series, waiting for the off-peak
/// window, running, or already done. Each waiting item can be run now or skipped.
struct ScheduledDownloadsView: View {
  @ObservedObject var queue: AutomaticDownloadQueue
  var query: String = ""
  @AppStorage(MyraSystemPreferences.automaticDownloadsKey) private var automaticEnabled = false
  @AppStorage(MyraSystemPreferences.windowStartKey) private var windowStart =
    OffPeakWindow.standard.startMinute
  @AppStorage(MyraSystemPreferences.windowEndKey) private var windowEnd =
    OffPeakWindow.standard.endMinute

  private var window: OffPeakWindow {
    OffPeakWindow(startMinute: windowStart, endMinute: windowEnd).isValid
      ? OffPeakWindow(startMinute: windowStart, endMinute: windowEnd) : .standard
  }

  private var visible: [AutomaticDownloadItem] {
    let trimmed = query.trimmingCharacters(in: .whitespaces)
    return queue.items
      .filter {
        trimmed.isEmpty
          || $0.seriesTitle.localizedCaseInsensitiveContains(trimmed)
          || $0.episodeName.localizedCaseInsensitiveContains(trimmed)
      }
      .sorted { lhs, rhs in
        let lhsRank = Self.rank(lhs.status)
        let rhsRank = Self.rank(rhs.status)
        if lhsRank != rhsRank { return lhsRank < rhsRank }
        return lhsRank == 0 ? lhs.foundAt < rhs.foundAt : lhs.foundAt > rhs.foundAt
      }
  }

  /// Waiting items first, then running, then history.
  private static func rank(_ status: AutomaticDownloadStatus) -> Int {
    switch status {
    case .pending: 0
    case .running: 1
    case .finished, .failed, .skipped: 2
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(note)
        .font(.system(size: 12))
        .foregroundStyle(MyraColor.text2)
        .padding(.bottom, 12)
      if visible.isEmpty {
        ContentUnavailableView(
          "Nothing is scheduled", systemImage: "calendar",
          description: Text(
            "New episodes of series you follow appear here when automatic downloads are on."
          )
        )
        .frame(maxWidth: .infinity, minHeight: 240)
      } else {
        RowCard(rows: visible.map(row))
      }
    }
  }

  private var note: String {
    let span = "\(OffPeakWindow.clockText(window.startMinute))–\(OffPeakWindow.clockText(window.endMinute))"
    guard automaticEnabled else {
      return
        "Automatic downloads are off. Turn them on in Settings > Downloads to queue new episodes for the off-peak window (\(span))."
    }
    return
      "New episodes of series you follow download in your off-peak window (\(span)). Myra must be open for them to start."
  }

  private func row(_ item: AutomaticDownloadItem) -> RowCardItem {
    RowCardItem(
      id: item.id.uuidString, title: item.episodeName,
      thumbnailColors: LibraryPalette.gradient(for: item.seriesTitle), tags: ["Auto"],
      meta: meta(for: item), status: pill(for: item),
      actions: actions(for: item))
  }

  private func meta(for item: AutomaticDownloadItem) -> [String] {
    var parts = [item.seriesTitle, "Found " + Self.foundText(item.foundAt)]
    if let size = item.size, size > 0 { parts.append(DownloadFormat.bytes(size)) }
    if item.status == .pending, automaticEnabled,
      let opening = window.nextOpening(after: .now, calendar: .current),
      opening > .now
    {
      parts.append("Starts " + opening.formatted(date: .omitted, time: .shortened))
    }
    if let message = item.message, item.status == .failed { parts.append(message) }
    return parts
  }

  private func pill(for item: AutomaticDownloadItem) -> StatusPill {
    switch item.status {
    case .pending: StatusPill(text: "Waiting", style: .neutral)
    case .running: StatusPill(text: "Downloading", style: .live)
    case .finished: StatusPill(text: "Finished", style: .ok)
    case .failed: StatusPill(text: "Failed", style: .err)
    case .skipped: StatusPill(text: "Skipped", style: .warn)
    }
  }

  private func actions(for item: AutomaticDownloadItem) -> [RowCardAction] {
    guard item.isActionable else { return [] }
    return [
      RowCardAction(id: "run", title: "Run now", systemImage: "play.fill", style: .button) {
        Task { await queue.runNow(item.id) }
      },
      RowCardAction(id: "skip", title: "Skip", systemImage: "forward.end", style: .button) {
        queue.skip(item.id)
      },
    ]
  }

  private static func foundText(_ date: Date) -> String {
    RelativeDateTimeFormatter().localizedString(for: date, relativeTo: .now)
  }
}

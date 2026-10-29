import SwiftUI

/// The header's indexing indicator (`.act`). Its width is fixed at 204 pt: an icon, a label that
/// truncates, and a 56 pt right-aligned monospaced-digit count column, so the header never shifts
/// as the count grows. Idle shows a check, "Up to date" and the library total; running shows a
/// spinner, "Indexing n/m" and the videos found so far.
enum IndexingIndicatorLayout {
  static let width: CGFloat = 204
  static let countColumnWidth: CGFloat = 56
}

struct IndexingIndicator: View {
  let snapshot: IndexingSnapshot
  let actions: IndexingActions
  let manage: () -> Void

  @State private var showingPopover = false
  @Environment(\.myraAccent) private var accent

  var body: some View {
    Button {
      showingPopover.toggle()
    } label: {
      HStack(spacing: 8) {
        icon.frame(width: 14, height: 14)
        Text(snapshot.label)
          .lineLimit(1)
          .truncationMode(.tail)
          .frame(maxWidth: .infinity, alignment: .leading)
        Text(snapshot.count.formatted())
          .monospacedDigit()
          .lineLimit(1)
          .frame(width: IndexingIndicatorLayout.countColumnWidth, alignment: .trailing)
      }
      .font(.system(size: 13, weight: snapshot.isRunning ? .semibold : .medium))
      .foregroundStyle(snapshot.isRunning ? accent.color : MyraColor.text2)
      .padding(.horizontal, 12)
      .padding(.vertical, 5)
      .frame(width: IndexingIndicatorLayout.width)
      .background {
        Capsule().fill(.ultraThinMaterial)
        Capsule().fill(snapshot.isRunning ? accent.color.opacity(0.13) : MyraColor.glass)
      }
      .overlay(Capsule().stroke(MyraColor.line, lineWidth: 1))
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .frame(width: IndexingIndicatorLayout.width)
    .accessibilityLabel("Library indexing status")
    .accessibilityValue("\(snapshot.label), \(snapshot.count) \(snapshot.isRunning ? "videos found" : "titles")")
    .help(snapshot.isRunning ? "Indexing library" : "Library up to date")
    .popover(isPresented: $showingPopover, arrowEdge: .bottom) {
      IndexingPopover(snapshot: snapshot, actions: actions, manage: manage) {
        showingPopover = false
      }
    }
  }

  @ViewBuilder private var icon: some View {
    if snapshot.isRunning {
      if snapshot.isPaused {
        Image(systemName: "pause.fill").font(.system(size: 11))
      } else {
        ProgressView().controlSize(.mini).scaleEffect(0.8)
      }
    } else {
      Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold))
    }
  }
}

/// The popover: one row per source, Pause and Cancel while indexing, Refresh now when idle.
struct IndexingPopover: View {
  let snapshot: IndexingSnapshot
  let actions: IndexingActions
  let manage: () -> Void
  let dismiss: () -> Void

  @Environment(\.myraAccent) private var accent

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(snapshot.isRunning ? (snapshot.isPaused ? "Indexing paused" : "Indexing library") : "Library up to date")
        .font(.system(size: 13, weight: .bold))
      Text(summary)
        .font(.system(size: 12)).foregroundStyle(MyraColor.text2).monospacedDigit()
      if snapshot.sources.isEmpty {
        Text("No sources yet. Add one in Sources.")
          .font(.system(size: 12)).foregroundStyle(MyraColor.text2)
      } else {
        VStack(spacing: 0) {
          ForEach(Array(snapshot.sources.enumerated()), id: \.element.id) { index, source in
            if index > 0 { Rectangle().fill(MyraColor.line).frame(height: 1) }
            sourceRow(source)
          }
        }
        .background(MyraColor.fill, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(MyraColor.line, lineWidth: 1))
      }
      HStack(spacing: 8) {
        if snapshot.isRunning {
          Button(snapshot.isPaused ? "Resume" : "Pause") {
            snapshot.isPaused ? actions.resume() : actions.pause()
          }
          .buttonStyle(MyraButtonStyle())
          Button("Cancel") {
            actions.cancel()
            dismiss()
          }
          .buttonStyle(MyraButtonStyle())
        } else {
          Button {
            actions.refreshNow()
            dismiss()
          } label: {
            Label("Refresh now", systemImage: "arrow.clockwise")
          }
          .buttonStyle(MyraButtonStyle(prominent: true))
        }
        Spacer(minLength: 8)
        Button("Folders…") {
          dismiss()
          manage()
        }
        .buttonStyle(.plain).foregroundStyle(accent.color)
      }
    }
    .padding(14)
    .frame(width: 330)
  }

  private var summary: String {
    if snapshot.isRunning {
      return
        "Source \(snapshot.currentSource) of \(max(snapshot.sourceCount, 1)) · \(snapshot.videosFound.formatted()) videos found"
    }
    return "\(snapshot.libraryTotal.formatted()) titles · " + ShellFooterText.scanned(snapshot.lastScan)
  }

  private func sourceRow(_ source: IndexingSourceRow) -> some View {
    HStack(spacing: 10) {
      VStack(alignment: .leading, spacing: 1) {
        Text(source.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
        Text(detail(source)).font(.system(size: 11)).foregroundStyle(MyraColor.text2).lineLimit(1)
      }
      Spacer(minLength: 6)
      switch source.state {
      case .indexed: StatusPill(text: "Indexed", style: .ok)
      case .indexing(let fraction):
        StatusPill(
          text: fraction.map { "Indexing \(Int($0 * 100))%" } ?? "Indexing", style: .live)
      case .queued: StatusPill(text: "Queued")
      case .unreachable: StatusPill(text: "Unreachable", style: .warn)
      }
    }
    .padding(.horizontal, 10).padding(.vertical, 8)
  }

  private func detail(_ source: IndexingSourceRow) -> String {
    var parts: [String] = []
    if !source.host.isEmpty { parts.append(source.host) }
    if let titles = source.titles { parts.append("\(titles.formatted()) titles") }
    if let last = source.lastScan { parts.append(ShellFooterText.scanned(last)) }
    return parts.joined(separator: " · ")
  }
}

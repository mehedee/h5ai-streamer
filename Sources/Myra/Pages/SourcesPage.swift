import SwiftUI

/// The saved facts a source card needs. Built from `Category` so the summary logic stays testable.
struct SourceInput: Equatable, Sendable {
  let id: UUID
  let name: String
  let rootURLString: String
}

enum SourceStatus: Equatable, Sendable {
  case unavailable, indexing, indexed, notIndexed

  var title: String {
    switch self {
    case .unavailable: "Unreachable"
    case .indexing: "Scanning"
    case .indexed: "Indexed"
    case .notIndexed: "Not indexed"
    }
  }
}

/// One source card: name, host, status and counts from the library index.
struct SourceSummary: Identifiable, Equatable, Sendable {
  let id: UUID
  let name: String
  let host: String
  let status: SourceStatus
  let titleCount: Int
  let mediaCount: Int
  /// Total size of the videos indexed from this source, shown as the "media" statistic.
  var mediaBytes: Int64 = 0
}

enum SourceSummaries {
  /// The host for a source card. Local folders are shown as "This Mac", remote sources by host.
  static func host(for rootURLString: String) -> String {
    guard let url = URL(string: rootURLString) else { return "Unknown location" }
    if url.isFileURL { return "This Mac" }
    return url.host ?? url.scheme ?? "Unknown location"
  }

  /// Counts titles, videos and bytes per source from the catalogue.
  /// Unavailable beats indexing, which beats indexed.
  static func make(
    sources: [SourceInput], titles: [EntertainmentTitle], unavailableNames: Set<String>,
    isIndexing: Bool
  ) -> [SourceSummary] {
    var titleCounts: [UUID: Int] = [:]
    var mediaCounts: [UUID: Int] = [:]
    var mediaBytes: [UUID: Int64] = [:]
    for title in titles {
      var sourcesOfTitle = Set<UUID>()
      for version in title.versions {
        let sourceID = version.media.categoryID
        mediaCounts[sourceID, default: 0] += 1
        mediaBytes[sourceID, default: 0] += version.media.entry.size ?? 0
        sourcesOfTitle.insert(sourceID)
      }
      for sourceID in sourcesOfTitle { titleCounts[sourceID, default: 0] += 1 }
    }
    return sources.map { source in
      let media = mediaCounts[source.id] ?? 0
      let status: SourceStatus
      if unavailableNames.contains(source.name) {
        status = .unavailable
      } else if isIndexing {
        status = .indexing
      } else {
        status = media > 0 ? .indexed : .notIndexed
      }
      return SourceSummary(
        id: source.id, name: source.name, host: host(for: source.rootURLString), status: status,
        titleCount: titleCounts[source.id] ?? 0, mediaCount: media,
        mediaBytes: mediaBytes[source.id] ?? 0)
    }
  }

  /// The compact "since scan" age from the preview: "now", "4 min", "2 hr", "2 days".
  static func scanAge(since date: Date?, now: Date = .now) -> String {
    guard let date else { return "never" }
    let seconds = max(0, now.timeIntervalSince(date))
    if seconds < 60 { return "now" }
    if seconds < 3600 { return "\(Int(seconds / 60)) min" }
    if seconds < 86_400 { return "\(Int(seconds / 3600)) hr" }
    let days = Int(seconds / 86_400)
    return days == 1 ? "1 day" : "\(days) days"
  }
}

/// Resolution labels read from file names, shown as the Quality tag in the source browser.
enum SourceFileFormat {
  static let resolutions = ["2160p", "1080p", "720p", "480p"]

  static func resolution(for fileName: String) -> String? {
    resolutions.first { fileName.localizedCaseInsensitiveContains($0) }
  }
}

/// List or grid for a source's files. Without a stored choice, a folder with videos opens as a grid.
enum SourceBrowserLayout: String, CaseIterable, Identifiable, Sendable {
  case list, grid

  var id: String { rawValue }

  var title: String {
    switch self {
    case .list: "List"
    case .grid: "Grid"
    }
  }

  var symbol: String {
    switch self {
    case .list: "list.bullet"
    case .grid: "square.grid.2x2"
    }
  }

  /// The saved choice, or the preview's file table.
  static func resolve(stored: String) -> SourceBrowserLayout {
    SourceBrowserLayout(rawValue: stored) ?? .list
  }
}

/// A small uppercase label from the preview's `.tag` style, used for quality and transfer kind.
struct LibraryTag: View {
  let text: String

  var body: some View {
    Text(text.uppercased())
      .font(.system(size: 10, weight: .bold))
      .tracking(0.4)
      .foregroundStyle(MyraColor.text2)
      .padding(.horizontal, 6)
      .padding(.vertical, 1)
      .background(MyraColor.fill2, in: RoundedRectangle(cornerRadius: 4))
      .lineLimit(1)
  }
}

/// The Sources landing page: a grid of source cards (`.grid`, `.source`), with a dashed card to add one.
struct SourcesOverview: View {
  let summaries: [SourceSummary]
  let isIndexing: Bool
  let indexingFraction: Double
  let lastIndexed: Date?
  let open: (UUID) -> Void
  let edit: (UUID) -> Void
  let delete: (UUID) -> Void
  let addSource: () -> Void
  /// The source shown in Browse below the grid, outlined as the preview's `.source.sel`.
  var selectedID: UUID?
  /// False when Browse sits below the grid, so the page has one scrolling area.
  var scrolls = true
  var hint: String?

  var body: some View {
    if scrolls {
      ScrollView { content }
    } else {
      content
    }
  }

  private var content: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(caption)
        .font(.system(size: 12))
        .foregroundStyle(MyraColor.text2)
        .padding(.top, 8)
        .padding(.bottom, 12)
      LazyVGrid(
        columns: [GridItem(.adaptive(minimum: 250), spacing: 14, alignment: .top)], spacing: 14
      ) {
        ForEach(summaries) { summary in
          SourceCard(
            summary: summary, isIndexing: isIndexing, indexingFraction: indexingFraction,
            lastIndexed: lastIndexed, isSelected: summary.id == selectedID,
            open: { open(summary.id) },
            edit: { edit(summary.id) }, delete: { delete(summary.id) })
        }
        AddSourceCard(action: addSource)
      }
      if let hint {
        Text(hint)
          .font(.system(size: 12))
          .foregroundStyle(MyraColor.text2)
          .padding(.top, 14)
      }
    }
    .padding(.horizontal, 26)
    .padding(.top, 4)
    .padding(.bottom, scrolls ? 30 : 0)
  }

  private var caption: String {
    let videos = summaries.reduce(0) { $0 + $1.mediaCount }
    let sourceCount = summaries.count
    return "\(sourceCount) \(sourceCount == 1 ? "source" : "sources") • \(videos) \(videos == 1 ? "video" : "videos") in the local index"
  }
}

private struct SourceCard: View {
  let summary: SourceSummary
  let isIndexing: Bool
  let indexingFraction: Double
  let lastIndexed: Date?
  var isSelected = false
  let open: () -> Void
  let edit: () -> Void
  let delete: () -> Void

  @State private var isHovering = false
  @Environment(\.myraAccent) private var accent
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    Button(action: open) {
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 10) {
          Image(systemName: summary.host == "This Mac" ? "folder.fill" : "server.rack")
            .font(.system(size: 18))
            .foregroundStyle(accent.color)
            .frame(width: 36, height: 36)
            .background(
              accent.color.opacity(colorScheme == .dark ? 0.20 : 0.13),
              in: RoundedRectangle(cornerRadius: 9))
            .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 0) {
            Text(summary.name)
              .font(.system(size: 13, weight: .bold))
              .lineLimit(1)
            Text(summary.host)
              .font(.system(size: 12))
              .foregroundStyle(MyraColor.text2)
              .lineLimit(1)
          }
          Spacer(minLength: 6)
          pill
        }
        if summary.status == .indexing {
          ProgressBarView(fraction: indexingFraction)
        }
        HStack(alignment: .top, spacing: 16) {
          stat(summary.titleCount.formatted(), "titles")
          stat(
            ByteCountFormatter.string(fromByteCount: summary.mediaBytes, countStyle: .file),
            "media")
          if summary.status == .indexing {
            stat("now", "scanning")
          } else {
            stat(SourceSummaries.scanAge(since: lastIndexed), "since scan")
          }
        }
      }
      .padding(16)
      // Grid cells share the Add Source card's height, as the preview's grid stretches rows.
      .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
      .background(MyraColor.content, in: RoundedRectangle(cornerRadius: MyraRadius.panel))
      .overlay(
        RoundedRectangle(cornerRadius: MyraRadius.panel)
          .stroke(isHovering || isSelected ? accent.color : MyraColor.line, lineWidth: 1))
      // The preview's selected ring: a 3pt soft accent halo outside the border.
      .overlay(
        RoundedRectangle(cornerRadius: MyraRadius.panel + 3)
          .stroke(accent.color.opacity(isSelected ? 0.2 : 0), lineWidth: 3)
          .padding(-2.5))
      .contentShape(RoundedRectangle(cornerRadius: MyraRadius.panel))
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .help("Browse \(summary.name)")
    .accessibilityLabel(
      "\(summary.name), \(summary.host), \(summary.status.title), \(summary.titleCount) titles")
    .contextMenu {
      Button("Edit Source…", action: edit)
      Button("Delete Source…", role: .destructive, action: delete)
    }
  }

  @ViewBuilder private var pill: some View {
    switch summary.status {
    case .indexed:
      StatusPill(text: "Indexed", style: .ok)
    case .indexing:
      StatusPill(
        text: "Scanning \(Int((min(1, max(0, indexingFraction)) * 100).rounded()))%", style: .live)
    case .unavailable:
      StatusPill(text: "Unreachable", style: .warn)
    case .notIndexed:
      StatusPill(text: "Not indexed", style: .neutral)
    }
  }

  private func stat(_ value: String, _ label: String) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(value)
        .font(.system(size: 15, weight: .bold))
        .foregroundStyle(MyraColor.text)
        .monospacedDigit()
        .lineLimit(1)
      Text(label)
        .font(.system(size: 12))
        .foregroundStyle(MyraColor.text2)
    }
  }
}

/// The dashed "Add Source" card at the end of the grid (`.source.add`).
private struct AddSourceCard: View {
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      VStack(spacing: 8) {
        Image(systemName: "plus")
          .font(.system(size: 20, weight: .regular))
        Text("Add Source")
          .font(.system(size: 13))
      }
      .foregroundStyle(MyraColor.text2)
      .frame(maxWidth: .infinity, minHeight: 150)
      .overlay(
        RoundedRectangle(cornerRadius: MyraRadius.panel)
          .strokeBorder(MyraColor.lineStrong, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
      .contentShape(RoundedRectangle(cornerRadius: MyraRadius.panel))
    }
    .buttonStyle(.plain)
    .help("Add a folder or network share as a source")
    .accessibilityLabel("Add Source")
  }
}

/// Connects the Sources overview to the saved sources, the catalogue and the index status.
struct SourcesOverviewPage: View {
  @ObservedObject var coordinator: AppCoordinator
  @ObservedObject var store: EntertainmentStore
  @ObservedObject var library: LibraryController
  let open: (UUID) -> Void
  let edit: (UUID) -> Void
  let delete: (UUID) -> Void
  let addSource: () -> Void
  var selectedID: UUID?
  var scrolls = true
  var hint: String?

  init(
    coordinator: AppCoordinator, open: @escaping (UUID) -> Void,
    edit: @escaping (UUID) -> Void, delete: @escaping (UUID) -> Void,
    addSource: @escaping () -> Void, selectedID: UUID? = nil, scrolls: Bool = true,
    hint: String? = nil
  ) {
    self.selectedID = selectedID
    self.scrolls = scrolls
    self.hint = hint
    self.coordinator = coordinator
    _store = ObservedObject(wrappedValue: coordinator.entertainment)
    _library = ObservedObject(wrappedValue: coordinator.library)
    self.open = open
    self.edit = edit
    self.delete = delete
    self.addSource = addSource
  }

  var body: some View {
    let inputs = coordinator.categories.map {
      SourceInput(id: $0.id, name: $0.name, rootURLString: $0.rootURLString)
    }
    let progress = library.progress
    SourcesOverview(
      summaries: SourceSummaries.make(
        sources: inputs, titles: store.catalogue,
        unavailableNames: Set(library.failures.map(\.categoryName)),
        isIndexing: library.isRefreshing),
      isIndexing: library.isRefreshing,
      indexingFraction: progress.sourcesTotal > 0
        ? min(1, Double(progress.sourcesCompleted) / Double(progress.sourcesTotal)) : 0,
      lastIndexed: library.lastRefresh,
      open: open, edit: edit, delete: delete, addSource: addSource,
      selectedID: selectedID, scrolls: scrolls, hint: hint)
  }
}

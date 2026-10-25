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
    case .unavailable: "Unavailable"
    case .indexing: "Indexing"
    case .indexed: "Indexed"
    case .notIndexed: "Not indexed"
    }
  }

  var symbol: String {
    switch self {
    case .unavailable: "exclamationmark.triangle.fill"
    case .indexing: "arrow.triangle.2.circlepath"
    case .indexed: "checkmark.circle.fill"
    case .notIndexed: "circle.dashed"
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
}

enum SourceSummaries {
  /// The host for a source card. Local folders are shown as "This Mac", remote sources by host.
  static func host(for rootURLString: String) -> String {
    guard let url = URL(string: rootURLString) else { return "Unknown location" }
    if url.isFileURL { return "This Mac" }
    return url.host ?? url.scheme ?? "Unknown location"
  }

  /// Counts titles and videos per source from the catalogue. Unavailable beats indexing, which beats indexed.
  static func make(
    sources: [SourceInput], titles: [EntertainmentTitle], unavailableNames: Set<String>,
    isIndexing: Bool
  ) -> [SourceSummary] {
    var titleCounts: [UUID: Int] = [:]
    var mediaCounts: [UUID: Int] = [:]
    for title in titles {
      var sourcesOfTitle = Set<UUID>()
      for version in title.versions {
        let sourceID = version.media.categoryID
        mediaCounts[sourceID, default: 0] += 1
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
        titleCount: titleCounts[source.id] ?? 0, mediaCount: media)
    }
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

  static func resolve(stored: String, hasVideos: Bool) -> SourceBrowserLayout {
    if let layout = SourceBrowserLayout(rawValue: stored) { return layout }
    return hasVideos ? .grid : .list
  }
}

/// The Sources landing page: a grid of source cards, with a card to add another source.
struct SourcesOverview: View {
  let summaries: [SourceSummary]
  let isIndexing: Bool
  let indexingFraction: Double
  let lastIndexed: Date?
  let open: (UUID) -> Void
  let edit: (UUID) -> Void
  let delete: (UUID) -> Void
  let addSource: () -> Void

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Sources").font(.largeTitle.bold())
          Text(caption).font(.callout).foregroundStyle(.secondary)
        }
        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 250, maximum: 320), spacing: 16)], spacing: 16
        ) {
          ForEach(summaries) { summary in
            SourceCard(
              summary: summary, isIndexing: isIndexing, indexingFraction: indexingFraction,
              lastIndexed: lastIndexed, open: { open(summary.id) },
              edit: { edit(summary.id) }, delete: { delete(summary.id) })
          }
          AddSourceCard(action: addSource)
        }
      }
      .padding(24)
    }
  }

  private var caption: String {
    let videos = summaries.reduce(0) { $0 + $1.mediaCount }
    let sourceCount = summaries.count
    return "\(sourceCount) \(sourceCount == 1 ? "source" : "sources") • \(videos) \(videos == 1 ? "video" : "videos") in the local index"
  }
}

struct SourceStatusBadge: View {
  let status: SourceStatus
  @Environment(\.myraAccent) private var accent

  var body: some View {
    Label(status.title, systemImage: status.symbol)
      .font(.caption.weight(.semibold))
      .labelStyle(.titleAndIcon)
      .padding(.horizontal, 8).padding(.vertical, 3)
      .foregroundStyle(color)
      .background(color.opacity(0.14), in: Capsule())
      .accessibilityLabel("Status: \(status.title)")
  }

  private var color: Color {
    switch status {
    case .indexed: .green
    case .unavailable: .orange
    case .indexing: accent.color
    case .notIndexed: .secondary
    }
  }
}

private struct SourceCard: View {
  let summary: SourceSummary
  let isIndexing: Bool
  let indexingFraction: Double
  let lastIndexed: Date?
  let open: () -> Void
  let edit: () -> Void
  let delete: () -> Void
  @Environment(\.myraAccent) private var accent

  var body: some View {
    Button(action: open) {
      VStack(alignment: .leading, spacing: 12) {
        HStack(alignment: .top) {
          Image(systemName: summary.host == "This Mac" ? "folder.fill" : "externaldrive.connected.to.line.below")
            .font(.title2).foregroundStyle(accent.color)
          Spacer()
          SourceStatusBadge(status: summary.status)
        }
        VStack(alignment: .leading, spacing: 3) {
          Text(summary.name).font(.headline).lineLimit(1)
          Text(summary.host).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        Text("\(summary.titleCount) titles • \(summary.mediaCount) videos")
          .font(.callout).foregroundStyle(.secondary)
        if summary.status == .indexing {
          ProgressView(value: indexingFraction).progressViewStyle(.linear)
          Text("Scanning this library…").font(.caption).foregroundStyle(.secondary)
        } else {
          Text(lastScanText).font(.caption).foregroundStyle(.secondary)
        }
      }
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: MyraRadius.card))
      .overlay(
        RoundedRectangle(cornerRadius: MyraRadius.card)
          .stroke(.secondary.opacity(0.2), lineWidth: 1))
      .contentShape(RoundedRectangle(cornerRadius: MyraRadius.card))
    }
    .buttonStyle(.plain)
    .help("Browse \(summary.name)")
    .accessibilityLabel(
      "\(summary.name), \(summary.host), \(summary.status.title), \(summary.titleCount) titles")
    .contextMenu {
      Button("Edit Source…", action: edit)
      Button("Delete Source…", role: .destructive, action: delete)
    }
  }

  private var lastScanText: String {
    guard let lastIndexed else { return "Not indexed yet" }
    return "Index updated \(lastIndexed.formatted(date: .abbreviated, time: .shortened))"
  }
}

private struct AddSourceCard: View {
  let action: () -> Void
  @Environment(\.myraAccent) private var accent

  var body: some View {
    Button(action: action) {
      VStack(spacing: 10) {
        Image(systemName: "plus.circle.fill").font(.largeTitle).foregroundStyle(accent.color)
        Text("Add Source").font(.headline)
        Text("Choose a folder or network share to index.")
          .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
      }
      .frame(maxWidth: .infinity, minHeight: 150)
      .padding(16)
      .overlay(
        RoundedRectangle(cornerRadius: MyraRadius.card)
          .strokeBorder(.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [5])))
      .contentShape(RoundedRectangle(cornerRadius: MyraRadius.card))
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

  init(
    coordinator: AppCoordinator, open: @escaping (UUID) -> Void,
    edit: @escaping (UUID) -> Void, delete: @escaping (UUID) -> Void,
    addSource: @escaping () -> Void
  ) {
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
      open: open, edit: edit, delete: delete, addSource: addSource)
  }
}

import SwiftUI

/// A "See All" destination: one Home shelf shown as a grid.
struct SeeAllRequest: Hashable, Identifiable, Sendable {
  enum Source: Hashable, Sendable {
    /// An automatic shelf, by its shelf ID.
    case automatic(String)
    case topRated, recent, series, latest, newEpisodes
    case collection(UUID)
  }

  var name: String
  var source: Source
  var id: String { name }
}

/// Sort choices on the See All page (`SORTS` in the preview).
enum SeeAllSort: String, CaseIterable, Identifiable {
  case rating, added, name, year

  var id: String { rawValue }

  var title: String {
    switch self {
    case .rating: "Top rated"
    case .added: "Recently added"
    case .name: "A to Z"
    case .year: "Newest release"
    }
  }

  func sorted(_ titles: [EntertainmentTitle]) -> [EntertainmentTitle] {
    switch self {
    case .rating:
      titles.sorted { ($0.metadata?.rating ?? 0) > ($1.metadata?.rating ?? 0) }
    case .added:
      titles.sorted { $0.latestDiscovered > $1.latestDiscovered }
    case .name:
      titles.sorted {
        $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
      }
    case .year:
      titles.sorted { ($0.latestReleaseDate ?? $0.year ?? "") > ($1.latestReleaseDate ?? $1.year ?? "") }
    }
  }
}

/// Grid measurements. The poster's hover ring is drawn 3 pt outside the poster with a 3 pt stroke,
/// so a grid or shelf needs at least `ringInset` of room on every side to avoid clipping it.
enum TitleGridLayout {
  static let ringInset: CGFloat = 8
  static let columnSpacing: CGFloat = 16
  static let rowSpacing: CGFloat = 20
  static let cellRange: ClosedRange<Double> = 110...220
  static let defaultCell: Double = 150
  static let cellKey = "myraSeeAllCell"
}

/// Presents the details sheet, the version chooser and Ask Myra for pages that show title cards,
/// and plays a title the way Home does.
struct TitleBrowserActions {
  var open: (EntertainmentTitle) -> Void
  var play: (EntertainmentTitle) -> Void
}

struct TitleBrowserHost<Content: View>: View {
  @ObservedObject var coordinator: AppCoordinator
  @ObservedObject var store: EntertainmentStore
  @ViewBuilder var content: (TitleBrowserActions) -> Content

  @State private var details: EntertainmentTitle?
  @State private var choosing: EntertainmentTitle?
  @State private var pendingChoice: EntertainmentTitle?
  @State private var showingAI = false
  @State private var aiFeature: MyraAIFeature = .smartPick
  @State private var aiTitle: EntertainmentTitle?
  @State private var pendingAI = false

  var body: some View {
    content(TitleBrowserActions(open: { details = $0 }, play: { start($0) }))
      .sheet(item: $details, onDismiss: presentPending) { title in
        EntertainmentDetailView(
          title: title, store: store, play: { start($0) },
          aiAction: { feature, title in
            aiFeature = feature
            aiTitle = title
            pendingAI = true
            details = nil
          })
      }
      .sheet(item: $choosing) { title in
        EntertainmentVersionChooser(title: title, store: store) { version in
          choosing = nil
          details = nil
          if version.progressSeconds >= 5 {
            coordinator.resumeVersion(version)
          } else {
            coordinator.playChosenVersion(version.media)
          }
        }
      }
      .sheet(isPresented: $showingAI, onDismiss: presentPending) {
        MyraAIWorkspaceView(store: store, initialFeature: aiFeature, initialTitle: aiTitle) {
          start($0)
        }
      }
  }

  private func start(_ title: EntertainmentTitle) {
    if let version = title.resumeVersion {
      details = nil
      showingAI = false
      coordinator.resumeVersion(version)
      return
    }
    guard !title.versions.isEmpty else { return }
    // A movie with an "Always use" quality plays that release directly. Series choose per episode.
    if title.kind == .movie, title.versions.count > 1,
      let choice = BestVersionPicker.choose(
        versions: title.versions, titleQuality: store.personal.titleQualities?[title.id],
        preferredQuality: store.personal.preferences.preferredQuality),
      choice.followsTitlePreference
    {
      details = nil
      showingAI = false
      coordinator.playChosenVersion(choice.version.media)
      return
    }
    if title.versions.count == 1, let version = title.versions.first {
      details = nil
      showingAI = false
      coordinator.playChosenVersion(version.media)
    } else if details != nil || showingAI {
      pendingChoice = title
      details = nil
      showingAI = false
    } else {
      choosing = title
    }
  }

  private func presentPending() {
    if pendingAI {
      pendingAI = false
      showingAI = true
      return
    }
    if let pending = pendingChoice {
      pendingChoice = nil
      choosing = pending
    }
  }
}

/// A grid of poster cards that leaves room for the hover ring on every side.
struct TitleGrid: View {
  let titles: [EntertainmentTitle]
  @ObservedObject var store: EntertainmentStore
  let cell: CGFloat
  let actions: TitleBrowserActions

  var body: some View {
    LazyVGrid(
      columns: [
        GridItem(
          .adaptive(minimum: cell, maximum: cell * 1.6), spacing: TitleGridLayout.columnSpacing,
          alignment: .top)
      ],
      alignment: .leading, spacing: TitleGridLayout.rowSpacing
    ) {
      ForEach(titles) { title in
        HomePosterCard(
          title: title, store: store, play: { actions.play(title) },
          details: { actions.open(title) })
      }
    }
    .padding(TitleGridLayout.ringInset)
  }
}

/// The category page (`renderCategory`): the pinned filter bar, a title with its count, Sort and
/// Size controls, then every title of the shelf as a grid.
struct SeeAllPage: View {
  @ObservedObject var coordinator: AppCoordinator
  @ObservedObject var store: EntertainmentStore
  @ObservedObject var filters: LibraryFilterModel
  let request: SeeAllRequest

  @AppStorage(TitleGridLayout.cellKey) private var cell = TitleGridLayout.defaultCell
  @AppStorage("myraSeeAllSort") private var sortRaw = SeeAllSort.rating.rawValue
  @State private var projection = HomeCatalogueProjection()
  @State private var loaded = false
  private static let worker = HomeProjectionWorker()

  private var sort: SeeAllSort { SeeAllSort(rawValue: sortRaw) ?? .rating }

  private var filter: HomeCatalogueFilter {
    HomeCatalogueFilter(
      query: coordinator.searchText, selection: filters.selection,
      revision: store.projectionRevision)
  }

  private var items: [EntertainmentTitle] {
    let base: [EntertainmentTitle]
    switch request.source {
    case .automatic(let id):
      base = projection.shelves.first { $0.id == id }?.titles ?? []
    case .topRated: base = projection.movies
    case .recent: base = projection.recent
    case .series: base = projection.series
    case .latest: base = projection.latest
    case .newEpisodes:
      base = projection.filtered.filter { $0.versions.contains { store.hasNewEpisode($0) } }
    case .collection(let id):
      let ids = store.personal.collections.first { $0.id == id }?.titleIDs ?? []
      base = projection.filtered.filter { ids.contains($0.id) }
    }
    return sort.sorted(base)
  }

  var body: some View {
    TitleBrowserHost(coordinator: coordinator, store: store) { actions in
      VStack(spacing: 0) {
        LibraryFilterBar(
          model: filters, options: projection.options, shown: projection.filtered.count,
          total: store.catalogue.count
        ) { EmptyView() }
        ScrollView {
          VStack(alignment: .leading, spacing: 0) {
            controls(count: items.count)
            if items.isEmpty && loaded {
              ContentUnavailableView(
                "No matches", systemImage: "line.3.horizontal.decrease.circle",
                description: Text("Try removing a filter."))
                .frame(minHeight: 240)
            } else {
              TitleGrid(titles: items, store: store, cell: CGFloat(cell), actions: actions)
            }
          }
          .padding(.horizontal, HomeLayout.pageInset - TitleGridLayout.ringInset)
          .padding(.bottom, 30)
        }
      }
    }
    .task(id: filter) {
      let request = filter
      do {
        try await Task.sleep(for: .milliseconds(60))
        let result = try await Self.worker.prepare(
          store.catalogue, personal: store.personal, filter: request)
        try Task.checkCancellation()
        projection = result
        loaded = true
      } catch {}
    }
  }

  private func controls(count: Int) -> some View {
    HStack(alignment: .center, spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(request.name).font(.system(size: 17, weight: .bold)).lineLimit(1)
          Text(count.formatted()).foregroundStyle(MyraColor.text3).monospacedDigit()
        }
        Text("All items in grid view · filters above apply here too")
          .font(.system(size: 12)).foregroundStyle(MyraColor.text2)
      }
      Spacer(minLength: 12)
      HStack(spacing: 6) {
        Text("Sort").foregroundStyle(MyraColor.text2)
        Picker("Sort", selection: $sortRaw) {
          ForEach(SeeAllSort.allCases) { Text($0.title).tag($0.rawValue) }
        }
        .labelsHidden().fixedSize()
        .accessibilityLabel("Sort")
      }
      HStack(spacing: 8) {
        Text("Size").foregroundStyle(MyraColor.text2)
        Slider(value: $cell, in: TitleGridLayout.cellRange).frame(width: 120)
          .accessibilityLabel("Card size")
      }
    }
    .font(.system(size: 13))
    .padding(.top, 18)
    .padding(.horizontal, TitleGridLayout.ringInset)
  }
}

/// The Watchlist page: a grid of saved titles.
struct WatchlistPage: View {
  @ObservedObject var coordinator: AppCoordinator
  @ObservedObject var store: EntertainmentStore

  @AppStorage(TitleGridLayout.cellKey) private var cell = TitleGridLayout.defaultCell

  private var titles: [EntertainmentTitle] {
    let saved = WatchlistStore.titles(in: store.catalogue, saved: store.personal.watchlist)
    let query = coordinator.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    return query.isEmpty
      ? saved : saved.filter { $0.displayName.localizedCaseInsensitiveContains(query) }
  }

  var body: some View {
    TitleBrowserHost(coordinator: coordinator, store: store) { actions in
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Saved to watch later").font(.system(size: 17, weight: .bold))
            Text(titles.count.formatted()).foregroundStyle(MyraColor.text3).monospacedDigit()
            Spacer()
          }
          .padding(.top, 18)
          .padding(.horizontal, TitleGridLayout.ringInset)
          Text("Use the bookmark on any poster to add or remove a title.")
            .font(.system(size: 12)).foregroundStyle(MyraColor.text2)
            .padding(.horizontal, TitleGridLayout.ringInset)
          if titles.isEmpty {
            ContentUnavailableView(
              "Nothing saved yet", systemImage: "bookmark",
              description: Text("Hover a poster and press the bookmark to save it here."))
              .frame(minHeight: 280)
          } else {
            TitleGrid(titles: titles, store: store, cell: CGFloat(cell), actions: actions)
          }
        }
        .padding(.horizontal, HomeLayout.pageInset - TitleGridLayout.ringInset)
        .padding(.bottom, 30)
      }
    }
  }
}

import Foundation

/// The two segments of the Transfers page.
enum TorrentsTab: Int, Sendable {
  case transfers = 0
  case search = 1
}

/// What the user chose on a search result. The Add torrent sheet opens with this action first.
enum TorrentStartMode: Sendable {
  case play, download
}

/// State of the Search tab: the query, per-indexer progress, merged results and filters.
/// Nothing runs until `search()` or `retryFailed()` is called from a user action.
@MainActor
final class TorrentSearchModel: ObservableObject {
  enum Phase: Equatable { case idle, searching, done }

  @Published var query = ""
  @Published var filter = TorrentSearchFilter()
  @Published private(set) var phase: Phase = .idle
  @Published private(set) var statuses: [IndexerStatus] = []
  @Published private(set) var collected: [TorrentSearchResult] = []
  /// The query the current results belong to.
  @Published private(set) var searchedQuery = ""
  @Published var notice: String?

  let store: TorrentIndexerStore
  var engine: TorrentSearchEngine
  private var task: Task<Void, Never>?
  private var generation = UUID()

  init(store: TorrentIndexerStore, engine: TorrentSearchEngine? = nil) {
    self.store = store
    self.engine = engine ?? TorrentSearchEngine(secrets: store.secrets)
  }

  /// Merged, filtered and sorted results as shown in the list.
  var visible: [TorrentSearchResult] { filter.apply(collected) }
  var failedStatuses: [IndexerStatus] {
    statuses.filter { if case .failed = $0.state { true } else { false } }
  }
  var isSearching: Bool { phase == .searching }
  /// Last known health per indexer, for the Settings list.
  func state(for id: UUID) -> IndexerRunState? { statuses.first { $0.indexerID == id }?.state }

  // MARK: Actions

  func search() {
    let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard text.count >= 2 else {
      notice = "Type at least two characters, then press Return."
      return
    }
    guard text.count <= 200 else {
      notice = "Keep the search under 200 characters."
      return
    }
    notice = nil
    let indexers = store.enabled
    guard !indexers.isEmpty else {
      notice = "Turn on at least one indexer to search."
      return
    }
    cancel()
    searchedQuery = text
    collected = []
    statuses = indexers.map { IndexerStatus(indexerID: $0.id, name: $0.name, state: .pending) }
    begin(indexers, query: text)
  }

  /// Runs only the indexers that failed last time and merges their results into the list.
  func retryFailed() {
    let failedIDs = Set(failedStatuses.map(\.indexerID))
    let indexers = store.indexers.filter { failedIDs.contains($0.id) && $0.enabled }
    guard !indexers.isEmpty, !searchedQuery.isEmpty else { return }
    cancel()
    begin(indexers, query: searchedQuery)
  }

  func cancel() {
    generation = UUID()
    task?.cancel()
    task = nil
    for index in statuses.indices where statuses[index].state == .searching {
      statuses[index].state = .pending
    }
    if phase == .searching { phase = collected.isEmpty && statuses.isEmpty ? .idle : .done }
  }

  /// Waits for the running search. Used by tests.
  func waitForSearch() async { await task?.value }

  func resetFilters() {
    filter.qualities = []
    filter.minSeeders = 1
  }

  // MARK: Private

  private func begin(_ indexers: [TorrentIndexer], query: String) {
    let token = UUID()
    generation = token
    phase = .searching
    for indexer in indexers {
      setState(.searching, for: indexer.id, name: indexer.name)
    }
    let engine = engine
    task = Task { [weak self] in
      await engine.run(query: query, indexers: indexers) { [weak self] id, outcome in
        guard let self, self.generation == token else { return }
        switch outcome {
        case .success(let results):
          self.collected = TorrentSearchDeduper.merge(self.collected + results)
          self.setState(.finished(count: results.count), for: id)
        case .failure(let failure):
          self.setState(.failed(failure), for: id)
        }
      }
      guard let self, self.generation == token else { return }
      self.phase = .done
      self.task = nil
    }
  }

  private func setState(_ state: IndexerRunState, for id: UUID, name: String? = nil) {
    if let index = statuses.firstIndex(where: { $0.indexerID == id }) {
      statuses[index].state = state
    } else if let name {
      statuses.append(IndexerStatus(indexerID: id, name: name, state: state))
    }
  }
}

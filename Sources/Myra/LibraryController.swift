import Combine
import Foundation
import OSLog

/// Observable refresh lifecycle. Completion is distinct from cancellation and partial failure.
enum IndexRefreshState: Equatable {
  case notScanned, noSources, refreshing, paused, completed, partial, failed, cancelled

  var title: String {
    switch self {
    case .notScanned: "Library not yet scanned"
    case .noSources: "No library sources"
    case .refreshing: "Indexing library"
    case .paused: "Indexing paused"
    case .completed: "Library refreshed"
    case .partial: "Refresh completed with issues"
    case .failed: "Refresh failed"
    case .cancelled: "Indexing cancelled"
    }
  }

  var symbol: String {
    switch self {
    case .refreshing: "arrow.triangle.2.circlepath"
    case .paused: "pause.circle"
    case .completed: "checkmark.circle"
    case .partial, .failed: "exclamationmark.triangle"
    case .cancelled: "stop.circle"
    case .notScanned, .noSources: "externaldrive"
    }
  }
}

@MainActor
final class LibraryController: ObservableObject {
  @Published private(set) var isRefreshing = false
  @Published var isPaused = false
  @Published var showIndexManagement = false
  @Published private(set) var folderRows: [IndexFolderRow] = []
  @Published var policies: IndexPolicies = {
    guard let data = UserDefaults.standard.data(forKey: "indexFolderPolicies"),
      let value = try? JSONDecoder().decode(IndexPolicies.self, from: data)
    else { return .init() }
    return value
  }()
  {
    didSet {
      if let data = try? JSONEncoder().encode(policies) {
        UserDefaults.standard.set(data, forKey: "indexFolderPolicies")
      }
    }
  }
  @Published private(set) var roots: [GlobalSearchRoot] = []
  func setRoots(_ roots: [GlobalSearchRoot]) { self.roots = roots }

  @Published private var lastOutcome: IndexRefreshState = .notScanned
  var refreshState: IndexRefreshState {
    if isRefreshing { return isPaused ? .paused : .refreshing }
    if roots.isEmpty { return .noSources }
    if errorMessage != nil { return .failed }
    return lastOutcome
  }
  var statusTitle: String { refreshState.title }
  var statusSymbol: String { refreshState.symbol }
  var hasIssues: Bool { refreshState == .partial || refreshState == .failed }
  var statusDetail: String {
    switch refreshState {
    case .refreshing, .paused:
      return
        "\(progress.foldersVisited.formatted()) folders · \(progress.matchesFound.formatted()) videos"
    case .cancelled: return "Saved results retained. Refresh to continue."
    case .partial: return "\(failures.count) source(s) with issues. Saved results retained."
    case .failed: return "Saved library retained. Check the source and retry."
    case .noSources: return "Add a source to build your library."
    case .notScanned: return "Refresh to index your sources."
    case .completed: return "Your saved library is available."
    }
  }

  func loadFolderRows() async {
    do { folderRows = try await database().folderRows(roots: roots) } catch {
      errorMessage = error.localizedDescription
    }
  }
  func setSchedule(_ schedule: IndexSchedule?, scope: IndexScope) {
    policies.overrides[scope.id] = schedule
  }
  func refreshSelected(_ scopes: [IndexScope], full: Bool = false) {
    refresh(roots: roots, manual: true, scopes: scopes, full: full)
  }
  func refreshDue() { refresh(roots: roots, manual: true, onlyIfDue: true) }

  @Published private(set) var progress = GlobalSearchProgress()
  @Published private(set) var failures: [GlobalSearchFailure] = []
  @Published private(set) var lastRefresh: Date?
  @Published var errorMessage: String?
  @Published var completionMessage: String?
  private(set) var index: LibraryIndex?
  private let directoryService: DirectoryService
  private var openTask: Task<LibraryIndex, Error>?
  private var refreshTask: Task<Void, Never>?
  private var refreshID = UUID()
  private var lastIndexNotification = Date.distantPast
  private var pendingIndexNotification: Task<Void, Never>?
  enum IndexingMode: String, CaseIterable {
    case balanced = "Balanced"
    case lowImpact = "Low Impact"
  }
  @Published var indexingMode: IndexingMode =
    IndexingMode(rawValue: UserDefaults.standard.string(forKey: "indexingMode") ?? "") ?? .balanced
  {
    didSet { UserDefaults.standard.set(indexingMode.rawValue, forKey: "indexingMode") }
  }
  nonisolated static func folderConcurrency(mode: IndexingMode, playing: Bool, lowPower: Bool)
    -> Int
  {
    mode == .lowImpact || playing || lowPower ? 1 : 2
  }
  var isPlaying: (() -> Bool)?
  private var lastProgressUpdate = Date.distantPast
  private let logger = Logger(subsystem: "Myra", category: "Indexing")
  var didUpdate: (() -> Void)?

  /// Coalesces catalogue reloads while making chunk commits visible during long scans.
  private func notifyIndexUpdated() {
    let delay = 750 - Int(Date.now.timeIntervalSince(lastIndexNotification) * 1000)
    if delay <= 0 {
      pendingIndexNotification?.cancel()
      pendingIndexNotification = nil
      lastIndexNotification = .now
      didUpdate?()
      return
    }
    guard pendingIndexNotification == nil else { return }
    pendingIndexNotification = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(delay))
      guard let self, !Task.isCancelled else { return }
      self.pendingIndexNotification = nil
      self.lastIndexNotification = .now
      self.didUpdate?()
    }
  }

  init(index: LibraryIndex? = nil, directoryService: DirectoryService = DirectoryService()) {
    self.index = index
    self.directoryService = directoryService
  }

  func database() async throws -> LibraryIndex {
    if let index { return index }
    if openTask == nil {
      openTask = Task.detached {
        let url = try AppPersistence.persistentStoreURL().deletingLastPathComponent()
          .appending(path: "LibraryIndex.sqlite")
        return try LibraryIndex(url: url)
      }
    }
    do {
      let opened = try await openTask!.value
      index = opened
      return opened
    } catch {
      openTask = nil
      throw error
    }
  }

  func refresh(
    roots: [GlobalSearchRoot], manual: Bool = false, onlyIfDue: Bool = false,
    scopes: [IndexScope]? = nil, full: Bool = false, prepare: (@MainActor () async -> Void)? = nil
  ) {
    self.roots = roots
    isPaused = false
    let previous = refreshTask
    previous?.cancel()
    refreshID = UUID()
    let id = refreshID
    isRefreshing = true
    progress = GlobalSearchProgress(sourcesTotal: roots.count)
    errorMessage = nil
    completionMessage = nil
    lastProgressUpdate = .distantPast
    refreshTask = Task(priority: .utility) { [weak self] in
      await previous?.value
      guard !Task.isCancelled, self?.refreshID == id else { return }
      if let prepare {
        // Cancelling an index refresh must not cancel the initial Home restore.
        let restore = Task { await prepare() }
        await restore.value
      }
      guard let self, !Task.isCancelled, refreshID == id else { return }
      var changed = false
      do {
        let index = try await database()
        try Task.checkCancellation()
        let previousRevision = try await index.revision()
        try await index.synchronizeSources(roots)
        changed = try await index.revision() != previousRevision
        lastRefresh = try await index.lastRefresh()
        folderRows = try await index.folderRows(roots: roots)
        try Task.checkCancellation()
        guard refreshID == id else { return }
        let selected: [IndexScope]
        if let scopes {
          selected = IndexScope.compact(scopes)
        } else if onlyIfDue {
          selected = IndexScope.compact(
            folderRows.filter { policies.schedule(for: $0.scope).isDue($0.checked) }.map(\.scope))
        } else {
          selected = roots.map { IndexScope(root: $0, folder: $0.url) }
        }
        if selected.isEmpty {
          isRefreshing = false
          refreshTask = nil
          lastOutcome = roots.isEmpty ? .noSources : (failures.isEmpty ? .completed : .partial)
          if manual {
            completionMessage =
              roots.isEmpty
              ? "Add a source before refreshing the library."
              : "No folders are due for a scheduled refresh. Use Refresh Library to check now."
          }
          if try await index.revision() != previousRevision { notifyIndexUpdated() }
          return
        }
        failures = []
        progress = GlobalSearchProgress(sourcesTotal: Set(selected.map { $0.root.id }).count)
        let indexer = LibraryIndexer(directoryService: directoryService)
        let started = Date.now
        let snapshot = try await indexer.refresh(
          roots: roots, index: index, generation: id, scopes: selected, policies: policies,
          automatic: onlyIfDue, full: full,
          concurrencyLimit: { [weak self] in
            while await MainActor.run(body: { self?.isPaused == true }) {
              if Task.isCancelled { return 1 }
              try? await Task.sleep(for: .milliseconds(200))
            }
            return await MainActor.run {
              guard let self else { return 1 }
              return Self.folderConcurrency(
                mode: self.indexingMode, playing: self.isPlaying?() == true,
                lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
            }
          },
          onCommit: { [weak self] in
            // A committed chunk belongs to the published index even if its scan was cancelled.
            await MainActor.run { self?.notifyIndexUpdated() }
          }
        ) {
          [weak self] snapshot in
          await MainActor.run {
            guard let self, self.refreshID == id else { return }
            guard Date.now.timeIntervalSince(self.lastProgressUpdate) >= 0.5 else { return }
            self.lastProgressUpdate = .now
            if self.progress != snapshot.progress { self.progress = snapshot.progress }
            if self.failures != snapshot.failures { self.failures = snapshot.failures }
          }
        }
        try Task.checkCancellation()
        guard refreshID == id else { return }
        logger.info(
          "Index completed: \(snapshot.progress.matchesFound) videos, \(snapshot.progress.foldersVisited) folders, \(Date.now.timeIntervalSince(started)) seconds"
        )
        changed = try await index.revision() != previousRevision
        progress = snapshot.progress
        failures = snapshot.failures
        lastOutcome =
          failures.isEmpty
          ? .completed
          : (snapshot.progress.foldersVisited > 0 ? .partial : .failed)
        lastRefresh = try await index.lastRefresh()
        if manual {
          let suffix =
            failures.isEmpty
            ? ""
            : " Issues: \(failures.map(\.summary).joined(separator: "; ")). Existing records for those paths were retained."
          completionMessage = await indexer.summary.text + suffix
        }
      } catch is CancellationError {
        // Full chunks already committed to the main index remain visible.
        if refreshID == id { lastOutcome = .cancelled }
      } catch {
        guard refreshID == id else { return }
        errorMessage = error.localizedDescription
        lastOutcome = .failed
        if manual { completionMessage = "Refresh failed: \(error.localizedDescription)" }
      }
      guard refreshID == id else { return }
      isRefreshing = false
      refreshTask = nil
      isPaused = false
      await loadFolderRows()
      if changed { notifyIndexUpdated() }
    }
  }

  func cancel() {
    guard isRefreshing else { return }
    lastOutcome = .cancelled
    completionMessage = nil
    let previous = refreshTask
    previous?.cancel()
    refreshID = UUID()
    isRefreshing = false
    isPaused = false
    let id = refreshID
    Task { [weak self] in
      await previous?.value
      guard let self, self.refreshID == id else { return }
      self.refreshTask = nil
      await self.loadFolderRows()
      // Any committed chunks already scheduled their catalogue reload notification.
    }
  }
}

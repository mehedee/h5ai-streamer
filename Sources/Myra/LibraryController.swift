import Combine
import Foundation
import OSLog

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
  func setRoots(_ roots: [GlobalSearchRoot]) {
    self.roots = roots
    if !isRefreshing { sources = roots.map { existing(for: $0) } }
    Task { await loadSourceStatuses() }
  }

  // MARK: - Observable indexing state

  @Published private var lastOutcome: IndexRefreshState = .notScanned
  /// Lifecycle of the current or most recent run.
  var refreshState: IndexRefreshState {
    if isRefreshing { return isPaused ? .paused : .refreshing }
    if roots.isEmpty { return .noSources }
    if errorMessage != nil { return .failed }
    return lastOutcome
  }
  var isCancelled: Bool { refreshState == .cancelled }
  var statusTitle: String { refreshState.title }
  var statusSymbol: String { refreshState.symbol }
  var hasIssues: Bool { refreshState == .partial || refreshState == .failed }
  var statusDetail: String {
    switch refreshState {
    case .refreshing, .paused:
      return
        "\(progress.foldersVisited.formatted()) folders · \(progress.matchesFound.formatted()) videos"
    case .cancelled: return "Saved results retained. Refresh to continue."
    case .partial:
      let count = max(failures.count, sources.filter { $0.state == .failed }.count)
      return "\(count) source(s) with issues. Saved results retained."
    case .failed: return "Saved library retained. Check the source and retry."
    case .noSources: return "Add a source to build your library."
    case .notScanned: return "Refresh to index your sources."
    case .completed: return "Your saved library is available."
    }
  }

  /// One entry per source, in source order: state, videos, last scan, last error, latency and the
  /// time of the next automatic retry. Live during a run, persisted between runs.
  @Published private(set) var sources: [SourceIndexStatus] = []
  /// Current source (1-based), source count, videos found so far and the overall fraction.
  @Published private(set) var indexing = IndexingProgress()
  /// Videos in the saved library, kept current while indexing commits.
  @Published private(set) var libraryTotal = 0

  @Published private(set) var progress = GlobalSearchProgress()
  @Published private(set) var failures: [GlobalSearchFailure] = []
  @Published private(set) var lastRefresh: Date?
  @Published var errorMessage: String?
  @Published var completionMessage: String?

  /// Pauses a running index. Requests already in flight finish first.
  func pause() { if isRefreshing { isPaused = true } }
  func resume() { isPaused = false }

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
  /// Scheduled refresh: only folders whose Daily or Weekly schedule is due.
  func refreshDue() { refresh(roots: roots, manual: true, onlyIfDue: true) }

  private(set) var index: LibraryIndex?
  private let directoryService: DirectoryService
  private let retryPolicy: IndexRetryPolicy
  private let retryDelay: Duration
  /// Automatic retry of failing sources with backoff. Tests may switch it off.
  var automaticRetry: Bool
  private var openTask: Task<LibraryIndex, Error>?
  private var refreshTask: Task<Void, Never>?
  private var retryTask: Task<Void, Never>?
  private var refreshID = UUID()
  private var lastIndexNotification = Date.distantPast
  private var pendingIndexNotification: Task<Void, Never>?
  private var runSourceIDs: [UUID] = []
  private var expectedFolders: [UUID: Int] = [:]
  private var lastSourceUpdate = Date.distantPast
  private var pendingSourceUpdates: [UUID: SourceRunUpdate] = [:]
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
    Task { await refreshLibraryTotal() }
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

  init(
    index: LibraryIndex? = nil, directoryService: DirectoryService = DirectoryService(),
    retryPolicy: IndexRetryPolicy = IndexRetryPolicy(), retryDelay: Duration = .milliseconds(500),
    automaticRetry: Bool = true
  ) {
    self.index = index
    self.directoryService = directoryService
    self.retryPolicy = retryPolicy
    self.retryDelay = retryDelay
    self.automaticRetry = automaticRetry
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

  // MARK: - Source statuses

  private func existing(for root: GlobalSearchRoot) -> SourceIndexStatus {
    sources.first { $0.id == root.id } ?? SourceIndexStatus(id: root.id, name: root.name)
  }

  /// Reads saved scan dates, counts and health, so the pages show real state before any run.
  func loadSourceStatuses() async {
    guard let index = try? await database() else { return }
    let health = (try? await index.sourceHealth()) ?? [:]
    let scans = (try? await index.sourceScanDates()) ?? [:]
    let counts = (try? await index.videoCounts()) ?? [:]
    libraryTotal = counts.values.reduce(0, +)
    guard !isRefreshing else { return }
    sources = roots.map { root in
      var status = SourceIndexStatus(id: root.id, name: root.name)
      let record = health[root.id]
      status.videosFound = counts[root.id] ?? 0
      status.lastScan = scans[root.id]
      status.lastSuccess = record?.lastSuccess ?? scans[root.id]
      status.lastProblem = record?.lastProblem
      status.lastError = record?.lastError
      status.latency = record?.latency
      status.consecutiveFailures = record?.consecutiveFailures ?? 0
      status.nextRetry = record?.nextRetry
      if (record?.consecutiveFailures ?? 0) > 0 {
        status.state = .failed
      } else if scans[root.id] != nil || record?.lastSuccess != nil {
        status.state = .ok
      } else {
        status.state = .notScanned
      }
      return status
    }
  }

  private func refreshLibraryTotal() async {
    if let count = try? await index?.videoCount(), count != libraryTotal { libraryTotal = count }
  }

  private func applySourceUpdate(_ update: SourceRunUpdate) {
    guard let offset = sources.firstIndex(where: { $0.id == update.sourceID }) else { return }
    var status = sources[offset]
    status.state = update.state
    if update.state != .queued {
      status.videosFound = update.videosFound
      status.foldersVisited = update.foldersVisited
    }
    if let health = update.health {
      status.lastSuccess = health.lastSuccess
      status.lastProblem = health.lastProblem
      status.lastError = health.lastError
      status.latency = health.latency
      status.consecutiveFailures = health.consecutiveFailures
      status.nextRetry = health.nextRetry
      if update.state == .ok { status.lastScan = health.lastSuccess }
    }
    if sources[offset] != status { sources[offset] = status }
    recomputeIndexingProgress()
  }

  /// Progress ticks are throttled; state changes (queued, indexing, ok, failed) apply at once.
  private func receive(_ update: SourceRunUpdate, run id: UUID) {
    guard refreshID == id else { return }
    let alreadyIndexing = sources.first { $0.id == update.sourceID }?.state == .indexing
    if update.state == .indexing, alreadyIndexing {
      pendingSourceUpdates[update.sourceID] = update
      guard Date.now.timeIntervalSince(lastSourceUpdate) >= 0.25 else { return }
      lastSourceUpdate = .now
      for pending in pendingSourceUpdates.values { applySourceUpdate(pending) }
      pendingSourceUpdates.removeAll()
    } else {
      pendingSourceUpdates[update.sourceID] = nil
      applySourceUpdate(update)
    }
  }

  private func recomputeIndexingProgress() {
    let run = sources.filter { runSourceIDs.contains($0.id) }
    guard !run.isEmpty else {
      if indexing != IndexingProgress() { indexing = IndexingProgress() }
      return
    }
    var fractions = 0.0
    var finished = 0
    for source in run {
      switch source.state {
      case .ok, .failed:
        fractions += 1
        finished += 1
      case .indexing:
        let expected = Double(expectedFolders[source.id] ?? 0)
        let visited = Double(source.foldersVisited)
        fractions +=
          expected > 0
          ? min(0.99, visited / max(expected, visited + 1))
          : 1 - 1 / (1 + visited / 40)
      case .queued, .notScanned: break
      }
    }
    let current = run.firstIndex { $0.state == .indexing }.map { $0 + 1 } ?? min(finished + 1, run.count)
    let value = IndexingProgress(
      currentSource: current, sourceCount: run.count,
      videosFound: run.reduce(0) { $0 + $1.videosFound },
      foldersVisited: run.reduce(0) { $0 + $1.foldersVisited },
      fraction: min(1, fractions / Double(run.count)))
    if indexing != value { indexing = value }
  }

  // MARK: - Refresh

  func refresh(
    roots: [GlobalSearchRoot], manual: Bool = false, onlyIfDue: Bool = false,
    scopes: [IndexScope]? = nil, full: Bool = false, prepare: (@MainActor () async -> Void)? = nil
  ) {
    self.roots = roots
    isPaused = false
    retryTask?.cancel()
    retryTask = nil
    let previous = refreshTask
    previous?.cancel()
    refreshID = UUID()
    let id = refreshID
    isRefreshing = true
    progress = GlobalSearchProgress(sourcesTotal: roots.count)
    errorMessage = nil
    completionMessage = nil
    lastProgressUpdate = .distantPast
    lastSourceUpdate = .distantPast
    pendingSourceUpdates = [:]
    runSourceIDs = []
    indexing = IndexingProgress(sourceCount: roots.count)
    sources = roots.map { existing(for: $0) }
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
      let runMark = MyraPerformance.begin(PerfMark.indexRun)
      defer { runMark.end("manual=\(manual) onlyIfDue=\(onlyIfDue)") }
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
          indexing = IndexingProgress()
          if manual {
            completionMessage =
              roots.isEmpty
              ? "Add a source before refreshing the library."
              : "No folders are due for a scheduled refresh. Use Refresh Library to check now."
          }
          if try await index.revision() != previousRevision { notifyIndexUpdated() }
          await loadSourceStatuses()
          scheduleRetries()
          return
        }
        failures = []
        var seen = Set<UUID>()
        runSourceIDs = selected.map(\.root.id).filter { seen.insert($0).inserted }
        var perRoot: [UUID: Int] = [:]
        for row in folderRows { perRoot[row.scope.root.id, default: 0] += 1 }
        expectedFolders = perRoot
        progress = GlobalSearchProgress(sourcesTotal: runSourceIDs.count)
        indexing = IndexingProgress(sourceCount: runSourceIDs.count)
        for sourceID in runSourceIDs { applySourceUpdate(SourceRunUpdate(sourceID: sourceID, state: .queued)) }
        await refreshLibraryTotal()
        let indexer = LibraryIndexer(
          directoryService: directoryService, retryPolicy: retryPolicy, retryDelay: retryDelay)
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
          },
          sourceUpdate: { [weak self] update in
            await MainActor.run { self?.receive(update, run: id) }
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
      // Settle sources that never reported (cancelled or aborted) before the run is closed.
      pendingSourceUpdates.removeAll()
      isRefreshing = false
      refreshTask = nil
      isPaused = false
      indexing = IndexingProgress()
      await loadFolderRows()
      await loadSourceStatuses()
      if lastOutcome == .completed, sources.contains(where: { $0.state == .failed }) {
        lastOutcome = .partial
      }
      if changed { notifyIndexUpdated() }
      scheduleRetries()
    }
  }

  func cancel() {
    guard isRefreshing else { return }
    lastOutcome = .cancelled
    completionMessage = nil
    retryTask?.cancel()
    retryTask = nil
    let previous = refreshTask
    previous?.cancel()
    refreshID = UUID()
    isRefreshing = false
    isPaused = false
    indexing = IndexingProgress()
    pendingSourceUpdates.removeAll()
    let id = refreshID
    Task { [weak self] in
      await previous?.value
      guard let self, self.refreshID == id else { return }
      self.refreshTask = nil
      await self.loadFolderRows()
      await self.loadSourceStatuses()
      // Any committed chunks already scheduled their catalogue reload notification.
    }
  }

  // MARK: - Automatic retry

  /// Retries failing sources once their backoff has elapsed. A failing source never delays others:
  /// the retry is its own small run.
  private func scheduleRetries() {
    retryTask?.cancel()
    retryTask = nil
    guard automaticRetry, !roots.isEmpty else { return }
    let due = sources.filter { $0.state == .failed }.compactMap(\.nextRetry)
    guard let earliest = due.min() else { return }
    let wait = max(0, earliest.timeIntervalSinceNow)
    retryTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(wait))
      guard !Task.isCancelled, let self else { return }
      self.runDueRetries()
    }
  }

  private func runDueRetries() {
    retryTask = nil
    guard !isRefreshing else { return }
    let now = Date.now
    let ids = Set(
      sources.filter { $0.state == .failed && ($0.nextRetry ?? .distantFuture) <= now }.map(\.id))
    let scopes = roots.filter { ids.contains($0.id) }.map { IndexScope(root: $0, folder: $0.url) }
    guard !scopes.isEmpty else {
      scheduleRetries()
      return
    }
    logger.info("Retrying \(scopes.count) failing source(s)")
    refresh(roots: roots, manual: false, scopes: scopes)
  }
}

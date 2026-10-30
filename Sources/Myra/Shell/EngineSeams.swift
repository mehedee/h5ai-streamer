import Foundation

/// The only place where the shell's UI reads engine state that the data workstream is changing.
///
/// Each seam has a default bound to the properties that exist today, so the UI compiles and shows
/// real values now. When the engine adds richer state (per-source health, videos found, a library
/// total from the catalogue database, facet lists with counts), bind these and nothing else:
///
/// - `IndexingSnapshot.make(...)`: the header indicator, its popover and the sidebar footer.
/// - `IndexingActions`: Pause, Resume, Cancel and Refresh now.
/// - `LibraryFacetProviding`: Genre, Language, Year, Quality and Source options with counts.
///
/// Views never read `LibraryController` progress or the catalogue count directly for these.
enum EngineSeams {}

// MARK: - Indexing state

/// One source's row in the indexing popover.
struct IndexingSourceRow: Identifiable, Equatable, Sendable {
  enum State: Equatable, Sendable {
    case indexed
    /// A fraction from 0 to 1 when the engine reports per-source progress, otherwise nil.
    case indexing(Double?)
    case queued
    case unreachable
  }

  var id: UUID
  var name: String
  /// For example "nas.local". Empty when unknown.
  var host: String
  var state: State
  /// Titles the source contributes, when the engine reports it.
  var titles: Int?
  var lastScan: Date?
}

/// What the header indicator, popover and footer show. Plain values, so they are easy to test.
struct IndexingSnapshot: Equatable, Sendable {
  var isRunning = false
  var isPaused = false
  /// The source being scanned, 1-based, and the number of sources in this run.
  var currentSource = 0
  var sourceCount = 0
  /// Videos found during the current run.
  var videosFound = 0
  /// Titles in the library.
  var libraryTotal = 0
  var lastScan: Date?
  var sources: [IndexingSourceRow] = []
  /// The engine's overall fraction (0...1) across all sources; nil falls back to source position.
  var overallFraction: Double?

  /// The indicator's label: "Up to date", "Indexing 2/3" or "Paused".
  var label: String {
    guard isRunning else { return "Up to date" }
    if isPaused { return "Paused" }
    return "Indexing \(min(max(currentSource, 1), max(sourceCount, 1)))/\(max(sourceCount, 1))"
  }

  /// The right-aligned count: videos found while running, the library total when idle.
  var count: Int { isRunning ? videosFound : libraryTotal }

  /// Reading of the run for the sidebar footer, from 0 to 1.
  var fraction: Double {
    guard isRunning, sourceCount > 0 else { return 0 }
    if let overallFraction { return min(1, max(0, overallFraction)) }
    return min(1, Double(max(currentSource - 1, 0)) / Double(sourceCount))
  }
}

/// The commands the indexing popover and footer can issue.
@MainActor
struct IndexingActions {
  var pause: () -> Void
  var resume: () -> Void
  var cancel: () -> Void
  var refreshNow: () -> Void
}

extension IndexingSnapshot {
  /// Bound to the engine: running/paused, source n of m, videos found, the overall fraction, the
  /// library total, and one row per source with its state, titles and last scan. Before the engine
  /// has reported sources (for example in a bare controller) it falls back to the configured ones.
  @MainActor
  static func make(
    library: LibraryController, catalogueCount: Int, categories: [Category]
  ) -> IndexingSnapshot {
    let live = Dictionary(library.sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let rows = categories.map { category -> IndexingSourceRow in
      let state: IndexingSourceRow.State
      var titles: Int?
      var lastScan = library.lastRefresh
      if let status = live[category.id] {
        switch status.state {
        case .ok: state = .indexed
        case .indexing: state = .indexing(nil)
        case .queued, .notScanned: state = .queued
        case .failed: state = .unreachable
        }
        titles = status.videosFound
        lastScan = status.lastScan ?? status.lastSuccess
      } else if library.failures.contains(where: { $0.categoryID == category.id }) {
        state = .unreachable
      } else {
        state = .indexed
      }
      return IndexingSourceRow(
        id: category.id, name: category.name,
        host: URL(string: category.rootURLString)?.host ?? "", state: state, titles: titles,
        lastScan: lastScan)
    }
    let run = library.indexing
    let count = library.isRefreshing ? max(run.sourceCount, 1) : max(run.sourceCount, categories.count)
    return IndexingSnapshot(
      isRunning: library.isRefreshing, isPaused: library.isPaused,
      currentSource: run.currentSource, sourceCount: count,
      videosFound: run.videosFound, libraryTotal: catalogueCount,
      lastScan: library.lastRefresh, sources: rows,
      overallFraction: library.isRefreshing ? run.fraction : nil)
  }
}

extension IndexingActions {
  /// Pause, Resume and Cancel drive the running index; Refresh now is the explicit refresh that
  /// always checks the sources (never the schedule-gated one).
  @MainActor
  static func make(library: LibraryController, refresh: @escaping () -> Void) -> IndexingActions {
    IndexingActions(
      pause: { library.pause() }, resume: { library.resume() },
      cancel: { library.cancel() }, refreshNow: refresh)
  }
}

// MARK: - Facet options

/// One selectable value in a filter popover, with the number of titles that carry it.
struct FilterOption: Identifiable, Equatable, Sendable {
  var value: String
  var count: Int
  var id: String { value }
}

/// The five facet lists behind the filter bar popovers.
struct LibraryFilterOptions: Equatable, Sendable {
  var genres: [FilterOption] = []
  var languages: [FilterOption] = []
  var years: [FilterOption] = []
  var qualities: [FilterOption] = []
  var sources: [FilterOption] = []
}

/// Supplies facet options with counts for a set of titles. The default derives them from the
/// loaded catalogue; the data workstream can answer from the database instead.
protocol LibraryFacetProviding: Sendable {
  func options(for titles: [EntertainmentTitle]) -> LibraryFilterOptions
}

/// Derives the options with the engine's title traits: TMDB metadata when present, otherwise the
/// folders and file names a title lives in, so filters work on a library with no metadata.
struct CatalogueFacetProvider: LibraryFacetProviding {
  func options(for titles: [EntertainmentTitle]) -> LibraryFilterOptions {
    HomeCatalogueIndex.options(traits: TitleFacetDerivation.traits(for: titles), include: nil)
  }
}

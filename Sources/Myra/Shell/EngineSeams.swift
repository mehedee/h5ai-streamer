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
  /// Default binding to today's engine: `LibraryController` progress, the catalogue count, the
  /// configured sources and the failures of the last run.
  @MainActor
  static func make(
    library: LibraryController, catalogueCount: Int, categories: [Category]
  ) -> IndexingSnapshot {
    let failed = Set(library.failures.map(\.categoryID))
    let total = max(library.progress.sourcesTotal, categories.count)
    let completed = library.progress.sourcesCompleted
    let rows = categories.enumerated().map { offset, category -> IndexingSourceRow in
      let state: IndexingSourceRow.State
      if failed.contains(category.id) {
        state = .unreachable
      } else if library.isRefreshing {
        state = offset < completed ? .indexed : (offset == completed ? .indexing(nil) : .queued)
      } else {
        state = .indexed
      }
      return IndexingSourceRow(
        id: category.id, name: category.name,
        host: URL(string: category.rootURLString)?.host ?? "", state: state, titles: nil,
        lastScan: library.lastRefresh)
    }
    return IndexingSnapshot(
      isRunning: library.isRefreshing, isPaused: library.isPaused,
      currentSource: min(completed + 1, max(total, 1)), sourceCount: total,
      videosFound: library.progress.matchesFound, libraryTotal: catalogueCount,
      lastScan: library.lastRefresh, sources: rows)
  }
}

extension IndexingActions {
  @MainActor
  static func make(library: LibraryController, refresh: @escaping () -> Void) -> IndexingActions {
    IndexingActions(
      pause: { library.isPaused = true }, resume: { library.isPaused = false },
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

struct CatalogueFacetProvider: LibraryFacetProviding {
  func options(for titles: [EntertainmentTitle]) -> LibraryFilterOptions {
    var genres: [String: Int] = [:]
    var languages: [String: Int] = [:]
    var years: [String: Int] = [:]
    var qualities: [String: Int] = [:]
    var sources: [String: Int] = [:]
    for title in titles {
      for genre in Set(title.metadata?.genres ?? []) { genres[genre, default: 0] += 1 }
      if let language = title.metadata?.language, !language.isEmpty {
        languages[language, default: 0] += 1
      }
      if let year = title.year { years[year, default: 0] += 1 }
      for quality in LibraryFilter.resolutions(of: title) { qualities[quality, default: 0] += 1 }
      for source in Set(title.versions.map(\.media.categoryName)) { sources[source, default: 0] += 1 }
    }
    /// Most titles first, then alphabetical.
    func list(_ values: [String: Int]) -> [FilterOption] {
      values.map { FilterOption(value: $0.key, count: $0.value) }
        .sorted {
          $0.count != $1.count
            ? $0.count > $1.count : $0.value.localizedStandardCompare($1.value) == .orderedAscending
        }
    }
    return LibraryFilterOptions(
      genres: list(genres), languages: list(languages),
      years: years.map { FilterOption(value: $0.key, count: $0.value) }
        .sorted { $0.value > $1.value },
      qualities: LibraryFilter.resolutionOrder.compactMap { name in
        qualities[name].map { FilterOption(value: name, count: $0) }
      },
      sources: list(sources))
  }
}

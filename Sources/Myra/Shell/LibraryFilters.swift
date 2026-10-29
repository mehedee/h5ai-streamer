import Combine
import Foundation

/// The kind segment of the filter bar.
enum LibraryKind: String, CaseIterable, Identifiable, Sendable {
  case all, movies, series

  var id: String { rawValue }

  var title: String {
    switch self {
    case .all: "All"
    case .movies: "Movies"
    case .series: "Series"
    }
  }
}

/// The five multi-select facets of the filter bar.
enum LibraryFacet: String, CaseIterable, Identifiable, Sendable {
  case genre, language, year, quality, source

  var id: String { rawValue }

  var title: String {
    switch self {
    case .genre: "Genre"
    case .language: "Language"
    case .year: "Year"
    case .quality: "Quality"
    case .source: "Source"
    }
  }
}

/// Helpers shared by the facet lists and the filter predicate.
enum LibraryFilter {
  /// Resolution labels from the highest to the lowest, as shown in the Quality popover.
  static let resolutionOrder = ["2160p", "1080p", "720p", "480p"]

  /// The resolutions among a title's versions, read from the file names ("4K" counts as 2160p).
  static func resolutions(of title: EntertainmentTitle) -> Set<String> {
    var found = Set<String>()
    for version in title.versions {
      let name = version.media.entry.name
      for resolution in resolutionOrder where name.localizedCaseInsensitiveContains(resolution) {
        found.insert(resolution)
      }
      if name.localizedCaseInsensitiveContains("4K") { found.insert("2160p") }
    }
    return found
  }

  /// "en" reads as "English" in the Language popover. Unknown codes are shown as they are.
  static func displayName(language code: String) -> String {
    guard code.count <= 3, let name = Locale.current.localizedString(forLanguageCode: code),
      name != code
    else { return code }
    return name.localizedCapitalized
  }
}

/// What the filter bar has selected. One value drives Home, the category pages and the facet counts,
/// so shelves and filters always agree.
struct LibraryFilterSelection: Hashable, Sendable {
  var kind: LibraryKind = .all
  var genres: Set<String> = []
  var languages: Set<String> = []
  var years: Set<String> = []
  var qualities: Set<String> = []
  var sources: Set<String> = []
  var hideWatched = false

  /// The number shown on "Clear": every selected value plus the kind and Hide watched.
  var activeCount: Int {
    genres.count + languages.count + years.count + qualities.count + sources.count
      + (hideWatched ? 1 : 0) + (kind == .all ? 0 : 1)
  }

  var isActive: Bool { activeCount > 0 }

  func values(for facet: LibraryFacet) -> Set<String> {
    switch facet {
    case .genre: genres
    case .language: languages
    case .year: years
    case .quality: qualities
    case .source: sources
    }
  }

  mutating func setValues(_ values: Set<String>, for facet: LibraryFacet) {
    switch facet {
    case .genre: genres = values
    case .language: languages = values
    case .year: years = values
    case .quality: qualities = values
    case .source: sources = values
    }
  }

  mutating func toggle(_ value: String, in facet: LibraryFacet) {
    var current = values(for: facet)
    if !current.insert(value).inserted { current.remove(value) }
    setValues(current, for: facet)
  }

  /// A title passes when it satisfies every active facet; within a facet any selected value is enough.
  func matches(_ title: EntertainmentTitle, watched: Set<String>) -> Bool {
    switch kind {
    case .all: break
    case .movies: if title.kind != .movie { return false }
    case .series: if title.kind != .series { return false }
    }
    if hideWatched && watched.contains(title.id) { return false }
    if !genres.isEmpty, genres.isDisjoint(with: title.metadata?.genres ?? []) { return false }
    if !languages.isEmpty, !languages.contains(title.metadata?.language ?? "") { return false }
    if !years.isEmpty {
      let year = title.year ?? title.metadata?.releaseDate.map { String($0.prefix(4)) }
      guard let year, years.contains(year) else { return false }
    }
    if !qualities.isEmpty, qualities.isDisjoint(with: LibraryFilter.resolutions(of: title)) {
      return false
    }
    if !sources.isEmpty,
      sources.isDisjoint(with: Set(title.versions.map(\.media.categoryName)))
    {
      return false
    }
    return true
  }
}

/// The shell-owned filter state shared by Home and the See All pages.
@MainActor
final class LibraryFilterModel: ObservableObject {
  @Published var selection = LibraryFilterSelection()

  func clear() { selection = LibraryFilterSelection() }
}

import Foundation

/// Builds automatic Home shelves from the library index after each refresh.
///
/// The builder is pure: it reads titles and optional OMDb records and performs no network calls.
enum HomeCategoryBuilder {
  /// Shelves that meet `HomeCategoryRules.minimumTitleCount`, in the default order.
  /// Titles in each shelf are sorted by rating (highest first), then name, then id.
  static func categories(
    for titles: [EntertainmentTitle], movies: [String: MovieMetadata] = [:]
  ) -> [HomeCategory] {
    var buckets: [HomeCategoryKind: [Int]] = [:]
    for (index, title) in titles.enumerated() {
      let assignment = HomeCategoryClassifier.classify(title, movie: movies[title.id])
      if let primary = assignment.primary { buckets[primary, default: []].append(index) }
      for shelf in assignment.genreShelves { buckets[shelf, default: []].append(index) }
    }
    var result: [HomeCategory] = []
    for kind in HomeCategoryKind.allCases {
      guard let indices = buckets[kind], indices.count >= HomeCategoryRules.minimumTitleCount
      else { continue }
      let keyed = indices.map { SortKey(title: titles[$0]) }.sorted()
      result.append(HomeCategory(kind: kind, titleIDs: keyed.map(\.id)))
    }
    return result
  }

  /// The shelves the Home screen should show, after the user's preferences are applied.
  /// Hidden shelves are included with `isHidden` set, so a settings screen can restore them.
  static func arranged(
    for titles: [EntertainmentTitle],
    movies: [String: MovieMetadata] = [:],
    preferences: HomeCategoryPreferences
  ) -> [ArrangedHomeCategory] {
    preferences.arrange(categories(for: titles, movies: movies))
  }

  /// Sort key for a title on a shelf: rating descending, then name, then id.
  private struct SortKey: Comparable {
    let rating: Double
    let folded: String
    let name: String
    let id: String

    init(title: EntertainmentTitle) {
      rating = title.metadata?.rating ?? 0
      name = title.displayName
      folded = name.lowercased()
      id = title.id
    }

    static func < (lhs: SortKey, rhs: SortKey) -> Bool {
      if lhs.rating != rhs.rating { return lhs.rating > rhs.rating }
      if lhs.folded != rhs.folded { return lhs.folded < rhs.folded }
      if lhs.name != rhs.name { return lhs.name < rhs.name }
      return lhs.id < rhs.id
    }

    static func == (lhs: SortKey, rhs: SortKey) -> Bool {
      !(lhs < rhs) && !(rhs < lhs)
    }
  }
}

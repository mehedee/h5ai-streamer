import Foundation

/// Built-in automatic Home shelves. The raw value is the stable category id stored in preferences.
enum HomeCategoryKind: String, CaseIterable, Codable, Sendable, Identifiable {
  case englishMovies = "english-movies"
  case hindiMovies = "hindi-movies"
  case anime
  case tvSeries = "tv-series"
  case koreanSeries = "korean-series"
  case documentaries
  case kidsAndFamily = "kids-and-family"

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .englishMovies: "English Movies"
    case .hindiMovies: "Hindi Movies"
    case .anime: "Anime"
    case .tvSeries: "TV Series"
    case .koreanSeries: "Korean Series"
    case .documentaries: "Documentaries"
    case .kidsAndFamily: "Kids and Family"
    }
  }

  /// Plain-language description of how titles join this shelf, shown beside the shelf in settings.
  var rule: String {
    switch self {
    case .englishMovies:
      "Movies whose TMDB or OMDb original language is English. Folder or file names are used only when neither has a language."
    case .hindiMovies:
      "Movies whose TMDB or OMDb language is Hindi, or that sit in a Hindi or Bollywood folder, or carry a Hindi tag in the file name."
    case .anime:
      "Japanese animation by TMDB or OMDb, any title inside an Anime folder, or an Anime tag in the file name when nothing else is known."
    case .tvSeries:
      "Series that do not belong to Korean Series or Anime."
    case .koreanSeries:
      "Series whose TMDB or OMDb language is Korean, or that sit in a Korean or K-Drama folder, or carry a Korean or K-Drama tag."
    case .documentaries:
      "Titles with the Documentary genre by TMDB or OMDb, or in a Documentaries folder or tagged Documentary when no genre is known."
    case .kidsAndFamily:
      "Titles with the Kids or Family genre by TMDB or OMDb, or in a Kids or Family folder when no genre is known."
    }
  }

  /// Language shelves are mutually exclusive: a title joins at most one of them.
  /// Documentaries and Kids and Family are genre shelves and may overlap with a language shelf.
  var isPrimaryShelf: Bool {
    switch self {
    case .documentaries, .kidsAndFamily: false
    default: true
    }
  }
}

enum HomeCategoryRules {
  /// A category appears on Home only once it has at least this many titles.
  static let minimumTitleCount = 8
}

/// An automatic shelf with its titles already ordered for display.
struct HomeCategory: Identifiable, Equatable, Sendable {
  let kind: HomeCategoryKind
  /// `EntertainmentTitle.id` values, rating first, then name, then id.
  let titleIDs: [String]

  var id: String { kind.rawValue }
  var displayName: String { kind.displayName }
  var rule: String { kind.rule }
  var count: Int { titleIDs.count }
}

/// A category after the user's show, hide, reorder and pin choices are applied.
struct ArrangedHomeCategory: Identifiable, Equatable, Sendable {
  let category: HomeCategory
  let isPinned: Bool
  let isHidden: Bool

  var id: String { category.id }
}

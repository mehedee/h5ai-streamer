import Foundation

/// The evidence that decided a title's primary shelf, in the order the classifier trusts it.
enum HomeCategorySource: String, Sendable, Equatable {
  case tmdb, omdb, folder, fileName, type
}

/// Where one title belongs on automatic Home shelves. No network access and no AI are involved.
struct HomeCategoryAssignment: Equatable, Sendable {
  /// At most one language or type shelf (English Movies, Hindi Movies, Anime, TV Series, Korean Series).
  let primary: HomeCategoryKind?
  let primarySource: HomeCategorySource?
  /// Genre shelves (Documentaries, Kids and Family) that may apply alongside the primary shelf.
  let genreShelves: Set<HomeCategoryKind>
}

/// Classifies titles from evidence in this order: TMDB, then OMDb, then folder names, then file-name tags.
///
/// Rules:
/// - Anime is a title inside an Anime folder, or Japanese animation by TMDB or OMDb.
///   The Anime folder rule is deliberately checked before metadata, because the user organised the file.
/// - Language and type come from the first source that knows the language. That answer is final,
///   so TMDB beats a folder, and a folder beats a file-name tag.
/// - Genre shelves use the same rule. When TMDB or OMDb reports genres, that answer is final.
///   Otherwise a folder name, and then a file-name tag, can place the title.
enum HomeCategoryClassifier {
  static func classify(_ title: EntertainmentTitle, movie: MovieMetadata? = nil) -> HomeCategoryAssignment {
    let facts = Facts(title: title, movie: movie)
    let primary = primaryShelf(facts)
    var genres = Set<HomeCategoryKind>()
    if isDocumentary(facts) { genres.insert(.documentaries) }
    if isKidsAndFamily(facts) { genres.insert(.kidsAndFamily) }
    return HomeCategoryAssignment(
      primary: primary.kind, primarySource: primary.source, genreShelves: genres)
  }

  // MARK: - Primary shelf

  private static func primaryShelf(_ facts: Facts) -> (kind: HomeCategoryKind?, source: HomeCategorySource?) {
    if !facts.folderTokens.isDisjoint(with: Tags.animeFolder) { return (.anime, .folder) }
    if facts.tmdbLanguage == Language.japanese, facts.tmdbIsAnimated { return (.anime, .tmdb) }
    if facts.omdbIsJapan, facts.omdbIsAnimated { return (.anime, .omdb) }

    if let language = facts.tmdbLanguage { return (shelf(for: language, kind: facts.kind), .tmdb) }
    if let language = facts.omdbLanguage { return (shelf(for: language, kind: facts.kind), .omdb) }

    if facts.kind == .series, !facts.folderTokens.isDisjoint(with: Tags.tvFolder) {
      return (.tvSeries, .folder)
    }
    if let language = folderLanguage(facts.folderTokens),
      let kind = shelf(for: language, kind: facts.kind)
    {
      return (kind, .folder)
    }

    let fileTokens = facts.fileTokens
    if !fileTokens.isDisjoint(with: Tags.animeFile) { return (.anime, .fileName) }
    if let language = fileLanguage(fileTokens), let kind = shelf(for: language, kind: facts.kind) {
      return (kind, .fileName)
    }

    if facts.kind == .series { return (.tvSeries, .type) }
    return (nil, nil)
  }

  /// Maps a language code and a title type to a language or type shelf.
  private static func shelf(for language: String, kind: EntertainmentKind) -> HomeCategoryKind? {
    switch (language, kind) {
    case (Language.korean, .series): .koreanSeries
    case (_, .series): .tvSeries
    case (Language.hindi, .movie): .hindiMovies
    case (Language.english, .movie): .englishMovies
    default: nil
    }
  }

  private static func folderLanguage(_ tokens: Set<String>) -> String? {
    if !tokens.isDisjoint(with: Tags.hindiFolder) { return Language.hindi }
    if !tokens.isDisjoint(with: Tags.koreanFolder) { return Language.korean }
    if !tokens.isDisjoint(with: Tags.englishFolder) { return Language.english }
    return nil
  }

  private static func fileLanguage(_ tokens: Set<String>) -> String? {
    if !tokens.isDisjoint(with: Tags.hindiFile) { return Language.hindi }
    if !tokens.isDisjoint(with: Tags.koreanFile) { return Language.korean }
    return nil
  }

  // MARK: - Genre shelves

  private static func isDocumentary(_ facts: Facts) -> Bool {
    if let genres = facts.tmdbGenres { return genres.contains(Genre.documentary) }
    if let genres = facts.omdbGenres { return genres.contains(Genre.documentary) }
    return !facts.folderTokens.isDisjoint(with: Tags.documentaryFolder)
      || !facts.fileTokens.isDisjoint(with: Tags.documentaryFile)
  }

  private static func isKidsAndFamily(_ facts: Facts) -> Bool {
    if let genres = facts.tmdbGenres { return !genres.isDisjoint(with: Genre.kidsAndFamily) }
    if let genres = facts.omdbGenres { return !genres.isDisjoint(with: Genre.kidsAndFamily) }
    return !facts.folderTokens.isDisjoint(with: Tags.kidsFolder)
      || !facts.fileTokens.isDisjoint(with: Tags.kidsFile)
  }

  // MARK: - Evidence

  private enum Language {
    static let english = "en"
    static let hindi = "hi"
    static let korean = "ko"
    static let japanese = "ja"
  }

  private enum Genre {
    static let animation = "animation"
    static let documentary = "documentary"
    static let kidsAndFamily: Set<String> = ["kids", "family"]
  }

  /// Folder tags match a whole path component, so "Family Guy" does not count as a Family folder.
  /// File-name tags match words and adjacent word pairs, so "K.Drama" also matches.
  private enum Tags {
    static let animeFolder: Set<String> = ["anime", "animes"]
    static let animeFile: Set<String> = ["anime"]
    static let tvFolder: Set<String> = ["tvshows", "tvshow", "tvseries", "series", "shows", "tv"]
    static let hindiFolder: Set<String> = ["hindi", "bollywood"]
    static let koreanFolder: Set<String> = ["korean", "koreanseries", "korea", "kdrama", "kdramas"]
    static let englishFolder: Set<String> = ["english", "hollywood"]
    static let hindiFile: Set<String> = ["hindi", "bollywood"]
    static let koreanFile: Set<String> = ["korean", "kdrama", "kdramas"]
    static let documentaryFolder: Set<String> = ["documentary", "documentaries", "docs"]
    static let documentaryFile: Set<String> = ["documentary", "documentaries"]
    static let kidsFolder: Set<String> = ["kids", "kid", "family"]
    static let kidsFile: Set<String> = ["kids"]
  }

  /// The evidence for one title, read once so each rule is a set check.
  private struct Facts {
    let kind: EntertainmentKind
    let tmdbLanguage: String?
    let tmdbGenres: Set<String>?
    let omdbLanguage: String?
    let omdbGenres: Set<String>?
    let omdbIsJapan: Bool
    let folderTokens: Set<String>
    /// File names are tokenised only when a rule reaches the file-name tier.
    let fileNames: [String]

    var fileTokens: Set<String> {
      var tokens = Set<String>()
      for name in fileNames { tokens.formUnion(Facts.fileTokens(name)) }
      return tokens
    }

    var tmdbIsAnimated: Bool { tmdbGenres?.contains(Genre.animation) == true }
    var omdbIsAnimated: Bool { omdbGenres?.contains(Genre.animation) == true }

    init(title: EntertainmentTitle, movie: MovieMetadata?) {
      kind = title.kind
      tmdbLanguage = Facts.normalized(title.metadata?.language)
      tmdbGenres = Facts.genreSet(title.metadata?.genres ?? [])

      let languages = Facts.list(MovieMetadata.available(movie?.language))
      let countries = Facts.list(MovieMetadata.available(movie?.country))
      omdbLanguage =
        languages.first.map(Facts.languageCode(named:))
        ?? countries.first.flatMap(Facts.countryLanguage(named:))
      omdbGenres = Facts.genreSet(Facts.list(MovieMetadata.available(movie?.genre)))
      omdbIsJapan = countries.contains("japan") || languages.contains("japanese")

      var folders = Set<String>()
      for version in title.versions {
        // Folder components come from the relative path string. GlobalSearchResult.parentPath
        // builds a URL per call, which dominated the cost for large libraries.
        folders.formUnion(Facts.folderKeys(ofParentOf: version.media.relativePath))
        folders.formUnion(Facts.folderKeys(version.media.categoryName))
      }
      folderTokens = folders
      fileNames = title.versions.map { $0.media.entry.name }
    }

    static func normalized(_ value: String?) -> String? {
      guard let value else { return nil }
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      return trimmed.isEmpty ? nil : trimmed
    }

    static func list(_ value: String?) -> [String] {
      guard let value else { return [] }
      return value.split(separator: ",").compactMap { normalized(String($0)) }
    }

    static func genreSet(_ names: [String]) -> Set<String>? {
      let set = Set(names.compactMap { normalized($0) })
      return set.isEmpty ? nil : set
    }

    static func languageCode(named name: String) -> String {
      switch name {
      case "english": Language.english
      case "hindi": Language.hindi
      case "korean": Language.korean
      case "japanese": Language.japanese
      default: name
      }
    }

    static func countryLanguage(named name: String) -> String? {
      switch name {
      case "japan": Language.japanese
      case "south korea", "korea": Language.korean
      default: nil
      }
    }

    /// Whole folder names, normalised to letters and digits: "K-Drama" becomes "kdrama".
    static func folderKeys(_ path: String) -> Set<String> {
      var keys = Set<String>()
      for component in path.split(separator: "/") {
        let key = folderKey(component)
        if !key.isEmpty { keys.insert(key) }
      }
      return keys
    }

    /// Folder keys for the directories above a file, given its path relative to the library root.
    static func folderKeys(ofParentOf relativePath: String) -> Set<String> {
      var components = relativePath.split(separator: "/")
      if !components.isEmpty { components.removeLast() }
      var keys = Set<String>()
      for component in components {
        let key = folderKey(component)
        if !key.isEmpty { keys.insert(key) }
      }
      return keys
    }

    private static func folderKey(_ component: Substring) -> String {
      var key = ""
      for character in component where character.isLetter || character.isNumber {
        key.append(contentsOf: character.lowercased())
      }
      return key
    }

    /// Words and adjacent word pairs from a file name, so "K.Drama" yields "kdrama".
    static func fileTokens(_ fileName: String) -> Set<String> {
      let words = fileName.lowercased()
        .split { !($0.isLetter || $0.isNumber) }
        .map(String.init)
      var tokens = Set(words)
      for index in words.indices.dropLast() {
        tokens.insert(words[index] + words[index + 1])
      }
      return tokens
    }
  }
}

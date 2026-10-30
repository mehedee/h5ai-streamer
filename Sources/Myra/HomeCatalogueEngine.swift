import Foundation

// MARK: - Facets

/// What a title is, for filtering. Taken from TMDB metadata when present, and otherwise from the
/// folders and file names the title lives in, so filters work on a library with no metadata at all.
struct TitleTraits: Sendable {
  var genres: [String] = []
  var language: String?
  /// Every year the title can be found under: file name, release date, a year folder.
  var years: [String] = []
  var qualities: [String] = []
  var sources: [String] = []
  var rating = 0.0
  /// Lowercased, accent-free display name for query matching.
  var searchText = ""
}

struct FolderFacts {
  var genres: [String] = []
  var language: String?
  var year: String?
}

enum TitleFacetDerivation {
  /// Folder words that carry no meaning of their own.
  private static let noise: Set<String> = [
    "movies", "movie", "films", "film", "series", "shows", "show", "tv", "collection", "hd", "the",
    "and", "new", "old", "dubbed", "complete", "season", "seasons",
  ]
  private static let genreWords: [String: String] = [
    "action": "Action", "adventure": "Adventure", "animation": "Animation", "animated": "Animation",
    "cartoon": "Animation", "cartoons": "Animation", "comedy": "Comedy", "comedies": "Comedy",
    "crime": "Crime", "documentary": "Documentary", "documentaries": "Documentary",
    "docs": "Documentary", "drama": "Drama", "dramas": "Drama", "family": "Family",
    "kids": "Family", "kid": "Family", "children": "Family", "fantasy": "Fantasy",
    "history": "History", "historical": "History", "horror": "Horror", "music": "Music",
    "musical": "Music", "musicals": "Music", "mystery": "Mystery", "romance": "Romance",
    "romantic": "Romance", "scifi": "Science Fiction", "thriller": "Thriller",
    "thrillers": "Thriller", "war": "War", "western": "Western", "westerns": "Western",
  ]
  private static let languageWords: [String: String] = [
    "english": "en", "hollywood": "en", "hindi": "hi", "bollywood": "hi", "korean": "ko",
    "kdrama": "ko", "kdramas": "ko", "korea": "ko", "japanese": "ja", "spanish": "es",
    "french": "fr", "german": "de", "italian": "it", "chinese": "zh", "tamil": "ta",
    "telugu": "te", "bengali": "bn", "russian": "ru", "turkish": "tr", "thai": "th",
    "portuguese": "pt", "arabic": "ar", "urdu": "ur", "malayalam": "ml", "punjabi": "pa",
  ]
  /// Languages a file name may announce by itself (distinct enough not to appear in titles).
  private static let fileLanguageWords: [String: String] = [
    "hindi": "hi", "bollywood": "hi", "korean": "ko", "kdrama": "ko", "tamil": "ta",
    "telugu": "te",
  ]

  private static func words(_ text: String) -> [String] {
    var result: [String] = []
    var current = ""
    for scalar in text.lowercased().unicodeScalars {
      if CharacterSet.alphanumerics.contains(scalar) {
        current.unicodeScalars.append(scalar)
      } else if !current.isEmpty {
        result.append(current)
        current = ""
      }
    }
    if !current.isEmpty { result.append(current) }
    // "sci-fi" and "sci fi" become one word.
    var merged: [String] = []
    var index = 0
    while index < result.count {
      if result[index] == "sci", index + 1 < result.count, result[index + 1] == "fi" {
        merged.append("scifi")
        index += 2
      } else {
        merged.append(result[index])
        index += 1
      }
    }
    return merged
  }

  /// A path component names genres, languages or a year only when every word in it does, so
  /// "Family Guy" is not a Family folder but "Hindi Action Movies" is Hindi and Action.
  private static func facts(ofComponent component: String, into result: inout FolderFacts) {
    let kept = words(component).filter { !noise.contains($0) }
    guard !kept.isEmpty else { return }
    if kept.count == 1, kept[0].count == 4, Int(kept[0]).map({ (1900...2099).contains($0) }) == true {
      result.year = kept[0]
      return
    }
    var genres: [String] = []
    var language: String?
    for word in kept {
      if let genre = genreWords[word] {
        genres.append(genre)
      } else if let code = languageWords[word] {
        language = language ?? code
      } else if word == "anime" {
        genres.append("Animation")
        language = language ?? "ja"
      } else {
        return
      }
    }
    for genre in genres where !result.genres.contains(genre) { result.genres.append(genre) }
    if result.language == nil { result.language = language }
  }

  private static func folderFacts(path: String, source: String) -> FolderFacts {
    var result = FolderFacts()
    facts(ofComponent: source, into: &result)
    let parts = path.split(separator: "/", omittingEmptySubsequences: true).dropLast()
    for part in parts { facts(ofComponent: String(part), into: &result) }
    return result
  }

  private static func qualities(ofFileName name: String) -> [String] {
    let lower = name.lowercased()
    var result: [String] = []
    if lower.contains("2160p") || lower.contains("4k") || lower.contains("uhd") {
      result.append("2160p")
    }
    if lower.contains("1080p") { result.append("1080p") }
    if lower.contains("720p") { result.append("720p") }
    if lower.contains("480p") || lower.contains("576p") || lower.contains("dvdrip") {
      result.append("480p")
    }
    return result
  }

  private static let posix = Locale(identifier: "en_US_POSIX")

  /// Lowercased and accent-free. Plain ASCII, nearly every name, skips the slow Unicode folding.
  static func fold(_ text: String) -> String {
    if text.utf8.allSatisfy({ $0 < 0x80 }) { return text.lowercased() }
    return text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: posix)
  }

  static func traits(for title: EntertainmentTitle, cache: inout [String: FolderFacts]) -> TitleTraits
  {
    var traits = TitleTraits()
    var folder = FolderFacts()
    var qualities: [String] = []
    var sources: [String] = []
    for version in title.versions {
      let media = version.media
      let path = media.relativePath
      let parent = path.lastIndex(of: "/").map { path[..<$0] } ?? ""
      let key = media.categoryName + "\u{1}" + parent
      let found: FolderFacts
      if let cached = cache[key] {
        found = cached
      } else {
        found = folderFacts(path: media.relativePath, source: media.categoryName)
        cache[key] = found
      }
      for genre in found.genres where !folder.genres.contains(genre) { folder.genres.append(genre) }
      folder.language = folder.language ?? found.language
      folder.year = folder.year ?? found.year
      for quality in Self.qualities(ofFileName: media.entry.name) where !qualities.contains(quality) {
        qualities.append(quality)
      }
      if !sources.contains(media.categoryName) { sources.append(media.categoryName) }
    }
    let metadata = title.metadata
    traits.genres = metadata?.genres.isEmpty == false ? metadata!.genres : folder.genres
    let metadataLanguage = metadata?.language.trimmingCharacters(in: .whitespaces).lowercased()
    var language = (metadataLanguage?.isEmpty == false ? metadataLanguage : nil) ?? folder.language
    if language == nil {
      // Last resort: a language tag in a file name ("Movie.2019.Hindi.1080p.mkv").
      outer: for version in title.versions {
        let lower = version.media.entry.name.lowercased()
        for (word, code) in fileLanguageWords where lower.contains(word) {
          if words(lower).contains(word) {
            language = code
            break outer
          }
        }
      }
    }
    traits.language = language
    var years: [String] = []
    for candidate in [
      title.year, metadata?.releaseDate.map { String($0.prefix(4)) }, folder.year,
    ] {
      if let candidate, candidate.count == 4, !years.contains(candidate) { years.append(candidate) }
    }
    traits.years = years
    traits.qualities = qualities
    traits.sources = sources
    traits.rating = metadata?.rating ?? 0
    traits.searchText = fold(title.displayName)
    return traits
  }

  /// Traits for many titles, computed across the processor cores.
  static func traits(for titles: [EntertainmentTitle]) -> [TitleTraits] {
    let result = ParallelChunks.map(count: titles.count) { range in
      var cache: [String: FolderFacts] = [:]
      return range.map { traits(for: titles[$0], cache: &cache) }
    }
    return result.count == titles.count ? result : Array(repeating: TitleTraits(), count: titles.count)
  }

  /// Display name for a filter value: language codes become names.
  static func languageLabel(_ code: String) -> String {
    Locale(identifier: "en").localizedString(forLanguageCode: code)?.capitalized ?? code
  }
}

// MARK: - The prepared catalogue

/// Everything Home needs from a catalogue, computed once off the main thread and kept: per-title
/// traits, the global shelf membership, the sort orders of the rating, release and recency shelves,
/// and the facet lists. A filter change is then one pass over small arrays, not a re-derivation.
final class HomeCatalogueIndex: @unchecked Sendable {
  struct Signature: Hashable, Sendable {
    var count: Int
    var enriched: Int
    var providerSum: Int
    var first: String
    var last: String

    init(_ titles: [EntertainmentTitle]) {
      count = titles.count
      var enriched = 0
      var sum = 0
      for title in titles {
        if let metadata = title.metadata {
          enriched += 1
          sum &+= metadata.providerID &+ metadata.voteCount
        }
      }
      self.enriched = enriched
      providerSum = sum
      first = titles.first?.id ?? ""
      last = titles.last?.id ?? ""
    }
  }

  let signature: Signature
  let traits: [TitleTraits]
  /// Automatic shelves over the whole catalogue, each at least `minimumTitleCount` strong.
  let categories: [HomeCategory]
  let options: LibraryFilterOptions
  let indexByID: [String: Int]
  let movieOrder: [Int]
  let seriesOrder: [Int]
  let latestOrder: [Int]
  let recentOrder: [Int]

  static let empty = HomeCatalogueIndex(titles: [])

  var count: Int { traits.count }

  init(titles: [EntertainmentTitle]) {
    var stage = MyraPerformance.begin("homeIndex.signature")
    signature = Signature(titles)
    stage.end()
    stage = MyraPerformance.begin("homeIndex.traits")
    let traits = TitleFacetDerivation.traits(for: titles)
    self.traits = traits
    stage.end()
    stage = MyraPerformance.begin("homeIndex.classify")
    let assignments = ParallelChunks.map(count: titles.count) { range in
      range.map { HomeCategoryClassifier.classify(titles[$0]) }
    }
    stage.end()
    stage = MyraPerformance.begin("homeIndex.categories")
    categories = HomeCategoryBuilder.categories(for: titles, assignments: assignments)
    stage.end()
    stage = MyraPerformance.begin("homeIndex.orders")
    var lookup: [String: Int] = [:]
    lookup.reserveCapacity(titles.count)
    for (offset, title) in titles.enumerated() where lookup[title.id] == nil { lookup[title.id] = offset }
    indexByID = lookup

    func score(_ title: EntertainmentTitle) -> Double {
      guard let metadata = title.metadata else { return 0 }
      let votes = Double(metadata.voteCount)
      return (votes * metadata.rating + 50 * 6.5) / (votes + 50)
    }
    let scores = titles.map(score)
    let byScore: (Int, Int) -> Bool = { scores[$0] != scores[$1] ? scores[$0] > scores[$1] : $0 < $1 }
    movieOrder = titles.indices.filter {
      titles[$0].kind == .movie && (titles[$0].metadata?.voteCount ?? 0) >= 20
    }.sorted(by: byScore)
    seriesOrder = titles.indices.filter { titles[$0].kind == .series }.sorted(by: byScore)
    let released = titles.map { $0.latestReleaseDate }
    latestOrder = titles.indices.filter { released[$0] != nil }.sorted {
      released[$0]! != released[$1]! ? released[$0]! > released[$1]! : $0 < $1
    }
    let discovered = titles.map(\.latestDiscovered)
    recentOrder = titles.indices.sorted {
      discovered[$0] != discovered[$1] ? discovered[$0] > discovered[$1] : $0 < $1
    }
    stage.end()
    stage = MyraPerformance.begin("homeIndex.facets")
    options = HomeCatalogueIndex.options(traits: traits, include: nil)
    stage.end()
  }

  /// Counts for each option over the titles in `include` (all titles when nil). Most titles first,
  /// then alphabetical; years newest first; qualities from the highest resolution down.
  static func options(traits: [TitleTraits], include: [Bool]?) -> LibraryFilterOptions {
    var genres: [String: Int] = [:]
    var languages: [String: Int] = [:]
    var years: [String: Int] = [:]
    var qualities: [String: Int] = [:]
    var sources: [String: Int] = [:]
    for (offset, trait) in traits.enumerated() {
      if let include, !include[offset] { continue }
      for value in trait.genres { genres[value, default: 0] += 1 }
      if let language = trait.language { languages[language, default: 0] += 1 }
      if let year = trait.years.first { years[year, default: 0] += 1 }
      for value in trait.qualities { qualities[value, default: 0] += 1 }
      for value in trait.sources { sources[value, default: 0] += 1 }
    }
    func list(_ counts: [String: Int]) -> [FilterOption] {
      counts.map { FilterOption(value: $0.key, count: $0.value) }.sorted {
        $0.count != $1.count
          ? $0.count > $1.count : $0.value.localizedStandardCompare($1.value) == .orderedAscending
      }
    }
    return LibraryFilterOptions(
      genres: list(genres), languages: list(languages),
      years: years.map { FilterOption(value: $0.key, count: $0.value) }.sorted {
        $0.value > $1.value
      },
      qualities: LibraryFilter.resolutionOrder.compactMap { name in
        qualities[name].map { FilterOption(value: name, count: $0) }
      },
      sources: list(sources))
  }
}

/// Splits indexed work across the processor cores. The body must be pure.
enum ParallelChunks {
  static func map<T: Sendable>(
    count: Int, _ body: @Sendable (Range<Int>) -> [T]
  ) -> [T] {
    guard count > 0 else { return [] }
    let chunks = count < 2000 ? 1 : min(ProcessInfo.processInfo.activeProcessorCount, 8)
    if chunks == 1 { return body(0..<count) }
    let size = (count + chunks - 1) / chunks
    let lock = NSLock()
    nonisolated(unsafe) var parts = [[T]](repeating: [], count: chunks)
    DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
      let range = (chunk * size)..<min(count, (chunk + 1) * size)
      let result = range.isEmpty ? [] : body(range)
      lock.lock()
      parts[chunk] = result
      lock.unlock()
    }
    return parts.flatMap { $0 }
  }
}

// MARK: - Filtering

extension HomeCatalogueFilter {
  var isEmpty: Bool {
    query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !selection.isActive
  }
}

enum HomeFilterEngine {
  /// Which titles pass the filter, from the prepared traits (no per-title string work). A title
  /// passes when it satisfies every active facet; within a facet any selected value is enough.
  /// `ignoring` leaves one facet out, for the counts shown in that facet's own menu.
  static func passes(
    index: HomeCatalogueIndex, catalogue: [EntertainmentTitle], personal: EntertainmentPersonalData,
    filter: HomeCatalogueFilter, ignoring skipped: LibraryFacet? = nil
  ) -> [Bool] {
    let query = TitleFacetDerivation.fold(filter.query.trimmingCharacters(in: .whitespacesAndNewlines))
    let selection = filter.selection
    let traits = index.traits
    var result = [Bool](repeating: true, count: traits.count)
    if query.isEmpty && !selection.isActive { return result }
    let watched = personal.watched
    for offset in traits.indices {
      let trait = traits[offset]
      let title = catalogue[offset]
      var pass = true
      if !query.isEmpty, !trait.searchText.contains(query) { pass = false }
      if pass {
        switch selection.kind {
        case .all: break
        case .movies: pass = title.kind == .movie
        case .series: pass = title.kind == .series
        }
      }
      if pass, selection.hideWatched, watched.contains(title.id) { pass = false }
      if pass, skipped != .genre, !selection.genres.isEmpty,
        selection.genres.isDisjoint(with: trait.genres)
      {
        pass = false
      }
      if pass, skipped != .language, !selection.languages.isEmpty,
        !selection.languages.contains(trait.language ?? "")
      {
        pass = false
      }
      if pass, skipped != .year, !selection.years.isEmpty,
        selection.years.isDisjoint(with: trait.years)
      {
        pass = false
      }
      if pass, skipped != .quality, !selection.qualities.isEmpty,
        selection.qualities.isDisjoint(with: trait.qualities)
      {
        pass = false
      }
      if pass, skipped != .source, !selection.sources.isEmpty,
        selection.sources.isDisjoint(with: trait.sources)
      {
        pass = false
      }
      result[offset] = pass
    }
    return result
  }

  /// Option lists with counts. With nothing selected they cover the whole catalogue; with a
  /// selection each list counts what the other active facets leave visible, so a menu shows what
  /// choosing a value would give.
  static func facetOptions(
    index: HomeCatalogueIndex, catalogue: [EntertainmentTitle], personal: EntertainmentPersonalData,
    filter: HomeCatalogueFilter
  ) -> LibraryFilterOptions {
    guard !filter.isEmpty, index.count == catalogue.count else { return index.options }
    var options = LibraryFilterOptions()
    for facet in LibraryFacet.allCases {
      let visible = passes(
        index: index, catalogue: catalogue, personal: personal, filter: filter, ignoring: facet)
      let counted = HomeCatalogueIndex.options(traits: index.traits, include: visible)
      switch facet {
      case .genre: options.genres = counted.genres
      case .language: options.languages = counted.languages
      case .year: options.years = counted.years
      case .quality: options.qualities = counted.qualities
      case .source: options.sources = counted.sources
      }
    }
    return options
  }

  static func project(
    catalogue: [EntertainmentTitle], index: HomeCatalogueIndex, personal: EntertainmentPersonalData,
    filter: HomeCatalogueFilter
  ) -> HomeCatalogueProjection {
    var result = HomeCatalogueProjection()
    let pass = passes(index: index, catalogue: catalogue, personal: personal, filter: filter)
    result.filtered = catalogue.indices.compactMap { pass[$0] ? catalogue[$0] : nil }
    result.movies = index.movieOrder.compactMap { pass[$0] ? catalogue[$0] : nil }
    result.series = index.seriesOrder.compactMap {
      pass[$0] && !personal.watched.contains(catalogue[$0].id) ? catalogue[$0] : nil
    }
    result.latest = index.latestOrder.compactMap { pass[$0] ? catalogue[$0] : nil }
    result.recent = index.recentOrder.compactMap { pass[$0] ? catalogue[$0] : nil }
    result.watchlist = personal.watchlist.compactMap { index.indexByID[$0] }.sorted().compactMap {
      pass[$0] ? catalogue[$0] : nil
    }
    // The filter bar's counts come from the whole catalogue, so a chosen value can be widened.
    result.options = index.options
    // Shelf membership was classified once for the whole catalogue; a filter only narrows it.
    let preferences = personal.homeCategories ?? HomeCategoryPreferences()
    for arranged in preferences.arrange(index.categories) where !arranged.isHidden {
      var ids: [String] = []
      var titles: [EntertainmentTitle] = []
      for id in arranged.category.titleIDs {
        guard let offset = index.indexByID[id], pass[offset] else { continue }
        ids.append(id)
        titles.append(catalogue[offset])
      }
      guard ids.count >= HomeCategoryRules.minimumTitleCount else { continue }
      result.shelves.append(
        HomeAutomaticShelf(
          arranged: ArrangedHomeCategory(
            category: HomeCategory(kind: arranged.category.kind, titleIDs: ids),
            isPinned: arranged.isPinned, isHidden: false),
          titles: titles))
    }
    return result
  }
}

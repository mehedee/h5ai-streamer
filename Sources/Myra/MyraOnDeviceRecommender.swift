import Foundation

/// Genre words people use, mapped to canonical catalogue genres.
enum MyraGenreVocabulary {
  private static let synonyms: [(pattern: String, genres: [String])] = [
    ("sci-?fi|science[ -]fiction", ["Science Fiction"]),
    ("romcom|rom-com", ["Romance", "Comedy"]),
    ("documentar(?:y|ies)", ["Documentary"]),
    ("animat(?:ed|ion|ions)|cartoons?", ["Animation"]),
    ("kids?|children'?s", ["Family"]),
  ]

  /// True when the request names this genre directly or through a synonym.
  static func mentions(_ genre: String, in request: String) -> Bool {
    if matches("\(NSRegularExpression.escapedPattern(for: genre))s?", in: request) { return true }
    return synonyms.contains { entry in
      entry.genres.contains { $0.caseInsensitiveCompare(genre) == .orderedSame }
        && matches(entry.pattern, in: request)
    }
  }

  /// Canonical genres named by the request. More than one means the request is ambiguous.
  static func genres(in request: String, catalogueGenres: [String]) -> [String] {
    var found = Set<String>()
    for genre in catalogueGenres where mentions(genre, in: request) { found.insert(genre) }
    for entry in synonyms where matches(entry.pattern, in: request) {
      entry.genres.forEach { found.insert($0) }
    }
    return found.sorted()
  }

  static func matches(_ pattern: String, in text: String) -> Bool {
    guard let regex = try? NSRegularExpression(pattern: "\\b(?:\(pattern))\\b", options: [.caseInsensitive])
    else { return false }
    return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
  }
}

/// A local reading of explicit constraints. `isConfident` means no clause was left unexplained.
struct MyraIntentParse: Sendable, Equatable {
  var intent: MyraSearchIntent
  var isConfident: Bool
}

/// Reads explicit constraints (genre, year, rating, runtime, watch state, kind, language)
/// without a model. Mood and style words stay with ranking, and anything it cannot express
/// marks the parse as unconfident so the model may be asked instead.
enum MyraIntentParser {
  private static let numberWords: [String: Int] = [
    "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
    "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "fifteen": 15, "twenty": 20,
    "thirty": 30, "forty": 40, "forty-five": 45, "fifty": 50, "sixty": 60, "ninety": 90,
  ]
  private static let number =
    "\\d{1,3}|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|fifteen|twenty|thirty|forty-five|forty|fifty|sixty|ninety"
  private static let languages: [(word: String, code: String)] = [
    ("english", "en"), ("korean", "ko"), ("japanese", "ja"), ("french", "fr"), ("spanish", "es"),
    ("german", "de"), ("bengali", "bn"), ("bangla", "bn"), ("hindi", "hi"), ("chinese", "zh"),
    ("italian", "it"), ("tamil", "ta"), ("arabic", "ar"), ("portuguese", "pt"), ("turkish", "tr"),
  ]
  /// Relative or quality words that need a model or a clearer request.
  private static let unexplainedWords =
    "short|long|recent|recently|latest|new|newest|old|older|classic|last|past|top|best|worst|popular|trending"
  private static let stopWords: Set<String> = [
    "a", "an", "the", "me", "my", "i", "you", "show", "find", "give", "want", "need", "search",
    "looking", "look", "for", "of", "on", "in", "to", "with", "and", "or", "please", "something",
    "some", "any", "anything", "that", "this", "these", "those", "is", "are", "be", "it", "its",
    "from", "about", "tonight", "today", "now", "just", "more", "like", "similar", "title",
    "titles", "what", "which", "do", "have", "pick", "plan", "recommend", "suggest", "one", "ones",
    "movie", "movies", "film", "films", "series", "show", "shows", "tv", "episode", "episodes",
    "minutes", "minute", "min", "mins", "hour", "hours", "hr", "hrs", "available", "time",
  ]

  /// `catalogueGenres` and `catalogueTitleWords` come from the indexed library, never from the model.
  static func parse(
    prompt: String, feature: MyraAIFeature, catalogueGenres: [String] = [],
    catalogueTitleWords: Set<String> = []
  ) -> MyraIntentParse {
    var text =
      " " + prompt.lowercased().replacingOccurrences(of: "\u{2019}", with: "'") + " "
    var intent = MyraSearchIntent()
    var uncertain = false
    if text.split(whereSeparator: { $0.isWhitespace }).count > 60 { uncertain = true }

    /// Returns the capture groups of every match and removes those matches from the text.
    func take(_ pattern: String) -> [[String]] {
      guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
      else { return [] }
      let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
      let groups = matches.map { match in
        (0..<match.numberOfRanges).map { index -> String in
          guard let range = Range(match.range(at: index), in: text) else { return "" }
          return String(text[range])
        }
      }
      if !matches.isEmpty {
        text = regex.stringByReplacingMatches(
          in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
      }
      return groups
    }
    func value(_ token: String) -> Int? { Int(token) ?? numberWords[token.lowercased()] }

    // Watch state and list membership.
    if !take(
      "\\b(?:unwatched|not (?:yet )?(?:watched|seen)|haven'?t (?:yet )?(?:seen|watched)|unseen|never (?:watched|seen)|new to me)\\b"
    ).isEmpty {
      intent.unwatched = true
    }
    if !take(
      "\\b(?:unfinished|in progress|resum(?:e|ing)|half[- ]watched|partly watched|continue watching|keep watching)\\b"
    ).isEmpty {
      intent.unfinished = true
    }
    if !take(
      "\\b(?:rewatch\\w*|already (?:watched|seen|finished)|seen before|previously watched|finished|i'?ve (?:already )?(?:seen|watched))\\b"
    ).isEmpty {
      intent.watched = true
    }
    if !take("\\b(?:watchlist|watch list|saved to watch|my list|bookmarked)\\b").isEmpty {
      intent.watchlisted = true
    }

    // Kind: a movie and a series in one request is ambiguous.
    let movieWords = !take("\\b(?:movies?|films?)\\b").isEmpty
    let seriesWords = !take("\\b(?:series|shows?|tv|episodes?|seasons?)\\b").isEmpty
    if movieWords && seriesWords {
      uncertain = true
    } else if movieWords {
      intent.kind = "movie"
    } else if seriesWords {
      intent.kind = "series"
    }

    // Genre: exactly one canonical genre is explicit; several are left to the model.
    let genres = MyraGenreVocabulary.genres(
      in: text, catalogueGenres: Array(Set(catalogueGenres)).sorted())
    if genres.count == 1 { intent.genre = genres[0] } else if genres.count > 1 { uncertain = true }

    // Language.
    let languageCodes = Set(
      languages.compactMap { entry -> String? in
        matches(entry.word, in: text) ? entry.code : nil
      })
    if languageCodes.count == 1 { intent.language = languageCodes.first } else if languageCodes.count > 1 {
      uncertain = true
    }

    // Years. A range first, then one-sided bounds, then an exact year.
    for group in take("\\b(?:from |between |in |during )?(19\\d{2}|20\\d{2}) ?(?:-|\u{2013}|to|and|through|till|until) ?(19\\d{2}|20\\d{2})\\b")
    {
      let first = Int(group[1]) ?? 0
      let second = Int(group[2]) ?? 0
      intent.minimumYear = min(first, second)
      intent.maximumYear = max(first, second)
    }
    for group in take("\\b(19\\d0|20\\d0)s\\b") {
      let start = Int(group[1]) ?? 0
      intent.minimumYear = start
      intent.maximumYear = start + 9
    }
    for group in take(
      "\\b(?:after|since|from|newer than|later than|released after)\\s+(19\\d{2}|20\\d{2})\\b")
    {
      intent.minimumYear = Int(group[1])
    }
    for group in take(
      "\\b(?:before|until|up to|older than|prior to|released before)\\s+(19\\d{2}|20\\d{2})\\b")
    {
      intent.maximumYear = Int(group[1])
    }
    for group in take("\\b(?:in|released in)\\s+(19\\d{2}|20\\d{2})\\b") {
      let year = Int(group[1])
      intent.minimumYear = year
      intent.maximumYear = year
    }
    for group in take("\\b(19\\d{2}|20\\d{2})\\b") {
      let year = Int(group[1])
      intent.minimumYear = year
      intent.maximumYear = year
    }

    // Rating: only explicit rating words, stars, or x/10 forms.
    for group in take(
      "\\b(?:rated|rating|scores?|scored|imdb)\\s*(?:of\\s+|above\\s+|over\\s+|at least\\s+|higher than\\s+)?(\\d{1,2}(?:\\.\\d)?)(?:\\s*(?:\\+|/\\s*10|or (?:higher|more|above)|and (?:up|above)))?\\b"
    ) + take("\\b(?:above|over|at least)\\s+(\\d{1,2}(?:\\.\\d)?)\\s*(?:stars?|rating|imdb)\\b")
      + take("\\b(\\d{1,2}(?:\\.\\d)?)\\s*/\\s*10\\b")
    {
      let rating = Double(group[1]) ?? -1
      if (0...10).contains(rating) { intent.minimumRating = rating } else { uncertain = true }
    }

    // Runtime. Qualified limits are explicit; plan budgets accept any time phrase.
    let limitPrefix =
      "under|less than|shorter than|no longer than|within|at most|up to|below|maximum of|max(?:imum)?|in under"
    for group in take(
      "\\b(?:\(limitPrefix))\\s+(\(number))\\s*(hours?|hrs?|minutes?|mins?)\\b")
    {
      if let amount = value(group[1]) {
        let isHours = group[2].lowercased().hasPrefix("h")
        intent.maximumMinutes = amount * (isHours ? 60 : 1)
      } else {
        uncertain = true
      }
    }
    if feature == .plan {
      for group in take("\\b(\(number))\\s*(hours?|hrs?|minutes?|mins?)\\b") {
        if let amount = value(group[1]) {
          let isHours = group[2].lowercased().hasPrefix("h")
          intent.maximumMinutes = amount * (isHours ? 60 : 1)
        }
      }
    }

    // Anything left that looks like a constraint is not explained by the rules above.
    if !take("\\bnot\\b|\\bno\\b|\\bwithout\\b|\\bexcept\\b|\\bbut\\b|\\bnever\\b|\\bavoid\\b|\\bexcluding\\b|\\bexclude\\b|\\bnothing\\b|\\bdon'?t\\b|\\bdoesn'?t\\b|\\bisn'?t\\b")
      .isEmpty
    {
      uncertain = true
    }
    if !take("\\b(?:\(unexplainedWords))\\b").isEmpty { uncertain = true }
    if !take("\\b\\d+\\b|\\b(?:hours?|hrs?|minutes?|mins?)\\b").isEmpty, feature != .plan {
      uncertain = true
    }

    // Title keywords are only taken from the library, so mood words never become filters.
    if feature == .naturalSearch {
      let residual = text.split { !$0.isLetter && !$0.isNumber && $0 != "'" && $0 != "-" }
        .map { String($0).lowercased() }
        .filter { !stopWords.contains($0) && catalogueTitleWords.contains($0) }
      if !residual.isEmpty { intent.query = residual.joined(separator: " ") }
    }
    return MyraIntentParse(intent: intent, isConfident: !uncertain)
  }

  private static func matches(_ word: String, in text: String) -> Bool {
    MyraGenreVocabulary.matches(NSRegularExpression.escapedPattern(for: word), in: text)
  }
}

extension MyraSearchIntent {
  /// Fills fields the primary intent left empty from the locally read one.
  func filled(from local: MyraSearchIntent) -> MyraSearchIntent {
    var result = self
    result.query = query ?? local.query
    result.genre = genre ?? local.genre
    result.language = language ?? local.language
    result.kind = kind ?? local.kind
    result.minimumYear = minimumYear ?? local.minimumYear
    result.maximumYear = maximumYear ?? local.maximumYear
    result.minimumRating = minimumRating ?? local.minimumRating
    result.unwatched = unwatched ?? local.unwatched
    result.unfinished = unfinished ?? local.unfinished
    result.watchlisted = watchlisted ?? local.watchlisted
    result.watched = watched ?? local.watched
    result.maximumMinutes = maximumMinutes ?? local.maximumMinutes
    return result
  }
}

/// Deterministic fallback for recommendation features. It uses the same filters and shortlist
/// as the model path and writes template reasons, so a recommendation request never ends empty.
enum MyraFallbackRecommender {
  struct Output: Sendable {
    var summary: String
    var recommendations: [MyraAIRecommendation]
  }

  static func recommend(
    feature: MyraAIFeature, prompt: String, titles: [EntertainmentTitle],
    personal: EntertainmentPersonalData, intent: MyraSearchIntent?, selectedIDs: [String],
    language: String
  ) throws -> Output {
    var config = MyraAISettings()
    config.language = language
    let ranked = try MyraAIContext.shortlist(
      titles: titles, personal: personal, config: config, feature: feature, prompt: prompt,
      selectedIDs: selectedIDs, intent: intent?.normalized(for: prompt), limit: 12)
    let budget = feature == .plan ? (intent?.maximumMinutes ?? 0) : nil
    var chosen: [EntertainmentTitle] = []
    var total = 0
    for item in ranked where chosen.count < MyraAIOutputFormat.maximumRecommendations {
      if let budget {
        guard let minutes = MyraAIContext.runtime(item.title), total + minutes <= budget else {
          continue
        }
        total += minutes
      }
      chosen.append(item.title)
    }
    let recommendations: [MyraAIRecommendation] = chosen.map { title in
      .init(
        titleID: title.id,
        reason: templateReason(title, feature: feature, intent: intent, personal: personal),
        versionID: feature == .plan ? MyraAIContext.plannedVersion(title)?.id : nil)
    }
    let summary =
      recommendations.isEmpty
      ? "No indexed title matched every explicit constraint."
      : "Picked \(recommendations.count) title\(recommendations.count == 1 ? "" : "s") from your saved catalogue using fixed rules, not a language model."
    return Output(summary: summary, recommendations: recommendations)
  }

  static func templateReason(
    _ title: EntertainmentTitle, feature: MyraAIFeature, intent: MyraSearchIntent?,
    personal: EntertainmentPersonalData
  ) -> String {
    var facts: [String] = []
    if let genre = title.metadata?.genres.first { facts.append(genre) }
    if let year = title.year { facts.append(year) }
    if let rating = title.metadata?.rating, rating > 0 {
      facts.append(String(format: "rated %.1f", rating))
    }
    if let minutes = MyraAIContext.runtime(title) { facts.append("\(minutes) min") }
    if personal.watched.contains(title.id) {
      facts.append("already watched")
    } else {
      facts.append("unwatched")
    }
    if personal.watchlist.contains(title.id) { facts.append("on your watchlist") }
    var constraints: [String] = []
    if let genre = intent?.genre { constraints.append(genre.lowercased()) }
    if let language = intent?.language { constraints.append("in \(language)") }
    if let maximum = intent?.maximumMinutes { constraints.append("within \(maximum) minutes") }
    let lead =
      constraints.isEmpty
      ? (feature == .similar ? "Similar genres in your library" : "Fits your request")
      : "Matches " + constraints.joined(separator: ", ")
    return "\(lead): " + facts.joined(separator: " · ") + "."
  }
}

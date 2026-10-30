import Foundation

enum MyraAIProvider: String, Codable, CaseIterable, Identifiable, Sendable {
  case apple, openAI, claude, disabled
  var id: String { rawValue }
  var title: String {
    switch self {
    case .apple: "Apple On-Device"
    case .openAI: "OpenAI"
    case .claude: "Claude"
    case .disabled: "Disabled"
    }
  }
  var isCloud: Bool { self == .openAI || self == .claude }
}

enum MyraAIFeature: String, Codable, CaseIterable, Identifiable, Sendable {
  case smartPick, naturalSearch, explain, summary, collection, similar, compare, plan
  case preferences, moodTags, assistant, action, cleanup, recap, translate, insights
  var id: String { rawValue }
  var title: String {
    switch self {
    case .smartPick: "Smart Pick"
    case .naturalSearch: "Natural-language Search"
    case .explain: "Why This Pick"
    case .summary: "Short Summary"
    case .collection: "Collection Suggestions"
    case .similar: "More Like This"
    case .compare: "Compare Titles"
    case .plan: "Plan Tonight"
    case .preferences: "Preference Feedback"
    case .moodTags: "Mood Tags"
    case .assistant: "Library Assistant"
    case .action: "Library Actions"
    case .cleanup: "Filename / Grouping Suggestions"
    case .recap: "Episode Recap"
    case .translate: "Translate Description"
    case .insights: "Viewing Insights"
    }
  }
  /// One typed output shape per feature. Chosen here in code, never by inspecting prompt text.
  var outputFormat: MyraAIOutputFormat {
    switch self {
    case .smartPick, .naturalSearch, .similar, .plan: .picks
    case .explain, .summary, .compare, .moodTags, .recap, .translate, .insights: .narrative
    case .collection, .action, .assistant, .cleanup, .preferences: .actions
    }
  }
  /// Features whose request constraints can be read locally before any model call.
  var usesLocalIntent: Bool {
    [.naturalSearch, .smartPick, .plan, .collection, .assistant, .action].contains(self)
  }
  /// Only these features send synopses; every other feature gets the compact one-line form.
  var needsSynopsis: Bool {
    [.summary, .explain, .compare, .moodTags, .translate, .similar, .recap].contains(self)
  }
  /// Recommendation features answer deterministically when the on-device model cannot.
  var isRecommendation: Bool { [.smartPick, .naturalSearch, .similar, .plan].contains(self) }
  var hint: String {
    switch self {
    case .smartPick:
      "Describe your mood, themes, or preferences. Suggestions come from your library."
    case .naturalSearch: "Example: unwatched Korean thrillers after 2018."
    case .explain: "Choose a title and explain why it fits your request."
    case .summary: "Choose a title for a concise, spoiler-conscious synopsis."
    case .collection: "Describe a themed collection; review suggested titles before saving."
    case .similar: "Choose a title to find related titles in your library."
    case .compare: "Select two or more titles to compare verified information."
    case .plan: "Include your time budget, e.g. 120 minutes. Unknown runtimes are excluded."
    case .preferences: "Describe what you enjoy or dislike; review before saving this feedback."
    case .moodTags: "Suggest interpretive mood tags from a title's description."
    case .assistant: "Ask about your library, watchlist, or unfinished shows."
    case .action:
      "Ask to add titles to your watchlist or create a collection; review the proposed action."
    case .cleanup:
      "Select a title to propose a cleaned title/year. Original media files are never renamed."
    case .recap:
      "Select a completed episode and import its subtitle text. Recaps can contain spoilers."
    case .translate: "Choose a title and your target language in AI Settings."
    case .insights: "Describe viewing patterns from locally calculated history statistics."
    }
  }
}

/// Typed output shapes. Titles are always referenced by the tN aliases offered in the request.
enum MyraAIOutputFormat: String, Sendable, CaseIterable {
  case picks, narrative, actions
  static let maximumRecommendations = 3
  static let maximumActions = 4
}

/// How a recommendation result was produced. The UI labels the path so users know what answered.
enum MyraAIResultPath: String, Codable, Sendable {
  case model, deterministicFallback
}

/// One model request. `purpose` selects the typed schema; `aliases` restricts titleID choices.
struct MyraAIRequest: Sendable {
  enum Purpose: Sendable, Equatable {
    case intent(MyraAIFeature)
    case answer(MyraAIFeature, MyraAIOutputFormat)
  }
  var provider: MyraAIProvider
  var model: String
  var key: String
  var instructions: String
  var prompt: String
  var maximumTokens: Int
  var language: String
  var purpose: Purpose
  var aliases: [String] = []
  var onPartialSummary: (@Sendable (String) -> Void)? = nil
}

struct MyraAISettings: Codable, Sendable {
  var provider: MyraAIProvider = .apple
  var model = ""
  var cloudConsent = false
  var shareHistory = false
  var shareSubtitles = false
  var personalize = true
  var language = "en"
  var dailyRequestLimit = 20
  var maximumOutputTokens = 1200
  var feedback = ""
  var enabledFeatures: Set<MyraAIFeature> = Set(MyraAIFeature.allCases)
}

struct MyraAIRecommendation: Codable, Sendable, Identifiable {
  var titleID: String
  var reason: String
  var versionID: String? = nil
  var id: String { titleID }
}

enum MyraAIActionKind: String, Codable, Sendable, CaseIterable {
  case addWatchlist, markWatched, collection, correction, preference, showResults, play
}
struct MyraAIAction: Codable, Sendable, Identifiable {
  var id: String = UUID().uuidString
  var kind: MyraAIActionKind
  var titleIDs: [String]
  var value: String
  var year: String? = nil
  var mediaKind: EntertainmentKind? = nil
  var label: String {
    switch kind {
    case .addWatchlist: "Add to Watchlist"
    case .markWatched: "Mark Watched"
    case .collection: "Create Collection: \(value)"
    case .correction: "Correct Match: \(value)"
    case .preference: "Save Preference Feedback"
    case .showResults: "Show Matching Titles"
    case .play: "Play Selected Title"
    }
  }
}
struct MyraAIResponse: Codable, Sendable {
  var summary: String
  var recommendations: [MyraAIRecommendation]
  var actions: [MyraAIAction]
  var tags: [String]
  var provider: String
  var sourceNote: String
  var path: MyraAIResultPath? = nil
  var pathReason: String? = nil
}

/// All model-facing identities are temporary aliases, never source URLs or paths.
struct MyraAICandidate: Codable, Sendable {
  var id: String
  var title: String
  var year: String?
  var kind: String
  var genres: [String]
  var synopsis: String
  var rating: Double?
  var language: String?
  var runtimeMinutes: Int?
  var watched: Bool?
  var unfinished: Bool?
  var watchlisted: Bool?
  var filenames: [String]? = nil
}
struct MyraSearchIntent: Codable, Sendable, Equatable {
  var query: String? = nil
  var genre: String? = nil
  var language: String? = nil
  var kind: String? = nil
  var minimumYear: Int? = nil
  var maximumYear: Int? = nil
  var minimumRating: Double? = nil
  var unwatched: Bool? = nil
  var unfinished: Bool? = nil
  var watchlisted: Bool? = nil
  var maximumMinutes: Int? = nil
  var watched: Bool? = nil

  /// Models can emit empty strings or defaults for optional fields. Only request-backed
  /// constraints may exclude indexed titles; moods remain model-facing ranking guidance.
  func normalized(for prompt: String) -> Self {
    let request = prompt.lowercased()
    var result = self
    func meaningful(_ value: String?) -> String? {
      guard let value else { return nil }
      let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard
        !["", "any", "all", "none", "null", "unknown", "unspecified"].contains(cleaned.lowercased())
      else { return nil }
      return cleaned
    }
    func mentions(_ words: [String]) -> Bool {
      words.contains { request.range(of: $0, options: .caseInsensitive) != nil }
    }
    let numbers = request.split { !$0.isNumber && $0 != "." }.compactMap { Double($0) }
    result.query = meaningful(query)
    result.genre = meaningful(genre)
    if let value = result.genre, !MyraGenreVocabulary.mentions(value, in: request) {
      result.genre = nil
    }
    result.language = meaningful(language)?.lowercased()
    if let code = result.language {
      let englishName = Locale(identifier: "en").localizedString(forLanguageCode: code)
      let localName = Locale.current.localizedString(forLanguageCode: code)
      let languageWords = [code, englishName, localName].compactMap { $0 }
      let requestWords = Set(request.split { !$0.isLetter }.map(String.init))
      if !languageWords.contains(where: { requestWords.contains($0.lowercased()) }) {
        result.language = nil
      }
    }
    switch meaningful(kind)?.lowercased() {
    case "movie", "movies", "film", "films":
      result.kind = mentions(["movie", "film"]) ? "movie" : nil
    case "series", "tv", "show", "shows", "tv series", "tv show":
      result.kind = mentions(["series", "show", "tv"]) ? "series" : nil
    default: result.kind = nil
    }
    if let year = minimumYear, !(1800...9999).contains(year) || !numbers.contains(Double(year)) {
      result.minimumYear = nil
    }
    if let year = maximumYear, !(1800...9999).contains(year) || !numbers.contains(Double(year)) {
      result.maximumYear = nil
    }
    if let rating = minimumRating,
      !(0...10).contains(rating) || !numbers.contains(rating)
        || !mentions(["rating", "rated", "score", "star", "/10"])
    {
      result.minimumRating = nil
    }
    if unwatched == true,
      !mentions(["unwatched", "not watched", "not seen", "haven't seen", "haven’t seen"])
    {
      result.unwatched = nil
    }
    if unfinished == true, !mentions(["unfinished", "resume", "continue", "in progress"]) {
      result.unfinished = nil
    }
    if watchlisted == true, !mentions(["watchlist", "watch list", "saved to watch"]) {
      result.watchlisted = nil
    }
    if watched == true,
      unwatched == true || !mentions(["rewatch", "watched", "already", "seen before", "finished"])
    {
      result.watched = nil
    }
    if let minutes = maximumMinutes, minutes <= 0 { result.maximumMinutes = nil }
    return result
  }
}

struct MyraAIWireAction: Codable, Sendable {
  var kind: String
  var titleIDs: [String]
  var value: String
  var year: String? = nil
  var mediaKind: String? = nil
}
struct MyraAIWireResponse: Codable, Sendable {
  var summary: String
  var recommendations: [MyraAIRecommendation]
  var actions: [MyraAIWireAction]
  var tags: [String]
}

enum MyraAIError: LocalizedError {
  case unavailable(String)
  case missingKey, consent, limit, invalidResponse, unsafeAction
  case missingContext(String)
  case http(Int)
  /// On-device failures, each with its own user-facing message (see MyraAppleModelErrors).
  case contextOverflow, decodingFailure, guardrail, refusal, assetsUnavailable, busy
  case unsupportedSchema, timedOut
  /// A cloud provider did not answer within the 20 second request budget.
  case cloudTimedOut
  /// A recommendation answer that chose no titles.
  case noPicks
  var isRetryableWithLessContext: Bool {
    switch self {
    case .contextOverflow, .decodingFailure, .invalidResponse: true
    default: false
    }
  }
  var errorDescription: String? {
    switch self {
    case .unavailable(let reason): reason
    case .contextOverflow:
      "The request is too large for the on-device model. Myra retried with less context; try a narrower request."
    case .decodingFailure:
      "The on-device model returned output Myra could not read. Try again or use a narrower request."
    case .guardrail:
      "Apple's on-device safety guardrails blocked this request. Rephrase it without the sensitive detail."
    case .refusal:
      "The on-device model declined this request. Rephrase it or choose another tool."
    case .assetsUnavailable:
      "The on-device model is still downloading or unavailable. Check Apple Intelligence in System Settings."
    case .busy: "The on-device model is busy with another request. Try again in a moment."
    case .unsupportedSchema:
      "Myra's result format is not supported by the on-device model on this Mac. Use a cloud provider or update macOS."
    case .timedOut:
      "The on-device model did not finish within 20 seconds. Myra stopped the request; try again or narrow the request."
    case .cloudTimedOut:
      "The AI provider did not answer within 20 seconds. Myra stopped the request and changed nothing; check your connection or try again."
    case .noPicks: "The on-device model answered without choosing any titles."
    case .missingKey: "Save your own provider API key in AI Settings."
    case .consent: "Enable cloud requests in AI Settings before sending catalogue information."
    case .limit:
      "Your daily AI request limit has been reached. Adjust it in AI Settings if intended."
    case .invalidResponse:
      "The model returned an incomplete or ungrounded response. No changes were applied."
    case .unsafeAction: "This proposed action is unsupported or no longer matches the library."
    case .missingContext(let reason): reason
    case .http(let status):
      "AI provider request failed (HTTP \(status)). Check your model, account, and API limits."
    }
  }
}

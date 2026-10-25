import Foundation

/// Mood presets offered on Home. Each maps to deterministic genre and runtime rules so
/// recommendations work without a language model.
enum MyraMood: String, Codable, CaseIterable, Identifiable, Sendable {
  case cosy, thrilling, funny, mindBending, feelGood, short, background, learn

  var id: String { rawValue }
  var title: String {
    switch self {
    case .cosy: "Cosy"
    case .thrilling: "Thrilling"
    case .funny: "Funny"
    case .mindBending: "Mind-bending"
    case .feelGood: "Feel-good"
    case .short: "Something short"
    case .background: "Background"
    case .learn: "Learn something"
    }
  }

  var preferredGenres: Set<String> {
    switch self {
    case .cosy: ["family", "animation", "romance", "comedy"]
    case .thrilling: ["thriller", "action", "crime", "horror", "adventure"]
    case .funny: ["comedy", "animation"]
    case .mindBending: ["science fiction", "mystery", "thriller", "fantasy"]
    case .feelGood: ["comedy", "family", "romance", "music", "adventure"]
    case .short: []
    case .background: ["comedy", "documentary", "reality", "animation"]
    case .learn: ["documentary", "history"]
    }
  }

  var avoidedGenres: Set<String> {
    switch self {
    case .cosy, .feelGood: ["horror", "war", "thriller"]
    case .funny: ["horror", "war"]
    case .background: ["mystery", "thriller"]
    default: []
    }
  }

  var keywords: [String] {
    switch self {
    case .cosy: ["heartwarming", "gentle", "charming", "friendship", "holiday"]
    case .thrilling: ["chase", "heist", "survival", "suspense", "escape"]
    case .funny: ["comedy", "hilarious", "satire", "quirky"]
    case .mindBending: ["time", "reality", "memory", "twist", "dimension"]
    case .feelGood: ["uplifting", "joy", "dream", "family", "friendship"]
    case .short, .background: []
    case .learn: ["true story", "history", "nature", "science", "biography"]
    }
  }

  var maximumMinutes: Int? { self == .short ? 95 : nil }
}

enum MyraDayPart: String, Sendable {
  case morning, afternoon, evening, lateNight

  init(date: Date, calendar: Calendar) {
    switch calendar.component(.hour, from: date) {
    case 5..<12: self = .morning
    case 12..<17: self = .afternoon
    case 17..<22: self = .evening
    default: self = .lateNight
    }
  }

  var title: String {
    switch self {
    case .morning: "morning"
    case .afternoon: "afternoon"
    case .evening: "evening"
    case .lateNight: "late night"
    }
  }
}

/// Everything the recommender knows about the moment. All values are local; nothing here
/// is sent to a model unless a caller explicitly asks for generated reasons.
struct MyraViewingContext: Sendable {
  var date: Date = .now
  var calendar: Calendar = .current
  var mood: MyraMood?
  /// Explicit minutes the user has. When nil, a budget is inferred from the time of day.
  var availableMinutes: Int?
  var avoidGenres: Set<String> = []
  var languages: Set<String> = []
  var kind: EntertainmentKind?
  var liked: Set<String> = []
  var disliked: Set<String> = []
  /// Titles dismissed with "Not tonight"; excluded for this context only.
  var dismissed: Set<String> = []
  /// Cached interpretive mood tags per title ID (from background tagging), lower-cased.
  var moodTags: [String: [String]] = [:]
  /// Varies novelty jitter so "Another" can rotate results deterministically.
  var seed: UInt64 = 0

  var dayPart: MyraDayPart { MyraDayPart(date: date, calendar: calendar) }
  var isWeekend: Bool { calendar.isDateInWeekend(date) }

  /// The explicit budget, else a conservative guess: weeknight late nights are short.
  var effectiveMinutes: (minutes: Int, explicit: Bool)? {
    if let availableMinutes, availableMinutes > 0 { return (availableMinutes, true) }
    if let moodLimit = mood?.maximumMinutes { return (moodLimit, true) }
    switch (dayPart, isWeekend) {
    case (.lateNight, false): return (110, false)
    case (.lateNight, true), (.evening, false): return (160, false)
    default: return nil
    }
  }
}

struct MyraRecommendation: Identifiable, Sendable {
  var title: EntertainmentTitle
  var score: Double
  var reasons: [String]
  var id: String { title.id }
}

enum MyraRecommender {
  static func recommend(
    titles: [EntertainmentTitle], personal: EntertainmentPersonalData,
    context: MyraViewingContext, limit: Int = 8
  ) -> [MyraRecommendation] {
    let taste = tasteProfile(titles: titles, personal: personal, context: context)
    let budget = context.effectiveMinutes
    let avoided = Set(
      (context.avoidGenres.union(context.mood?.avoidedGenres ?? [])).map { $0.lowercased() })
    let recentCutoff = context.date.addingTimeInterval(-3 * 86_400)
    var results: [MyraRecommendation] = []
    for title in titles {
      // Hard constraints are never traded for score.
      if personal.watched.contains(title.id) || context.disliked.contains(title.id)
        || context.dismissed.contains(title.id)
      {
        continue
      }
      if let kind = context.kind, title.kind != kind { continue }
      if !context.languages.isEmpty,
        !context.languages.contains(title.metadata?.language ?? "")
      {
        continue
      }
      let genres = Set((title.metadata?.genres ?? []).map { $0.lowercased() })
      if !context.avoidGenres.isEmpty,
        !genres.isDisjoint(with: context.avoidGenres.map { $0.lowercased() })
      {
        continue
      }
      let runtime = MyraAIContext.runtime(title)
      if let budget, budget.explicit {
        guard let runtime, runtime <= budget.minutes else { continue }
      } else if let budget, let runtime, runtime > budget.minutes {
        continue
      }

      var reasons: [String] = []
      let mood = moodScore(title: title, genres: genres, context: context)
      if mood >= 0.3, let name = context.mood?.title { reasons.append("Fits \(name.lowercased())") }
      let tasteScore = genres.isEmpty ? 0 : genres.map { taste[$0] ?? 0 }.max() ?? 0
      if tasteScore > 0.5, let genre = genres.max(by: { (taste[$0] ?? 0) < (taste[$1] ?? 0) }) {
        reasons.append("You often watch \(genre)")
      }
      var timeFit = 0.5
      if let runtime {
        if let budget {
          timeFit = 1 - Double(budget.minutes - runtime) / Double(max(budget.minutes, 1)) * 0.6
          reasons.append("\(duration(runtime)) · fits your time")
        } else {
          timeFit = 0.7
        }
      }
      let dayFit = dayPartScore(genres: genres, runtime: runtime, part: context.dayPart)
      let rating = min(max((title.metadata?.rating ?? 5) / 10, 0), 1)
      if rating >= 0.8 { reasons.append(String(format: "Rated %.1f", rating * 10)) }
      let novelty = Double(jitter(title.id, seed: context.seed) % 1000) / 1000

      var score =
        0.35 * mood + 0.2 * tasteScore + 0.15 * timeFit + 0.1 * dayFit + 0.1 * rating
        + 0.1 * novelty
      if !genres.isDisjoint(with: avoided) { score -= 0.5 }
      if let played = title.versions.compactMap(\.lastPlayed).max(), played > recentCutoff,
        title.resumeVersion == nil
      {
        score -= 0.2
      }
      if context.liked.contains(where: { likedID in
        titles.first { $0.id == likedID }?.metadata?.genres.contains {
          genres.contains($0.lowercased())
        } ?? false
      }) {
        score += 0.05
      }
      if title.resumeVersion != nil { reasons.insert("Continue where you left off", at: 0) }
      results.append(.init(title: title, score: score, reasons: Array(reasons.prefix(3))))
    }
    return Array(
      results.sorted { $0.score == $1.score ? $0.id < $1.id : $0.score > $1.score }.prefix(limit))
  }

  /// A short line for the Home banner, e.g. "Friday evening · about 2h 40m free".
  static func headline(for context: MyraViewingContext) -> String {
    let day = context.date.formatted(.dateTime.weekday(.wide))
    guard let budget = context.effectiveMinutes else { return "\(day) \(context.dayPart.title)" }
    return "\(day) \(context.dayPart.title) · about \(duration(budget.minutes)) free"
  }

  static func duration(_ minutes: Int) -> String {
    minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
  }

  /// Normalised genre affinity (0...1) from watched titles, playback history and likes.
  static func tasteProfile(
    titles: [EntertainmentTitle], personal: EntertainmentPersonalData,
    context: MyraViewingContext
  ) -> [String: Double] {
    var counts: [String: Double] = [:]
    for title in titles {
      var weight = 0.0
      if personal.watched.contains(title.id) { weight += 1 }
      if title.versions.contains(where: { $0.lastPlayed != nil }) { weight += 0.5 }
      if context.liked.contains(title.id) { weight += 2 }
      if context.disliked.contains(title.id) { weight -= 1 }
      guard weight != 0 else { continue }
      for genre in title.metadata?.genres ?? [] { counts[genre.lowercased(), default: 0] += weight }
    }
    let maximum = counts.values.max() ?? 0
    guard maximum > 0 else { return [:] }
    return counts.mapValues { max($0, 0) / maximum }
  }

  private static func moodScore(
    title: EntertainmentTitle, genres: Set<String>, context: MyraViewingContext
  ) -> Double {
    guard let mood = context.mood else { return 0.5 }
    if mood == .short { return 0.7 }
    let preferred = mood.preferredGenres
    let genreMatch = preferred.isEmpty ? 0 : min(Double(genres.intersection(preferred).count), 2) / 2
    let tags = context.moodTags[title.id] ?? []
    let tagMatch =
      tags.contains { $0 == mood.rawValue.lowercased() || $0 == mood.title.lowercased() } ? 1.0 : 0
    let overview = (title.metadata?.overview ?? "").lowercased()
    let keywordMatch = mood.keywords.contains { overview.contains($0) } ? 1.0 : 0
    return min(0.6 * genreMatch + 0.3 * tagMatch + 0.2 * keywordMatch, 1)
  }

  private static func dayPartScore(genres: Set<String>, runtime: Int?, part: MyraDayPart) -> Double
  {
    let heavy: Set<String> = ["horror", "war", "drama", "thriller"]
    let light: Set<String> = ["comedy", "animation", "family", "documentary"]
    switch part {
    case .morning, .afternoon:
      return genres.isDisjoint(with: light) ? (genres.isDisjoint(with: heavy) ? 0.5 : 0.3) : 0.9
    case .evening:
      return 0.7
    case .lateNight:
      var score = genres.isDisjoint(with: heavy) ? 0.6 : 0.8
      if let runtime, runtime > 130 { score -= 0.3 }
      return score
    }
  }

  /// Stable FNV-1a hash so ordering is reproducible for a given seed.
  private static func jitter(_ id: String, seed: UInt64) -> UInt64 {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325 ^ seed
    for byte in id.utf8 {
      hash ^= UInt64(byte)
      hash = hash &* 0x0000_0100_0000_01b3
    }
    return hash
  }
}

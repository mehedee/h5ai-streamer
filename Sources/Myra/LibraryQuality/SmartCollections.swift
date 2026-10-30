import Foundation

/// A field a smart collection can test. Each field offers only the operators that make sense for it.
enum SmartField: String, Codable, CaseIterable, Sendable, Identifiable {
  case kind, quality, watched, language, genre, runtime, rating, added

  var id: String { rawValue }

  var title: String {
    switch self {
    case .kind: "Type"
    case .quality: "Quality"
    case .watched: "Watched"
    case .language: "Language"
    case .genre: "Genre"
    case .runtime: "Runtime"
    case .rating: "Rating"
    case .added: "Added"
    }
  }

  var operators: [SmartOperator] {
    switch self {
    case .kind, .quality, .language, .genre: [.is, .isNot]
    case .watched: [.is]
    case .runtime: [.under, .atLeast]
    case .rating: [.atLeast]
    case .added: [.within]
    }
  }

  /// Fixed choices offered by the builder. Language and genre come from the library instead.
  var fixedValues: [String] {
    switch self {
    case .kind: EntertainmentKind.allCases.map(\.rawValue)
    case .quality: ["2160p", "1080p", "720p"]
    case .watched: ["yes", "no"]
    case .runtime: ["30", "60", "90", "120"]
    case .rating: ["6", "7", "7.5", "8"]
    case .added: ["7", "30", "90", "365"]
    case .language, .genre: []
    }
  }

  var isNumeric: Bool {
    switch self {
    case .runtime, .rating, .added: true
    default: false
    }
  }
}

enum SmartOperator: String, Codable, CaseIterable, Sendable, Identifiable {
  case `is`, isNot, under, atLeast, within

  var id: String { rawValue }

  var title: String {
    switch self {
    case .is: "is"
    case .isNot: "is not"
    case .under: "is under"
    case .atLeast: "is at least"
    case .within: "was added in the last (days)"
    }
  }
}

/// One row of the builder: a field, its operator and a value such as "2160p", "30" or "Korean".
struct SmartRule: Codable, Equatable, Sendable {
  var field: SmartField
  var op: SmartOperator
  var value: String

  init(field: SmartField, op: SmartOperator? = nil, value: String) {
    self.field = field
    self.op = op ?? field.operators[0]
    self.value = value
  }

  /// Operators must belong to the field, and numeric fields need a number.
  var isValid: Bool {
    guard field.operators.contains(op) else { return false }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= 80 else { return false }
    if field.isNumeric { return Double(trimmed) != nil }
    return true
  }

  var summary: String {
    "\(field.title) \(op.title) \(value)"
  }
}

/// A saved rule set that updates itself whenever the library changes.
struct SmartCollection: Codable, Identifiable, Equatable, Sendable {
  var id: UUID
  var name: String
  var rules: [SmartRule]
  /// Pinned collections appear as shelves on Home.
  var pinnedToHome: Bool

  init(id: UUID = UUID(), name: String, rules: [SmartRule], pinnedToHome: Bool = false) {
    self.id = id
    self.name = name
    self.rules = rules
    self.pinnedToHome = pinnedToHome
  }
}

/// The facts a rule can test, read once per title.
struct SmartTitleFacts: Equatable, Sendable {
  var kind: EntertainmentKind
  var qualities: Set<String>
  var watched: Bool
  var language: String?
  var genres: Set<String>
  var runtimeMinutes: Int?
  var rating: Double?
  var added: Date

  init(title: EntertainmentTitle, watched: Bool) {
    kind = title.kind
    qualities = Set(
      title.versions.flatMap { version in
        EntertainmentVersion.qualityTokens(in: version.media.entry.name)
      }.compactMap { SmartCollectionRules.resolution(of: $0) })
    self.watched = watched
    language = title.metadata?.language.lowercased()
    genres = Set((title.metadata?.genres ?? []).map { $0.lowercased() })
    runtimeMinutes = title.metadata?.runtimeMinutes
    rating = title.metadata?.rating
    added = title.firstDiscovered
  }
}

/// Rule evaluation and the built-in collections. Pure: no storage, no UI.
enum SmartCollectionRules {
  static let maximumRules = 10
  static let maximumCollections = 200

  /// The two collections pinned to Home, plus two more the builder can show, as in the preview.
  static let defaults: [SmartCollection] = [
    SmartCollection(
      id: UUID(uuidString: "5A1B0000-0000-4000-8000-000000000001")!, name: "Unwatched 4K",
      rules: [SmartRule(field: .quality, value: "2160p"), SmartRule(field: .watched, value: "no")],
      pinnedToHome: true),
    SmartCollection(
      id: UUID(uuidString: "5A1B0000-0000-4000-8000-000000000002")!, name: "Under 30 minutes",
      rules: [SmartRule(field: .runtime, op: .under, value: "30")], pinnedToHome: true),
    SmartCollection(
      id: UUID(uuidString: "5A1B0000-0000-4000-8000-000000000003")!, name: "Added this week",
      rules: [SmartRule(field: .added, value: "7")]),
    SmartCollection(
      id: UUID(uuidString: "5A1B0000-0000-4000-8000-000000000004")!, name: "Series to start",
      rules: [SmartRule(field: .kind, value: "series"), SmartRule(field: .watched, value: "no")]),
  ]

  /// Maps a file-name quality token to a resolution label, or nil for tokens that are not one.
  static func resolution(of token: String) -> String? {
    switch token.lowercased() {
    case "2160p", "4k": "2160p"
    case "1080p": "1080p"
    case "720p": "720p"
    case "480p": "480p"
    default: nil
    }
  }

  static func isValid(_ collection: SmartCollection) -> Bool {
    let name = collection.name.trimmingCharacters(in: .whitespacesAndNewlines)
    return !name.isEmpty && name.count <= 200 && !collection.rules.isEmpty
      && collection.rules.count <= maximumRules && collection.rules.allSatisfy(\.isValid)
  }

  static func matches(_ rule: SmartRule, facts: SmartTitleFacts, now: Date) -> Bool {
    let value = rule.value.trimmingCharacters(in: .whitespacesAndNewlines)
    let lowered = value.lowercased()
    switch rule.field {
    case .kind:
      let same = facts.kind.rawValue == lowered
      return rule.op == .isNot ? !same : same
    case .quality:
      let has = facts.qualities.contains(resolution(of: lowered) ?? lowered)
      return rule.op == .isNot ? !has : has
    case .watched:
      return facts.watched == (lowered == "yes")
    case .language:
      let same = facts.language == lowered
      return rule.op == .isNot ? !same : same
    case .genre:
      let has = facts.genres.contains(lowered)
      return rule.op == .isNot ? !has : has
    case .runtime:
      guard let minutes = facts.runtimeMinutes, let limit = Int(value) else { return false }
      return rule.op == .under ? minutes < limit : minutes >= limit
    case .rating:
      guard let rating = facts.rating, let minimum = Double(value) else { return false }
      return rating >= minimum
    case .added:
      guard let days = Int(value) else { return false }
      return now.timeIntervalSince(facts.added) <= Double(days) * 86_400
    }
  }

  /// Titles matching every rule. A collection without rules matches nothing.
  static func titles(
    matching rules: [SmartRule], in titles: [EntertainmentTitle], watched: Set<String>,
    now: Date = .now
  ) -> [EntertainmentTitle] {
    guard !rules.isEmpty else { return [] }
    return titles.filter { title in
      let facts = SmartTitleFacts(title: title, watched: watched.contains(title.id))
      return rules.allSatisfy { matches($0, facts: facts, now: now) }
    }
  }

  static func count(
    matching rules: [SmartRule], in titles: [EntertainmentTitle], watched: Set<String>,
    now: Date = .now
  ) -> Int {
    self.titles(matching: rules, in: titles, watched: watched, now: now).count
  }

  static func summary(_ rules: [SmartRule]) -> String {
    rules.map(\.summary).joined(separator: " · ")
  }
}

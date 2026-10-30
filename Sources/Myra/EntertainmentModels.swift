import Foundation

enum EntertainmentKind: String, Codable, Sendable, CaseIterable { case movie, series }

struct EntertainmentMetadata: Codable, Sendable, Equatable {
  var providerID: Int
  var title: String
  var overview: String
  var posterURL: URL?
  var rating: Double
  var voteCount: Int
  var releaseDate: String?
  var genres: [String]
  var language: String
  var runtimeMinutes: Int? = nil
  var episodeReleaseDates: [String: String]? = nil
  /// TMDB backdrop (w780). Optional so metadata cached before this field existed still decodes.
  var backdropURL: URL? = nil
  /// Cast and crew when the stored metadata includes them. Nil or empty shows a placeholder.
  var credits: [EntertainmentCredit]? = nil
  /// A trailer link when the stored metadata includes one. The app never looks one up itself.
  var trailerURL: URL? = nil

  /// The trailer to open: only an HTTP(S) link that the metadata already carries.
  var openableTrailerURL: URL? {
    guard let trailerURL, ["http", "https"].contains(trailerURL.scheme?.lowercased() ?? "")
    else { return nil }
    return trailerURL
  }
}

/// One person in the cast or crew list, as the stored metadata describes them.
struct EntertainmentCredit: Codable, Sendable, Equatable {
  var name: String
  var role: String
}

struct EntertainmentVersion: Identifiable, Sendable, Hashable, Codable {
  var media: GlobalSearchResult
  var firstDiscovered: Date
  var progressSeconds: Double = 0
  var duration: Double = 0
  var lastPlayed: Date? = nil
  var season: Int?
  var episode: Int?
  var id: String { media.entry.url.absoluteString }
  static let qualityTokenList = [
    "2160p", "1080p", "720p", "480p", "4K", "BluRay", "WEB-DL", "WEBRip", "HDR", "x265", "x264",
  ]
  /// Release tokens present in a file name, in a fixed order.
  static func qualityTokens(in name: String) -> [String] {
    qualityTokenList.filter { name.localizedCaseInsensitiveContains($0) }
  }
  var quality: String {
    Self.qualityTokens(in: media.entry.name).joined(separator: " · ")
  }
}

struct EntertainmentTitle: Identifiable, Sendable, Codable {
  var id: String
  var name: String
  var year: String?
  var kind: EntertainmentKind
  var versions: [EntertainmentVersion]
  var metadata: EntertainmentMetadata?
  var firstDiscovered: Date { versions.map(\.firstDiscovered).min() ?? .distantPast }
  var latestDiscovered: Date { versions.map(\.firstDiscovered).max() ?? .distantPast }
  func metadataCacheKey(providerID: Int? = nil) -> String {
    let episodes = Set(
      versions.compactMap { version -> String? in
        guard let season = version.season, let episode = version.episode else { return nil }
        return "\(season):\(episode)"
      }
    ).sorted().joined(separator: ",")
    return "tmdb|\(id)|\(providerID ?? 0)|\(episodes)"
  }
  var displayName: String { metadata?.title ?? name }
  var posterURL: URL? { metadata?.posterURL ?? versions.first?.media.artworkURL }
  var latestReleaseDate: String? {
    if kind == .series { return metadata?.episodeReleaseDates?.values.max() }
    return metadata?.releaseDate
  }
  var resumeVersion: EntertainmentVersion? {
    // Never jump back to an older episode when the latest episode has finished.
    let latest = versions.filter { $0.lastPlayed != nil }.max {
      ($0.lastPlayed ?? .distantPast) < ($1.lastPlayed ?? .distantPast)
    }
    guard let latest, latest.progressSeconds >= 5,
      latest.duration == 0 || latest.duration > latest.progressSeconds + 10
    else { return nil }
    return latest
  }
}

struct EntertainmentCollection: Codable, Identifiable, Sendable {
  var id: UUID = UUID()
  var name: String
  var titleIDs: Set<String> = []
}

struct EntertainmentPreferences: Codable, Sendable, Equatable {
  var notifications: Bool = false
}

struct EntertainmentMatchCorrection: Codable, Sendable, Equatable {
  var title: String
  var year: String?
  var kind: EntertainmentKind
  var providerID: Int?
}

struct EntertainmentPlaybackRecord: Codable, Sendable {
  var seconds: Double
  var duration: Double
  var updated: Date
}

struct EntertainmentPersonalData: Codable, Sendable {
  var schemaVersion: Int = 1
  var watchlist: Set<String> = []
  var watched: Set<String> = []
  var collections: [EntertainmentCollection] = []
  var followed: Set<String> = []
  var knownEpisodeIDs: Set<String> = []
  var matchCorrections: [String: EntertainmentMatchCorrection] = [:]
  var preferences = EntertainmentPreferences()
  var history: [String: EntertainmentPlaybackRecord] = [:]
  /// Optional so profiles written before recommendation feedback still decode.
  var recommendationFeedback: MyraRecommendationFeedback?
  /// Automatic Home shelf choices. Nil for personal data written before shelves existed.
  var homeCategories: HomeCategoryPreferences? = nil
  /// Personal 1 to 5 star ratings keyed by title ID. Optional so older profiles still decode.
  var ratings: [String: Int]? = nil
  /// Private notes keyed by title ID. Optional so older profiles still decode.
  var notes: [String: String]? = nil
}

struct MyraRecommendationFeedback: Codable, Sendable, Equatable {
  var liked: Set<String> = []
  var disliked: Set<String> = []
  /// "Not tonight" dismissals; each expires after `dismissalLifetime`.
  var dismissed: [String: Date] = [:]

  static let dismissalLifetime: TimeInterval = 18 * 3600

  func activeDismissals(at date: Date) -> Set<String> {
    Set(dismissed.filter { date.timeIntervalSince($0.value) < Self.dismissalLifetime }.keys)
  }
}

/// Where one file belongs: the title it joins and the episode it carries.
struct EntertainmentPlacement: Sendable, Equatable {
  let key: String
  let name: String
  let year: String?
  let kind: EntertainmentKind
  let season: Int?
  let episode: Int?
}

enum EntertainmentGrouping {
  /// Decides which title one file joins. Pure and independent of every other file, so a catalogue
  /// can be updated one changed file at a time and still match a full regrouping.
  static func placement(
    fileName: String, url: URL, correction: EntertainmentMatchCorrection?
  ) -> EntertainmentPlacement {
    let identity = MediaIdentity.parse(filename: fileName)
    let season = identity.season.flatMap(Int.init)
    let episode = identity.episode.flatMap(Int.init)
    let name = correction?.title ?? identity.title
    let year = correction?.year ?? identity.year
    let kind = correction?.kind ?? (episode == nil ? .movie : .series)
    let normalized = name.folding(
      options: [.caseInsensitive, .diacriticInsensitive],
      locale: Locale(identifier: "en_US_POSIX")
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    // A year, episode token, or explicit correction is required to merge across files.
    let confident = year != nil || episode != nil || correction != nil
    let key: String
    if confident {
      key = "\(kind.rawValue)|\(normalized)|\(year ?? "")"
    } else if !EntertainmentVersion.qualityTokens(in: fileName).isEmpty {
      key = "folder|\(url.deletingLastPathComponent().absoluteString)|\(normalized)"
    } else {
      key = "file|\(url.absoluteString)"
    }
    return EntertainmentPlacement(
      key: key, name: name, year: year, kind: kind, season: season, episode: episode)
  }

  /// Sort key for title names: case and accents ignored, digit runs compared as numbers.
  static func sortKey(_ name: String) -> String {
    let folded = name.folding(
      options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    var result = ""
    var digits = ""
    for character in folded {
      if character.isASCII, character.isNumber {
        digits.append(character)
        continue
      }
      if !digits.isEmpty {
        result += String(repeating: "0", count: max(0, 12 - digits.count)) + digits
        digits = ""
      }
      result.append(character)
    }
    if !digits.isEmpty { result += String(repeating: "0", count: max(0, 12 - digits.count)) + digits }
    return result
  }

  static func orderVersions(_ versions: inout [EntertainmentVersion]) {
    versions.sort {
      if ($0.season ?? 0) != ($1.season ?? 0) { return ($0.season ?? 0) < ($1.season ?? 0) }
      if ($0.episode ?? 0) != ($1.episode ?? 0) { return ($0.episode ?? 0) < ($1.episode ?? 0) }
      let left = $0.media.entry.name
      let right = $1.media.entry.name
      return left != right ? left < right : $0.id < $1.id
    }
  }

  static func group(
    _ versions: [EntertainmentVersion], corrections: [String: EntertainmentMatchCorrection] = [:]
  ) -> [EntertainmentTitle] {
    var titles: [String: EntertainmentTitle] = [:]
    // Placement is pure per file, so large libraries are parsed across the processor cores.
    let placements = ParallelChunks.map(count: versions.count) { range in
      range.map { offset -> EntertainmentPlacement in
        let version = versions[offset]
        return placement(
          fileName: version.media.entry.name, url: version.media.entry.url,
          correction: corrections[version.id])
      }
    }
    for (offset, var version) in versions.enumerated() {
      let placement = placements[offset]
      version.season = placement.season
      version.episode = placement.episode
      let key = placement.key
      if titles[key] == nil {
        titles[key] = EntertainmentTitle(
          id: key, name: placement.name, year: placement.year, kind: placement.kind, versions: [])
      }
      titles[key]?.versions.append(version)
    }
    return titles.values.map { title in
      var value = title
      orderVersions(&value.versions)
      return value
    }.sorted {
      let left = sortKey($0.name)
      let right = sortKey($1.name)
      return left != right ? left < right : $0.id < $1.id
    }
  }
}

import Foundation

enum AttentionKind: String, CaseIterable, Sendable, Identifiable {
  case unmatched, wrongMatch, missingPoster, duplicate

  var id: String { rawValue }

  var title: String {
    switch self {
    case .unmatched: "Unmatched"
    case .wrongMatch: "Wrong match"
    case .missingPoster: "Missing poster"
    case .duplicate: "Duplicates"
    }
  }
}

/// A proposed identity for a title that could not be matched, with a 0 to 100 confidence.
struct AttentionGuess: Equatable, Sendable {
  let title: String
  let year: String?
  let kind: EntertainmentKind
  let confidence: Int
}

/// One title that needs a decision. Nothing here changes the library: accepting an item saves a
/// correction for that title, and original files are never renamed or moved.
struct AttentionItem: Identifiable, Equatable, Sendable {
  let titleID: String
  let kind: AttentionKind
  let displayName: String
  let fileNames: [String]
  let sourceNames: [String]
  let guess: AttentionGuess?
  let note: String

  var id: String { "\(kind.rawValue)|\(titleID)" }

  /// Only a guess at or above the threshold may be accepted in bulk.
  var isConfident: Bool {
    guard kind == .unmatched, let guess else { return false }
    return guess.confidence >= AttentionAnalysis.confidentThreshold
  }
}

/// Finds titles that need a decision. Pure over the catalogue, so it can be tested without a library.
enum AttentionAnalysis {
  static let confidentThreshold = 90

  static func items(for titles: [EntertainmentTitle]) -> [AttentionItem] {
    var result: [AttentionItem] = []
    for title in titles {
      let files = title.versions.map { $0.media.entry.name }
      let sources = Array(Set(title.versions.map { $0.media.categoryName })).sorted()
      func item(_ kind: AttentionKind, guess: AttentionGuess? = nil, note: String) -> AttentionItem {
        AttentionItem(
          titleID: title.id, kind: kind, displayName: title.displayName, fileNames: files,
          sourceNames: sources, guess: guess, note: note)
      }
      if let metadata = title.metadata {
        if let parsed = releaseYear(metadata.releaseDate), let year = title.year, parsed != year {
          result.append(
            item(
              .wrongMatch,
              guess: AttentionGuess(
                title: metadata.title, year: parsed, kind: title.kind, confidence: 60),
              note: "Matched to \(metadata.title) (\(parsed)), but the file says \(year)."))
        }
        if metadata.posterURL == nil, title.posterURL == nil {
          result.append(item(.missingPoster, note: "No poster is saved for this title."))
        }
      } else {
        let guess = AttentionGuess(
          title: title.name, year: title.year, kind: title.kind,
          confidence: title.year == nil ? 60 : 95)
        let note =
          title.year == nil
          ? "No year in the file name, so the title could not be matched."
          : "Best guess from the file name. Accept to confirm it and look up details."
        result.append(item(.unmatched, guess: guess, note: note))
      }
      if hasDuplicateEpisodes(title.versions) {
        result.append(item(.duplicate, note: duplicateNote(title.versions)))
      }
    }
    return result.sorted {
      let order = AttentionKind.allCases
      if $0.kind != $1.kind { return order.firstIndex(of: $0.kind)! < order.firstIndex(of: $1.kind)! }
      return EntertainmentGrouping.sortKey($0.displayName) < EntertainmentGrouping.sortKey($1.displayName)
    }
  }

  /// Items grouped by kind, in display order, for the tabs of the Needs Attention page.
  static func grouped(_ items: [AttentionItem]) -> [(AttentionKind, [AttentionItem])] {
    AttentionKind.allCases.map { kind in (kind, items.filter { $0.kind == kind }) }
  }

  /// The bulk action: every unmatched item whose guess reaches the threshold.
  static func confidentItems(_ items: [AttentionItem]) -> [AttentionItem] {
    items.filter(\.isConfident)
  }

  static func releaseYear(_ date: String?) -> String? {
    guard let date, date.count >= 4 else { return nil }
    let year = String(date.prefix(4))
    return Int(year) != nil ? year : nil
  }

  /// Two or more files for the same movie, or the same episode of a series.
  static func hasDuplicateEpisodes(_ versions: [EntertainmentVersion]) -> Bool {
    var seen = Set<String>()
    for version in versions {
      let key = "\(version.season ?? -1)|\(version.episode ?? -1)"
      if !seen.insert(key).inserted { return true }
    }
    return false
  }

  private static func duplicateNote(_ versions: [EntertainmentVersion]) -> String {
    let qualities = versions.map {
      let height = BestVersionPicker.height(of: $0)
      return height == 0 ? "untagged" : "\(height)p"
    }
    return "Saved \(versions.count) times: \(qualities.joined(separator: " and ")). Choose the one to play first. No file is deleted."
  }
}

import Foundation

/// The version that playback starts for a title with several releases, and the reason it was chosen.
struct BestVersionChoice: Equatable, Sendable {
  let version: EntertainmentVersion
  /// Plain-language explanation shown beside the choice, for example "Matches your preferred 1080p".
  let reason: String
  /// True when the choice follows a per-title "Always use" preference.
  let followsTitlePreference: Bool

  static func == (lhs: BestVersionChoice, rhs: BestVersionChoice) -> Bool {
    lhs.version.id == rhs.version.id && lhs.reason == rhs.reason
      && lhs.followsTitlePreference == rhs.followsTitlePreference
  }
}

/// Picks one release from several. Order of precedence: the title's "Always use" quality, then
/// the global preferred quality, then the highest quality in the file names.
enum BestVersionPicker {
  /// Resolutions a preference can name, best first. "highest" means no preference.
  static let qualityChoices = ["highest", "2160p", "1080p", "720p", "480p"]

  static func height(of version: EntertainmentVersion) -> Int {
    let resolutions = EntertainmentVersion.qualityTokens(in: version.media.entry.name)
      .compactMap { SmartCollectionRules.resolution(of: $0) }
    return resolutions.compactMap { Int($0.dropLast()) }.max() ?? 0
  }

  /// Chooses one version. `titleQuality` and `preferredQuality` are resolution labels such as
  /// "1080p"; nil or "highest" means the best quality available.
  static func choose(
    versions: [EntertainmentVersion], titleQuality: String?, preferredQuality: String?
  ) -> BestVersionChoice? {
    guard !versions.isEmpty else { return nil }
    if let titleQuality, let target = targetHeight(titleQuality) {
      if let exact = versions.first(where: { height(of: $0) == target }) {
        return BestVersionChoice(
          version: exact, reason: "Always use \(titleQuality) for this title",
          followsTitlePreference: true)
      }
      return fallback(versions: versions, target: target, label: titleQuality, reason: "for this title")
    }
    if let preferredQuality, let target = targetHeight(preferredQuality) {
      if let exact = versions.first(where: { height(of: $0) == target }) {
        return BestVersionChoice(
          version: exact, reason: "Matches your preferred \(preferredQuality)",
          followsTitlePreference: false)
      }
      return fallback(versions: versions, target: target, label: preferredQuality, reason: "as preferred")
    }
    return highest(versions: versions)
  }

  private static func targetHeight(_ label: String) -> Int? {
    guard label != "highest", let value = Int(label.dropLast()), label.hasSuffix("p") else {
      return nil
    }
    return value
  }

  /// No release at the wanted quality: take the best one below it, else the best one above it.
  private static func fallback(
    versions: [EntertainmentVersion], target: Int, label: String, reason: String
  ) -> BestVersionChoice {
    let below = versions.filter { height(of: $0) > 0 && height(of: $0) < target }
    let chosen = below.max { height(of: $0) < height(of: $1) }
      ?? versions.min { height(of: $0) < height(of: $1) }
    let version = chosen ?? versions[0]
    let untagged = height(of: version) == 0
    let text =
      untagged
      ? "No \(label) release \(reason). Using the first file, which has no quality tag."
      : "No \(label) release \(reason). Using \(height(of: version))p, the closest available."
    return BestVersionChoice(version: version, reason: text, followsTitlePreference: false)
  }

  private static func highest(versions: [EntertainmentVersion]) -> BestVersionChoice {
    let ranked = versions.enumerated().sorted {
      let left = height(of: $0.element)
      let right = height(of: $1.element)
      return left != right ? left > right : $0.offset < $1.offset
    }
    let version = ranked[0].element
    let best = height(of: version)
    let reason: String
    if best == 0 {
      reason = "Quality is not tagged in the file names, so the first file is used."
    } else if versions.count == 1 {
      reason = "The only release, \(best)p."
    } else {
      reason = "Highest quality available, \(best)p, of \(versions.count) releases."
    }
    return BestVersionChoice(version: version, reason: reason, followsTitlePreference: false)
  }
}

import Foundation

/// What an opened URL means for torrents. Pasted magnets use the same route as opened ones.
enum TorrentLinkRoute: Equatable {
  case magnet(String)
  case torrentFile(URL)
  case ignored
}

enum TorrentLinkRouter {
  static func route(_ url: URL) -> TorrentLinkRoute {
    if url.scheme?.lowercased() == "magnet" { return .magnet(url.absoluteString) }
    if url.isFileURL, url.pathExtension.lowercased() == "torrent" { return .torrentFile(url) }
    return .ignored
  }

  /// Display name from the magnet's `dn` parameter. Nil when absent or blank.
  static func displayName(magnet: String) -> String? {
    guard
      let value = URLComponents(string: magnet)?.queryItems?.first(where: { $0.name == "dn" })?
        .value?.replacingOccurrences(of: "+", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines),
      !value.isEmpty
    else { return nil }
    return value
  }
}

/// A link waiting for the one-time networking consent before it may be used.
enum PendingTorrentLink: Equatable {
  case magnet(String)
  case torrentData(Data)
}

/// One-time privacy consent. Networking starts only after this is granted and the user adds a link.
struct TorrentConsent {
  static let defaultsKey = "torrentNetworkConsentDate"
  let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  var grantedAt: Date? { defaults.object(forKey: Self.defaultsKey) as? Date }
  var isGranted: Bool { grantedAt != nil }

  func grant(at date: Date = .now) {
    defaults.set(date, forKey: Self.defaultsKey)
  }

  func withdraw() {
    defaults.removeObject(forKey: Self.defaultsKey)
  }
}

enum TorrentExportPath {
  /// Path below the shared download folder, e.g. Torrents/<name>/<file path>.
  static func relativePath(jobName: String, file: TorrentFile) -> String {
    let folder = DestinationSafety.sanitize(jobName)
    let components = file.path.split(separator: "/").map { DestinationSafety.sanitize(String($0)) }
    return (["Torrents", folder] + components).joined(separator: "/")
  }
}

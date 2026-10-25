import Foundation

/// Where a remote or local artwork candidate came from.
enum ArtworkOrigin: String, Sendable, Equatable {
  case source, tmdbPoster, tmdbBackdrop, omdbPoster
}

/// One step in the poster fallback chain. The last step is always `.titleCard`.
enum ArtworkCandidate: Equatable, Sendable {
  /// `.source` may be a local file; every other origin is an https URL on an allowed host.
  case image(ArtworkOrigin, URL)
  case titleCard
}

/// Hosts that artwork may be fetched from. Image URLs only; no user data is ever placed in them.
enum ArtworkHostPolicy {
  static let tmdbImageHost = "image.tmdb.org"
  /// Host that OMDb returns poster links on.
  static let omdbPosterHost = "m.media-amazon.com"

  static func allows(_ url: URL, origin: ArtworkOrigin) -> Bool {
    switch origin {
    case .source:
      return url.isFileURL || isHTTPS(url, host: nil)
    case .tmdbPoster, .tmdbBackdrop:
      return isHTTPS(url, host: tmdbImageHost)
    case .omdbPoster:
      return isHTTPS(url, host: omdbPosterHost)
    }
  }

  /// Remote hosts the disk cache and loader may contact.
  static func allowsRemote(_ url: URL) -> Bool {
    isHTTPS(url, host: tmdbImageHost) || isHTTPS(url, host: omdbPosterHost)
  }

  private static func isHTTPS(_ url: URL, host: String?) -> Bool {
    guard url.scheme?.lowercased() == "https", let urlHost = url.host?.lowercased() else {
      return false
    }
    return host == nil || urlHost == host
  }
}

/// Orders the artwork a title can show. It only arranges known URLs and never touches the network.
enum ArtworkResolver {
  /// The fallback chain: source artwork, TMDB poster, TMDB backdrop, OMDb poster, then the title card.
  /// Missing or disallowed URLs are skipped and duplicates are removed.
  static func candidates(for title: EntertainmentTitle, movie: MovieMetadata? = nil) -> [ArtworkCandidate] {
    var ordered: [ArtworkCandidate] = []
    var seen = Set<URL>()
    func append(_ origin: ArtworkOrigin, _ url: URL?) {
      guard let url, ArtworkHostPolicy.allows(url, origin: origin), seen.insert(url).inserted else {
        return
      }
      ordered.append(.image(origin, url))
    }
    append(.source, title.versions.lazy.compactMap { $0.media.artworkURL }.first)
    append(.tmdbPoster, title.metadata?.posterURL)
    append(.tmdbBackdrop, title.metadata?.backdropURL)
    let omdbPoster = movie.flatMap { MovieMetadata.available($0.poster) }
    append(.omdbPoster, omdbPoster.flatMap { URL(string: $0) })
    ordered.append(.titleCard)
    return ordered
  }
}

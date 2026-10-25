import Foundation

/// Loads artwork bytes for `FallbackArtworkView`. Local files are read directly. Remote images are
/// fetched only from allowed hosts, without cookies or credentials, and cached on disk.
actor ArtworkLoader {
  /// Largest image accepted from the network.
  static let maxImageBytes = 8 * 1024 * 1024

  enum LoadError: Error, Equatable {
    case disallowedURL, badResponse, notImage, tooLarge
  }

  static let shared = ArtworkLoader(cache: ArtworkDiskCache(
    storage: FileArtworkCacheStorage(directory: ArtworkDiskCache.defaultDirectory())))

  private let cache: ArtworkDiskCache
  private let session: URLSession

  init(cache: ArtworkDiskCache, session: URLSession? = nil) {
    self.cache = cache
    if let session {
      self.session = session
    } else {
      let config = URLSessionConfiguration.ephemeral
      config.timeoutIntervalForRequest = 15
      config.timeoutIntervalForResource = 25
      config.urlCache = nil
      config.httpCookieStorage = nil
      config.httpShouldSetCookies = false
      config.urlCredentialStorage = nil
      self.session = URLSession(
        configuration: config, delegate: ArtworkRedirectPolicy(), delegateQueue: nil)
    }
  }

  func data(for url: URL) async throws -> Data {
    if url.isFileURL {
      return try Data(contentsOf: url)
    }
    guard ArtworkHostPolicy.allowsRemote(url) else { throw LoadError.disallowedURL }
    if let cached = await cache.data(for: url) { return cached }

    var request = URLRequest(url: url)
    request.httpShouldHandleCookies = false
    request.setValue("image/*", forHTTPHeaderField: "Accept")
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
      throw LoadError.badResponse
    }
    guard http.mimeType?.hasPrefix("image/") == true else { throw LoadError.notImage }
    guard data.count <= Self.maxImageBytes else { throw LoadError.tooLarge }
    try? await cache.store(data, for: url)
    return data
  }
}

/// Refuses redirects to hosts outside the artwork allowlist.
private final class ArtworkRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    let allowed = request.url.map(ArtworkHostPolicy.allowsRemote) ?? false
    completionHandler(allowed ? request : nil)
  }
}

import Foundation

/// API key storage seam. The app uses the Keychain; tests use an in-memory fake.
/// Calls can block, so callers invoke them off the main thread.
protocol IndexerSecretStore: Sendable {
  func key(for id: UUID) throws -> String
  func setKey(_ value: String, for id: UUID) throws
}

struct KeychainIndexerSecretStore: IndexerSecretStore {
  func key(for id: UUID) throws -> String { try TorznabKeyStore.read(id) }
  func setKey(_ value: String, for id: UUID) throws { try TorznabKeyStore.save(value, id: id) }
}

/// Result of pressing Test connection.
struct IndexerTestOutcome: Equatable, Sendable {
  var milliseconds: Int
  var capabilities: [String]
}

/// Talks to the indexers. Every request starts from an explicit user action (Search, Retry,
/// Test connection); the engine never runs by itself.
struct TorrentSearchEngine: Sendable {
  var secrets: any IndexerSecretStore
  /// Per-indexer limit for the whole request.
  var timeout: TimeInterval = 8
  /// Tests inject a configuration with a stub `URLProtocol`.
  var configuration: @Sendable () -> URLSessionConfiguration = {
    let config = URLSessionConfiguration.ephemeral
    config.httpCookieStorage = nil
    config.urlCredentialStorage = nil
    config.urlCache = nil
    return config
  }

  init(secrets: any IndexerSecretStore = KeychainIndexerSecretStore()) {
    self.secrets = secrets
  }

  // MARK: Fan-out

  /// Queries every indexer in parallel. `onFinish` runs on the main actor as each one ends,
  /// so the list can fill in progressively and one failure never hides the others.
  func run(
    query: String, indexers: [TorrentIndexer],
    onFinish: @escaping @MainActor @Sendable (UUID, Result<[TorrentSearchResult], TorrentSearchFailure>) -> Void
  ) async {
    await withTaskGroup(of: Void.self) { group in
      for indexer in indexers {
        group.addTask {
          let outcome: Result<[TorrentSearchResult], TorrentSearchFailure>
          do {
            outcome = .success(try await search(indexer, query: query))
          } catch {
            if Task.isCancelled { return }
            outcome = .failure(Self.failure(from: error))
          }
          await onFinish(indexer.id, outcome)
        }
      }
    }
  }

  func search(_ indexer: TorrentIndexer, query: String) async throws -> [TorrentSearchResult] {
    switch indexer.kind {
    case .blenderOpenMovies:
      return BlenderOpenMovies.results(matching: query, indexer: indexer)
    case .internetArchive:
      let data = try await get(TorrentDiscoveryService.archiveURL(query: query, page: 1))
      let items: [TorrentDiscoveryItem]
      do { items = try TorrentDiscoveryService.parseArchive(data) } catch {
        throw TorrentSearchFailure.notTorznab
      }
      return items.compactMap { item in
        guard let archiveID = item.archiveID else { return nil }
        return TorrentSearchResult(
          id: item.id, title: item.title, indexerID: indexer.id, indexerName: indexer.name,
          archiveID: archiveID, license: item.license, sourceURL: item.sourceURL)
      }
    case .torznab:
      let url = try await torznabSearchURL(indexer, query: query)
      let data = try await get(url)
      return try TorznabParser.parse(data, indexer: indexer).results
    }
  }

  // MARK: Test connection

  /// One capabilities request. Returns the response time and what the indexer supports.
  func test(endpoint: URL, key: String) async throws -> IndexerTestOutcome {
    let source = TorznabSource(name: "Test", endpoint: endpoint)
    guard (try? TorznabSource.validatedEndpoint(endpoint.absoluteString)) != nil else {
      throw TorrentSearchFailure.invalidEndpoint
    }
    var components = URLComponents(url: source.endpoint, resolvingAgainstBaseURL: false)!
    components.queryItems =
      (components.queryItems ?? []).filter {
        !["t", "q", "apikey"].contains($0.name.lowercased())
      } + [.init(name: "t", value: "caps"), .init(name: "apikey", value: key)]
    let clock = ContinuousClock()
    let start = clock.now
    let data = try await get(components.url!)
    let elapsed = start.duration(to: clock.now)
    let probe = TorrentIndexer(
      id: UUID(), name: "Test", kind: .torznab, url: endpoint, enabled: true, isBuiltIn: false)
    let feed = try TorznabParser.parse(data, indexer: probe)
    let milliseconds = Int(elapsed.components.seconds * 1000)
      + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
    return IndexerTestOutcome(milliseconds: milliseconds, capabilities: feed.capabilities)
  }

  // MARK: Transport

  private func torznabSearchURL(_ indexer: TorrentIndexer, query: String) async throws -> URL {
    guard let endpoint = indexer.url else { throw TorrentSearchFailure.invalidEndpoint }
    let secrets = secrets
    let id = indexer.id
    // The Keychain can block; read it on a background thread, never on the main actor.
    let key: String
    do {
      key = try await Task.detached(priority: .userInitiated) { try secrets.key(for: id) }.value
    } catch { throw TorrentSearchFailure.keychain }
    do {
      return try TorrentDiscoveryService.torznabURL(
        source: TorznabSource(id: id, name: indexer.name, endpoint: endpoint), key: key,
        query: query, page: 1, limit: 50)
    } catch { throw TorrentSearchFailure.invalidEndpoint }
  }

  /// GET with the per-indexer deadline, redirect policy, size cap and HTTP status mapping.
  func get(_ url: URL) async throws -> Data {
    guard url.scheme == "https"
      || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(url.host ?? "")),
      url.user == nil, url.password == nil
    else { throw TorrentSearchFailure.invalidEndpoint }
    let seconds = timeout
    return try await withThrowingTaskGroup(of: Data.self) { group in
      group.addTask { try await transfer(url) }
      group.addTask {
        try await Task.sleep(for: .seconds(seconds))
        throw TorrentSearchFailure.timeout
      }
      defer { group.cancelAll() }
      guard let first = try await group.next() else { throw TorrentSearchFailure.unreachable }
      return first
    }
  }

  private func transfer(_ url: URL) async throws -> Data {
    let config = configuration()
    config.timeoutIntervalForRequest = timeout
    config.timeoutIntervalForResource = timeout
    let session = URLSession(
      configuration: config, delegate: TorrentRedirectPolicy(origin: url), delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    var request = URLRequest(url: url)
    request.setValue("application/xml, application/rss+xml, application/json, */*", forHTTPHeaderField: "Accept")
    do {
      let (data, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse else { throw TorrentSearchFailure.notTorznab }
      switch http.statusCode {
      case 200: break
      case 401, 403: throw TorrentSearchFailure.badKey
      default: throw TorrentSearchFailure.http(http.statusCode)
      }
      guard data.count <= TorznabParser.maxBytes else { throw TorrentSearchFailure.tooLarge }
      return data
    } catch let failure as TorrentSearchFailure {
      throw failure
    } catch {
      throw Self.failure(from: error)
    }
  }

  static func failure(from error: Error) -> TorrentSearchFailure {
    if let failure = error as? TorrentSearchFailure { return failure }
    if error is CancellationError { return .timeout }
    if let urlError = error as? URLError {
      switch urlError.code {
      case .timedOut: return .timeout
      case .cancelled: return .timeout
      case .userAuthenticationRequired: return .badKey
      case .dataLengthExceedsMaximum: return .tooLarge
      default: return .unreachable
      }
    }
    return .unreachable
  }
}

/// Curated open-licence films from the Blender Foundation. This is a fixed list, not a
/// network search: the torrents are the official WebTorrent "free torrents" files.
enum BlenderOpenMovies {
  static let license = "Creative Commons Attribution (Blender Foundation) — curated list"
  static let source = URL(string: "https://webtorrent.io/free-torrents")!
  static let titles: [(title: String, slug: String)] = [
    ("Big Buck Bunny", "big-buck-bunny"), ("Cosmos Laundromat", "cosmos-laundromat"),
    ("Sintel", "sintel"), ("Tears of Steel", "tears-of-steel"),
  ]

  static func results(matching query: String, indexer: TorrentIndexer) -> [TorrentSearchResult] {
    let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    return titles.compactMap { entry in
      let name = entry.title.lowercased()
      guard words.allSatisfy({ name.contains($0) }) else { return nil }
      return TorrentSearchResult(
        id: "blender:" + entry.slug, title: entry.title, indexerID: indexer.id,
        indexerName: indexer.name,
        torrentURL: URL(string: "https://webtorrent.io/torrents/" + entry.slug + ".torrent"),
        license: license, sourceURL: source)
    }
  }
}

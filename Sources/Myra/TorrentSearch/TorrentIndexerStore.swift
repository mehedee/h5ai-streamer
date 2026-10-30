import Foundation

/// What the Add Search Indexer sheet collects, and the rules it must pass.
struct IndexerDraft: Equatable, Sendable {
  var name = ""
  var url = ""
  var key = ""

  static let maxCustom = 10

  /// Localhost-only presets for the user's own Jackett or Prowlarr. No third-party site is bundled.
  enum Preset: String, CaseIterable, Identifiable {
    case jackett, prowlarr
    var id: String { rawValue }
    var title: String {
      switch self {
      case .jackett: "Use local Jackett"
      case .prowlarr: "Use local Prowlarr"
      }
    }
    var name: String { self == .jackett ? "Jackett" : "Prowlarr" }
    var url: String {
      self == .jackett
        ? "http://localhost:9117/api/v2.0/indexers/all/results/torznab/"
        : "http://localhost:9696/1/api"
    }
  }

  mutating func apply(_ preset: Preset) {
    name = preset.name
    url = preset.url
  }

  enum Problem: Error, Equatable {
    case emptyName, invalidURL, duplicate, limitReached
    var message: String {
      switch self {
      case .emptyName: "Give the indexer a name."
      case .invalidURL:
        "Use an HTTPS address, or http://localhost for your own Jackett or Prowlarr. Enter the API key in its own field, not in the address."
      case .duplicate: "An indexer with this name or address already exists."
      case .limitReached: "You can add up to \(IndexerDraft.maxCustom) indexers. Remove one first."
      }
    }
  }

  /// Returns the cleaned name and endpoint, or the first problem found.
  func validated(existing: [TorrentIndexer]) throws -> (name: String, url: URL) {
    let cleanName = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
    guard !cleanName.isEmpty else { throw Problem.emptyName }
    guard let endpoint = try? TorznabSource.validatedEndpoint(url) else {
      throw Problem.invalidURL
    }
    let custom = existing.filter { !$0.isBuiltIn }
    guard custom.count < Self.maxCustom else { throw Problem.limitReached }
    guard
      !existing.contains(where: {
        $0.name.caseInsensitiveCompare(cleanName) == .orderedSame || $0.url == endpoint
      })
    else { throw Problem.duplicate }
    return (cleanName, endpoint)
  }
}

/// The persisted list of indexers: built-ins plus the user's Torznab endpoints. Only ids,
/// names, addresses and on/off flags are written to disk; API keys go to the Keychain.
@MainActor
final class TorrentIndexerStore: ObservableObject {
  @Published private(set) var indexers: [TorrentIndexer] = TorrentIndexer.builtIns
  @Published private(set) var loaded = false
  @Published var error: String?

  /// `indexers.json` next to the other torrent data. Nil keeps the list in memory (tests).
  var storageURL: URL?
  /// The older single-purpose `sources.json`; its entries are imported once and kept in place.
  var legacyURL: URL?
  let secrets: any IndexerSecretStore

  init(secrets: any IndexerSecretStore = KeychainIndexerSecretStore()) {
    self.secrets = secrets
  }

  var enabled: [TorrentIndexer] { indexers.filter(\.enabled) }
  var custom: [TorrentIndexer] { indexers.filter { !$0.isBuiltIn } }

  func load() throws {
    var stored: [TorrentIndexer] = []
    if let storageURL, FileManager.default.fileExists(atPath: storageURL.path) {
      let data = try Data(contentsOf: storageURL)
      guard data.count < 1024 * 1024 else { throw TorrentError.invalidSettings }
      stored = try JSONDecoder().decode([TorrentIndexer].self, from: data)
    } else if let legacyURL, FileManager.default.fileExists(atPath: legacyURL.path) {
      let data = try Data(contentsOf: legacyURL)
      guard data.count < 1024 * 1024 else { throw TorrentError.invalidSettings }
      // Same ids, so keys already in the Keychain keep working.
      stored = try JSONDecoder().decode([TorznabSource].self, from: data).map {
        TorrentIndexer(
          id: $0.id, name: $0.name, kind: .torznab, url: $0.endpoint, enabled: true,
          isBuiltIn: false)
      }
    }
    indexers = Self.reconciled(stored)
    loaded = true
  }

  /// Built-ins first (keeping their saved on/off flag), then valid custom entries.
  static func reconciled(_ stored: [TorrentIndexer]) -> [TorrentIndexer] {
    let builtIns = TorrentIndexer.builtIns.map { builtIn -> TorrentIndexer in
      var copy = builtIn
      if let saved = stored.first(where: { $0.id == builtIn.id }) { copy.enabled = saved.enabled }
      return copy
    }
    let custom = stored.filter { entry in
      guard !entry.isBuiltIn, entry.kind == .torznab, let url = entry.url else { return false }
      return (try? TorznabSource.validatedEndpoint(url.absoluteString)) != nil
    }
    return builtIns + custom.prefix(IndexerDraft.maxCustom)
  }

  /// Replaces the in-memory list without saving. For isolated tests.
  func replaceForTesting(_ list: [TorrentIndexer]) {
    indexers = list
    loaded = true
  }

  func setEnabled(_ enabled: Bool, for id: UUID) {
    guard let index = indexers.firstIndex(where: { $0.id == id }),
      indexers[index].enabled != enabled
    else { return }
    indexers[index].enabled = enabled
    persistOrReport()
  }

  /// Validates, stores the key in the Keychain (off the main thread), then saves the list.
  @discardableResult
  func add(_ draft: IndexerDraft) async throws -> TorrentIndexer {
    let (name, url) = try draft.validated(existing: indexers)
    let indexer = TorrentIndexer(
      id: UUID(), name: name, kind: .torznab, url: url, enabled: true, isBuiltIn: false)
    let key = draft.key.trimmingCharacters(in: .whitespacesAndNewlines)
    let secrets = secrets
    try await Task.detached(priority: .userInitiated) {
      try secrets.setKey(key, for: indexer.id)
    }.value
    indexers.append(indexer)
    do { try persist() } catch {
      indexers.removeAll { $0.id == indexer.id }
      let secrets = self.secrets
      try? await Task.detached { try secrets.setKey("", for: indexer.id) }.value
      throw error
    }
    return indexer
  }

  func remove(_ id: UUID) async throws {
    guard let indexer = indexers.first(where: { $0.id == id }), !indexer.isBuiltIn else { return }
    let secrets = secrets
    try await Task.detached(priority: .userInitiated) { try secrets.setKey("", for: id) }.value
    indexers.removeAll { $0.id == id }
    try persist()
  }

  private func persistOrReport() {
    do { try persist() } catch { self.error = error.localizedDescription }
  }

  private func persist() throws {
    guard let storageURL else { return }
    try FileManager.default.createDirectory(
      at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(indexers).write(to: storageURL, options: .atomic)
  }
}

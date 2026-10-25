import CryptoKit
import Foundation

/// One cached image as the storage reports it.
struct ArtworkCacheEntry: Equatable, Sendable {
  let key: String
  let byteCount: Int
  let lastAccess: Date
}

/// Storage behind `ArtworkDiskCache`. The app uses files; tests inject an in-memory store.
protocol ArtworkCacheStorage: Sendable {
  func read(_ key: String) throws -> Data?
  func write(_ data: Data, for key: String, at date: Date) throws
  func touch(_ key: String, at date: Date) throws
  func remove(_ key: String) throws
  func entries() throws -> [ArtworkCacheEntry]
}

/// Stores each image as a file, with the modification date used as the last-access time.
struct FileArtworkCacheStorage: ArtworkCacheStorage {
  let directory: URL

  func read(_ key: String) throws -> Data? {
    let url = directory.appending(path: key)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try Data(contentsOf: url)
  }

  func write(_ data: Data, for key: String, at date: Date) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: key)
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
  }

  func touch(_ key: String, at date: Date) throws {
    let url = directory.appending(path: key)
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
  }

  func remove(_ key: String) throws {
    let url = directory.appending(path: key)
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    try FileManager.default.removeItem(at: url)
  }

  func entries() throws -> [ArtworkCacheEntry] {
    guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
    let urls = try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
    return urls.compactMap { url in
      guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
        let size = values.fileSize
      else { return nil }
      return ArtworkCacheEntry(
        key: url.lastPathComponent, byteCount: size,
        lastAccess: values.contentModificationDate ?? .distantPast)
    }
  }
}

/// Caches downloaded artwork with a size cap. Eviction removes the least recently used images first.
actor ArtworkDiskCache {
  /// Cap on the total size of cached artwork.
  static let defaultByteLimit = 256 * 1024 * 1024
  /// Folder inside the app support directory that holds cached artwork.
  static let folderName = "Artwork"

  private let storage: ArtworkCacheStorage
  private let byteLimit: Int
  private let clock: @Sendable () -> Date

  init(
    storage: ArtworkCacheStorage,
    byteLimit: Int = ArtworkDiskCache.defaultByteLimit,
    clock: @escaping @Sendable () -> Date = { .now }
  ) {
    self.storage = storage
    self.byteLimit = byteLimit
    self.clock = clock
  }

  /// `<Application Support>/com.mehedee.Myra/Artwork`, falling back to the temporary directory.
  static func defaultDirectory(fileManager: FileManager = .default) -> URL {
    let base =
      (try? fileManager.url(
        for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
      ?? fileManager.temporaryDirectory
    return base.appending(path: AppPersistence.applicationSupportFolder, directoryHint: .isDirectory)
      .appending(path: folderName, directoryHint: .isDirectory)
  }

  static func key(for url: URL) -> String {
    SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  /// Returns cached bytes and marks them as used.
  func data(for url: URL) -> Data? {
    let key = Self.key(for: url)
    guard let data = try? storage.read(key) else { return nil }
    try? storage.touch(key, at: clock())
    return data
  }

  func store(_ data: Data, for url: URL) throws {
    try storage.write(data, for: Self.key(for: url), at: clock())
    try trim()
  }

  /// Removes the least recently used entries until the total is within the byte limit.
  func trim() throws {
    var entries = try storage.entries()
    var total = entries.reduce(0) { $0 + $1.byteCount }
    guard total > byteLimit else { return }
    entries.sort { ($0.lastAccess, $0.key) < ($1.lastAccess, $1.key) }
    for entry in entries where total > byteLimit {
      try storage.remove(entry.key)
      total -= entry.byteCount
    }
  }
}

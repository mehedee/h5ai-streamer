import Foundation

/// What Myra keeps on disk, grouped as the Storage view shows it. Only `reclaimableBytes` may be
/// removed by the one-click cleanup; the library index, backups and artwork are kept.
struct StorageSummary: Equatable, Sendable {
  var libraryIndexBytes: Int64
  var backupBytes: Int64
  var artworkBytes: Int64
  /// Regenerable caches that cleanup would remove (legacy Home cache, extra backups, staging).
  var reclaimableBytes: Int64
  var homeCacheBytes: Int64

  var totalBytes: Int64 { libraryIndexBytes + backupBytes + artworkBytes + reclaimableBytes }

  /// The library index and its SQLite side files.
  static func indexFileBytes(at indexURL: URL, fileManager: FileManager = .default) -> Int64 {
    ["", "-wal", "-shm"].reduce(Int64(0)) { total, suffix in
      total + DirectorySize.bytes(of: URL(fileURLWithPath: indexURL.path + suffix), fileManager: fileManager)
    }
  }

  static func make(
    indexURL: URL, backupsURL: URL, artworkURL: URL, reclaimable: [LibraryCleanup.Candidate],
    fileManager: FileManager = .default
  ) -> StorageSummary {
    StorageSummary(
      libraryIndexBytes: indexFileBytes(at: indexURL, fileManager: fileManager),
      backupBytes: DirectorySize.bytes(of: backupsURL, fileManager: fileManager),
      artworkBytes: DirectorySize.bytes(of: artworkURL, fileManager: fileManager),
      reclaimableBytes: reclaimable.reduce(0) { $0 + $1.bytes },
      homeCacheBytes: reclaimable.filter { $0.kind == .legacyHomeCache }.reduce(0) { $0 + $1.bytes })
  }

  /// Share of the total for a bar segment, between 0 and 1.
  static func share(_ bytes: Int64, of total: Int64) -> Double {
    guard total > 0 else { return 0 }
    return min(1, Double(bytes) / Double(total))
  }

  static func formatted(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }
}

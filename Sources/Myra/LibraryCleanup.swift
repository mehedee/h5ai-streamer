import Foundation

/// Reclaims regenerable caches. It never touches the library database, settings, personal data,
/// the SwiftData store, downloads or credentials: only files that Myra can rebuild.
enum LibraryCleanup {
  enum Kind: String, Sendable {
    /// The 4.0 JSON home cache (or its renamed copy) once the database catalogue has replaced it.
    case legacyHomeCache
    /// A database or personal-data backup beyond the newest one.
    case oldBackup
    /// A leftover staging folder from an interrupted index run.
    case stagingFolder
  }

  struct Candidate: Equatable, Sendable {
    let url: URL
    let kind: Kind
    let bytes: Int64
  }

  struct Report: Equatable, Sendable {
    var removed: [Candidate] = []
    var failed: [String] = []
    var reclaimedBytes: Int64 { removed.reduce(0) { $0 + $1.bytes } }
  }

  private static func size(of url: URL) -> Int64 {
    var total: Int64 = 0
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
    if isDirectory.boolValue {
      let enumerator = FileManager.default.enumerator(
        at: url, includingPropertiesForKeys: [.fileSizeKey])
      while let item = enumerator?.nextObject() as? URL {
        total += Int64((try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
      }
    } else {
      total = Int64((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0)
    }
    return total
  }

  private static func modified(_ url: URL) -> Date {
    (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
      ?? .distantPast
  }

  /// Everything that would be removed, without removing it. `catalogueVerified` must be true
  /// before the JSON cache counts as regenerable.
  static func plan(
    libraryIndexURL: URL, catalogueVerified: Bool, temporaryDirectory: URL = FileManager.default.temporaryDirectory
  ) -> [Candidate] {
    var result: [Candidate] = []
    let manager = FileManager.default
    let directory = libraryIndexURL.deletingLastPathComponent()
    let base = libraryIndexURL.lastPathComponent
    if catalogueVerified {
      for name in ["\(base).home-cache", "\(base).home-cache.retired"] {
        let url = directory.appending(path: name)
        if manager.fileExists(atPath: url.path) {
          result.append(Candidate(url: url, kind: .legacyHomeCache, bytes: size(of: url)))
        }
      }
    }
    let names = (try? manager.contentsOfDirectory(atPath: directory.path)) ?? []
    // Library-database backups (pre-4.1 and schema-migration copies): keep only the newest.
    let databaseBackups = names.filter { $0.hasPrefix(base + ".") && $0.hasSuffix("-backup") }
      .map { directory.appending(path: $0) }.sorted { modified($0) > modified($1) }
    for url in databaseBackups.dropFirst() {
      result.append(Candidate(url: url, kind: .oldBackup, bytes: size(of: url)))
    }
    // Personal-data import backups: keep only the newest.
    let personalBackups = names.filter {
      $0.hasPrefix("EntertainmentPersonal.backup-") && $0.hasSuffix(".json")
    }.map { directory.appending(path: $0) }.sorted { modified($0) > modified($1) }
    for url in personalBackups.dropFirst() {
      result.append(Candidate(url: url, kind: .oldBackup, bytes: size(of: url)))
    }
    for name in (try? manager.contentsOfDirectory(atPath: temporaryDirectory.path)) ?? []
    where name.hasPrefix("Myra-staging-") {
      let url = temporaryDirectory.appending(path: name)
      // A run in progress was touched moments ago.
      if Date.now.timeIntervalSince(modified(url)) > 3600 {
        result.append(Candidate(url: url, kind: .stagingFolder, bytes: size(of: url)))
      }
    }
    return result
  }

  static func perform(_ candidates: [Candidate]) -> Report {
    var report = Report()
    for candidate in candidates {
      do {
        try FileManager.default.removeItem(at: candidate.url)
        report.removed.append(candidate)
      } catch {
        report.failed.append("\(candidate.url.lastPathComponent): \(error.localizedDescription)")
      }
    }
    return report
  }
}

extension LibraryController {
  /// Regenerable caches that cleanup would remove, with their sizes.
  func reclaimableCaches() async -> [LibraryCleanup.Candidate] {
    guard let index = try? await database() else { return [] }
    var verified = (try? await index.catalogueState())?.legacyRetired ?? false
    if !verified { verified = (try? await index.verifyCatalogue())?.ok ?? false }
    return LibraryCleanup.plan(libraryIndexURL: index.url, catalogueVerified: verified)
  }

  /// Removes regenerable caches only; the library, settings and credentials are untouched.
  @discardableResult
  func cleanUpRegenerableCaches() async -> LibraryCleanup.Report {
    LibraryCleanup.perform(await reclaimableCaches())
  }
}

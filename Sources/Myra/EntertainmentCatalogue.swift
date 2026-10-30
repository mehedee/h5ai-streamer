import Foundation
import OSLog

/// How a catalogue was obtained. Reported for diagnostics and tests.
enum CatalogueRoute: Equatable, Sendable {
  /// Read straight from the saved compact catalogue; nothing changed since it was written.
  case saved
  /// The saved catalogue plus the files that changed since (index only the delta).
  case incremental(files: Int)
  /// Built from every indexed file and saved: first launch of this version, or a format change.
  case built
  /// The database route failed; titles were grouped in memory and nothing was saved.
  case memoryFallback(String)
}

enum CatalogueError: LocalizedError {
  case verificationFailed(CatalogueVerification)
  var errorDescription: String? {
    switch self {
    case .verificationFailed(let check):
      "The compact catalogue did not match the library (\(check.versions) of \(check.videos) files)."
    }
  }
}

/// Reads the retired 4.0 JSON home cache without decoding it: just enough to compare counts.
enum LegacyHomeCache {
  static func url(for index: LibraryIndex) -> URL { index.url.appendingPathExtension("home-cache") }
  static func retiredURL(for index: LibraryIndex) -> URL {
    index.url.appendingPathExtension("home-cache.retired")
  }
  static func backupURL(for index: LibraryIndex) -> URL {
    index.url.appendingPathExtension("pre-4.1-backup")
  }

  struct Summary: Equatable, Sendable {
    var revision: Int?
    var titles: Int
    var versions: Int
  }

  /// Counts titles (`"kind":`) and files (`"relativePath":`) by scanning the mapped file. Quotes
  /// inside strings are escaped in JSON, so neither marker can occur inside a value.
  static func summary(of file: URL) -> Summary? {
    guard let data = try? Data(contentsOf: file, options: .alwaysMapped), !data.isEmpty else {
      return nil
    }
    var revision: Int?
    let head = String(decoding: data.prefix(4096), as: UTF8.self)
    if let match = head.range(of: "\"revision\":[0-9]+", options: .regularExpression) {
      revision = Int(head[match].dropFirst("\"revision\":".count))
    }
    return Summary(
      revision: revision, titles: occurrences(of: "\"kind\":", in: data),
      versions: occurrences(of: "\"relativePath\":", in: data))
  }

  static func occurrences(of marker: String, in data: Data) -> Int {
    let needle = Array(marker.utf8)
    guard let first = needle.first else { return 0 }
    return data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Int in
      guard let base = buffer.baseAddress else { return 0 }
      var total = 0
      var offset = 0
      let length = buffer.count
      while offset < length {
        guard
          let found = memchr(base + offset, Int32(first), length - offset)
        else { break }
        let position = base.distance(to: UnsafeRawPointer(found))
        if position + needle.count <= length,
          memcmp(base + position, needle, needle.count) == 0
        {
          total += 1
        }
        offset = position + 1
      }
      return total
    }
  }
}

actor EntertainmentCatalogueWorker {
  struct Prepared: Sendable {
    var titles: [EntertainmentTitle]
    let enrichmentIDs: Set<String>
    let metadataQueryCount: Int
    var route: CatalogueRoute = .saved
  }

  private let logger = Logger(subsystem: "Myra", category: "Catalogue")

  /// Many changed files are cheaper to regroup in bulk than to place one at a time.
  static func shouldRebuild(dirty: Int, saved: Int) -> Bool { dirty > max(3000, saved / 4) }

  func prepare(index: LibraryIndex, personal: EntertainmentPersonalData) async throws -> Prepared {
    let started = Date.now
    let prepareMark = MyraPerformance.begin(PerfMark.cataloguePrepare)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let corrections = personal.matchCorrections
    let correctionsData = try encoder.encode(corrections)
    var route: CatalogueRoute = .saved
    var queries = 0
    do {
      let state = try await index.catalogueState()
      if let state, state.format == LibraryIndex.catalogueFormat {
        let dirty = try await index.catalogueDirtyCount()
        if dirty > 0 || state.corrections != correctionsData {
          if Self.shouldRebuild(dirty: dirty, saved: state.versionTotal) {
            queries = try await buildFull(
              index: index, corrections: corrections, data: correctionsData, first: false)
            route = .built
          } else {
            let mark = MyraPerformance.begin(PerfMark.catalogueBuild)
            let summary = try await index.updateCatalogue(
              corrections: corrections, correctionsData: correctionsData)
            queries = summary.metadataQueries
            route = .incremental(files: summary.processedFiles)
            mark.end("incremental \(summary.processedFiles) files, \(summary.titlesTouched) titles")
          }
        }
      } else {
        queries = try await buildFull(
          index: index, corrections: corrections, data: correctionsData, first: state == nil)
        route = .built
      }
      let loadMark = MyraPerformance.begin(PerfMark.homeCacheLoad)
      let loaded = try await index.loadCatalogue()
      loadMark.end("\(loaded.titles.count) titles")
      if route == .built || route != .saved {
        let check = try await index.verifyCatalogue()
        guard check.ok else { throw CatalogueError.verificationFailed(check) }
      }
      try await retireLegacyCacheIfVerified(index: index)
      prepareMark.end("\(route) \(loaded.titles.count) titles in \(Date.now.timeIntervalSince(started))s")
      return Prepared(
        titles: loaded.titles, enrichmentIDs: loaded.enrichmentIDs, metadataQueryCount: queries,
        route: route)
    } catch is CancellationError {
      prepareMark.end("cancelled")
      throw CancellationError()
    } catch {
      logger.error("Compact catalogue unavailable, grouping in memory: \(error.localizedDescription)")
      let fallback = try await buildInMemory(index: index, corrections: corrections)
      prepareMark.end("memory fallback")
      return Prepared(
        titles: fallback.titles, enrichmentIDs: fallback.enrichmentIDs,
        metadataQueryCount: fallback.queries, route: .memoryFallback(error.localizedDescription))
    }
  }

  /// Builds and saves the whole catalogue. On the very first build the library database is backed
  /// up first, so a rollback to the previous version always finds its original data.
  private func buildFull(
    index: LibraryIndex, corrections: [String: EntertainmentMatchCorrection], data: Data,
    first: Bool
  ) async throws -> Int {
    let mark = MyraPerformance.begin(PerfMark.catalogueBuild)
    if first, (try? await index.videoCount()) ?? 0 > 0 {
      let backup = LegacyHomeCache.backupURL(for: index)
      if !FileManager.default.fileExists(atPath: backup.path) {
        try await index.backup(to: backup)
      }
    }
    var stage = MyraPerformance.begin("catalogue.build.inventory")
    let inventory = try await index.catalogueInventory()
    stage.end("\(inventory.versions.count) files")
    stage = MyraPerformance.begin("catalogue.build.group")
    let titles = EntertainmentGrouping.group(inventory.versions, corrections: corrections)
    stage.end("\(titles.count) titles")
    stage = MyraPerformance.begin("catalogue.build.metadata")
    let resolved = try await index.resolveCatalogueMetadata(for: titles, corrections: corrections)
    stage.end("\(resolved.queries) queries")
    stage = MyraPerformance.begin("catalogue.build.write")
    try await index.replaceCatalogue(
      titles: titles, metadata: resolved.entries, corrections: data, skipped: inventory.skipped)
    stage.end()
    mark.end("full \(titles.count) titles, \(inventory.versions.count) files")
    return resolved.queries
  }

  /// Retires the 4.0 JSON cache once the database catalogue is verified. The file is renamed, not
  /// deleted, so it can be restored; `LibraryCleanup` removes it when space is reclaimed. If the
  /// JSON describes the same index revision but different counts, it is left where it is.
  private func retireLegacyCacheIfVerified(index: LibraryIndex) async throws {
    guard let state = try await index.catalogueState(), !state.legacyRetired else { return }
    let legacy = LegacyHomeCache.url(for: index)
    guard FileManager.default.fileExists(atPath: legacy.path) else {
      try await index.markLegacyCacheRetired()
      return
    }
    let check = try await index.verifyCatalogue()
    guard check.ok else { return }
    if let old = LegacyHomeCache.summary(of: legacy),
      old.revision == (try await index.revision()), old.versions != check.versions
        || old.titles != check.titles
    {
      logger.error(
        "Legacy home cache has \(old.titles) titles / \(old.versions) files, catalogue has \(check.titles) / \(check.versions); keeping the JSON")
      return
    }
    let retired = LegacyHomeCache.retiredURL(for: index)
    try? FileManager.default.removeItem(at: retired)
    try FileManager.default.moveItem(at: legacy, to: retired)
    try await index.markLegacyCacheRetired()
  }

  private struct MemoryResult {
    var titles: [EntertainmentTitle]
    var enrichmentIDs: Set<String>
    var queries: Int
  }

  /// Last resort: the pre-4.1 behaviour without a saved catalogue.
  private func buildInMemory(
    index: LibraryIndex, corrections: [String: EntertainmentMatchCorrection]
  ) async throws -> MemoryResult {
    let versions = try await index.inventory()
    var titles = EntertainmentGrouping.group(versions, corrections: corrections)
    let resolved = try await index.resolveCatalogueMetadata(for: titles, corrections: corrections)
    let decoder = JSONDecoder()
    var enrichment: Set<String> = []
    let cutoff = Date.now.timeIntervalSince1970 - LibraryIndex.metadataFreshness
    for offset in titles.indices {
      guard let entry = resolved.entries[titles[offset].id] else { continue }
      if let payload = entry.payload {
        titles[offset].metadata = try? decoder.decode(
          EntertainmentMetadata.self, from: Data(payload.utf8))
      }
      if entry.fetched < cutoff, entry.attempt < cutoff { enrichment.insert(titles[offset].id) }
    }
    return MemoryResult(titles: titles, enrichmentIDs: enrichment, queries: resolved.queries)
  }
}

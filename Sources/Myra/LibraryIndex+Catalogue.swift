import CSQLite
import Foundation

/// The compact catalogue: Home's titles, grouped and ready to read, stored in the library database
/// instead of a 100 MB+ JSON file.
///
/// Why the library's own SQLite file rather than SwiftData: the videos, playback positions and
/// metadata cache already live there, so a catalogue row is one indexed join away from its files;
/// writes share one transaction with the index revision; triggers record changed files so the
/// catalogue is updated incrementally; and no model graph has to be faulted in for 30,000 titles.
/// Every change is additive (new tables and triggers, same `user_version`), so an older Myra opens
/// the file after a rollback and simply ignores them.

struct CatalogueStateRecord: Sendable {
  var format: Int
  /// Match corrections the catalogue was grouped with (JSON, sorted keys).
  var corrections: Data
  var built: Date
  var versionTotal: Int
  var titleTotal: Int
  /// Files the build could not represent (unparseable address). Counted in verification.
  var skipped: Int
  /// True once the legacy JSON home cache has been retired.
  var legacyRetired: Bool
  var aliasesSynced: Bool
}

/// The saved metadata for one title, as resolved from the metadata cache table.
struct CatalogueMetadataEntry: Sendable {
  /// Raw JSON of `EntertainmentMetadata`; nil when none is cached.
  var payload: String?
  /// When the exact cache record was fetched (0 when only an older base record exists).
  var fetched: Double
  /// When a lookup for this title last ended without a confident match (0 if never).
  var attempt: Double
}

struct CatalogueLoad: Sendable {
  var titles: [EntertainmentTitle]
  var enrichmentIDs: Set<String>
}

struct CatalogueUpdateSummary: Sendable, Equatable {
  var processedFiles = 0
  var titlesTouched = 0
  var metadataQueries = 0
}

struct CatalogueVerification: Sendable, Equatable {
  var videos: Int
  var versions: Int
  var skipped: Int
  var titles: Int
  var versionsOfTitles: Int
  var orphanVersions: Int
  var ok: Bool {
    versions + skipped == videos && versionsOfTitles == versions && orphanVersions == 0
  }
}

extension LibraryIndex {
  static let catalogueFormat = 3
  static let metadataFreshness: TimeInterval = 7 * 86400

  static let catalogueSchema = """
    CREATE TABLE IF NOT EXISTS catalogue_state(id INTEGER PRIMARY KEY CHECK(id=1),
      format INTEGER NOT NULL, corrections BLOB NOT NULL, built REAL NOT NULL,
      versions INTEGER NOT NULL, titles INTEGER NOT NULL, skipped INTEGER NOT NULL DEFAULT 0,
      legacy_retired INTEGER NOT NULL DEFAULT 0, aliases_synced INTEGER NOT NULL DEFAULT 0);
    CREATE TABLE IF NOT EXISTS catalogue_titles(id TEXT PRIMARY KEY, name TEXT NOT NULL,
      sort_key TEXT NOT NULL, year TEXT, kind TEXT NOT NULL, metadata TEXT,
      meta_fetched REAL NOT NULL DEFAULT 0, attempt_at REAL NOT NULL DEFAULT 0,
      version_count INTEGER NOT NULL DEFAULT 0);
    CREATE INDEX IF NOT EXISTS catalogue_titles_sort ON catalogue_titles(sort_key,id);
    CREATE TABLE IF NOT EXISTS catalogue_versions(category TEXT NOT NULL, url TEXT NOT NULL,
      title_id TEXT NOT NULL, season INTEGER, episode INTEGER,
      PRIMARY KEY(category,url)) WITHOUT ROWID;
    CREATE INDEX IF NOT EXISTS catalogue_versions_title ON catalogue_versions(title_id);
    CREATE TABLE IF NOT EXISTS catalogue_dirty(category TEXT NOT NULL, url TEXT NOT NULL,
      PRIMARY KEY(category,url)) WITHOUT ROWID;
    CREATE TRIGGER IF NOT EXISTS catalogue_video_insert AFTER INSERT ON videos BEGIN
      INSERT OR IGNORE INTO catalogue_dirty VALUES(new.category,new.url); END;
    CREATE TRIGGER IF NOT EXISTS catalogue_video_update AFTER UPDATE OF name ON videos
      WHEN new.name IS NOT old.name BEGIN
      INSERT OR IGNORE INTO catalogue_dirty VALUES(new.category,new.url); END;
    CREATE TRIGGER IF NOT EXISTS catalogue_video_delete AFTER DELETE ON videos BEGIN
      INSERT OR IGNORE INTO catalogue_dirty VALUES(old.category,old.url); END;
    """

  // MARK: - State

  func catalogueState() throws -> CatalogueStateRecord? {
    let statement = try prepare(
      "SELECT format,corrections,built,versions,titles,skipped,legacy_retired,aliases_synced FROM catalogue_state WHERE id=1"
    )
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
    let length = Int(sqlite3_column_bytes(statement, 1))
    let corrections =
      length > 0 && sqlite3_column_blob(statement, 1) != nil
      ? Data(bytes: sqlite3_column_blob(statement, 1), count: length) : Data()
    return CatalogueStateRecord(
      format: Int(sqlite3_column_int64(statement, 0)), corrections: corrections,
      built: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
      versionTotal: Int(sqlite3_column_int64(statement, 3)),
      titleTotal: Int(sqlite3_column_int64(statement, 4)),
      skipped: Int(sqlite3_column_int64(statement, 5)),
      legacyRetired: sqlite3_column_int64(statement, 6) != 0,
      aliasesSynced: sqlite3_column_int64(statement, 7) != 0)
  }

  func clearCatalogueDirty() throws { try execute("DELETE FROM catalogue_dirty") }

  func catalogueDirtyCount() throws -> Int { try count("SELECT COUNT(*) FROM catalogue_dirty") }

  /// Forgets the saved catalogue so the next prepare rebuilds it. Videos are untouched.
  func discardCatalogue() throws {
    try transaction {
      try execute("DELETE FROM catalogue_state")
      try execute("DELETE FROM catalogue_titles")
      try execute("DELETE FROM catalogue_versions")
      try execute("DELETE FROM catalogue_dirty")
    }
  }

  func markLegacyCacheRetired() throws {
    try execute("UPDATE catalogue_state SET legacy_retired=1 WHERE id=1")
  }

  // MARK: - Reading the inventory for a build

  /// All indexed files with playback, without the per-row boundary re-check that `inventory()`
  /// performs: rows were validated when written. Rows with an unparseable address are counted.
  func catalogueInventory() throws -> (versions: [EntertainmentVersion], skipped: Int) {
    try clearCatalogueDirty()
    let statement = try prepare(
      """
      SELECT category,category_name,root,videos.url,name,relative_path,artwork,size,modified,
        first_discovered,COALESCE(playback.seconds,0),COALESCE(playback.duration,0),playback.updated
      FROM videos LEFT JOIN playback ON playback.url=videos.url
      """)
    defer { sqlite3_finalize(statement) }
    var versions: [EntertainmentVersion] = []
    var skipped = 0
    var roots: [String: URL] = [:]
    var status = sqlite3_step(statement)
    while status == SQLITE_ROW {
      try Task.checkCancellation()
      let rootText = string(statement, 2)
      let root: URL?
      if let cached = roots[rootText] {
        root = cached
      } else {
        root = URL(string: rootText)
        if let root { roots[rootText] = root }
      }
      if let category = UUID(uuidString: string(statement, 0)), let root,
        let url = URL(string: string(statement, 3))
      {
        let media = GlobalSearchResult(
          categoryID: category, categoryName: string(statement, 1), categoryRoot: root,
          entry: DirectoryEntry(
            name: string(statement, 4), url: url, kind: .file,
            size: sqlite3_column_type(statement, 7) == SQLITE_NULL
              ? nil : sqlite3_column_int64(statement, 7),
            modifiedAt: sqlite3_column_type(statement, 8) == SQLITE_NULL
              ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 8))),
          relativePath: string(statement, 5), artworkURL: URL(string: string(statement, 6)))
        versions.append(
          EntertainmentVersion(
            media: media,
            firstDiscovered: Date(timeIntervalSince1970: sqlite3_column_double(statement, 9)),
            progressSeconds: sqlite3_column_double(statement, 10),
            duration: sqlite3_column_double(statement, 11),
            lastPlayed: sqlite3_column_type(statement, 12) == SQLITE_NULL
              ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 12))))
      } else {
        skipped += 1
      }
      status = sqlite3_step(statement)
    }
    guard status == SQLITE_DONE else { throw databaseError() }
    return (versions, skipped)
  }

  // MARK: - Metadata resolution

  /// Resolves the cached metadata of titles in batches of 200 (at most 600 keys per query).
  /// The record for the title's exact episode set wins; an older base record is the fallback.
  func resolveCatalogueMetadata(
    for titles: [EntertainmentTitle], corrections: [String: EntertainmentMatchCorrection]
  ) throws -> (entries: [String: CatalogueMetadataEntry], queries: Int) {
    var entries: [String: CatalogueMetadataEntry] = [:]
    var queries = 0
    let decoder = JSONDecoder()
    for start in stride(from: 0, to: titles.count, by: 200) {
      try Task.checkCancellation()
      let end = min(start + 200, titles.count)
      var keys: [String] = []
      keys.reserveCapacity((end - start) * 3)
      var names: [(key: String, base: String, attempt: String)] = []
      for offset in start..<end {
        let title = titles[offset]
        let correction = title.versions.first.flatMap { corrections[$0.id] }
        let key = title.metadataCacheKey(providerID: correction?.providerID)
        let base = "tmdb-base|\(title.id)|\(correction?.providerID ?? 0)"
        let attempt = "tmdb-attempt|\(key)"
        keys += [key, base, attempt]
        names.append((key, base, attempt))
      }
      let records = try metadataRecords(keys: keys)
      queries += 1
      for (offset, name) in names.enumerated() {
        let title = titles[start + offset]
        let exact = records[name.key]
        let chosen = exact ?? records[name.base]
        var payload: String?
        if let chosen, (try? decoder.decode(EntertainmentMetadata.self, from: Data(chosen.payload.utf8))) != nil {
          payload = chosen.payload
        }
        entries[title.id] = CatalogueMetadataEntry(
          payload: payload, fetched: exact?.fetched ?? 0, attempt: records[name.attempt]?.fetched ?? 0)
      }
    }
    return (entries, queries)
  }

  // MARK: - Full build

  /// Replaces the catalogue in one transaction. Nothing is visible until it commits.
  func replaceCatalogue(
    titles: [EntertainmentTitle], metadata: [String: CatalogueMetadataEntry], corrections: Data,
    skipped: Int
  ) throws {
    try transaction {
      try execute("DELETE FROM catalogue_titles")
      try execute("DELETE FROM catalogue_versions")
      let insertTitle = try prepare(
        "INSERT OR REPLACE INTO catalogue_titles(id,name,sort_key,year,kind,metadata,meta_fetched,attempt_at,version_count) VALUES(?,?,?,?,?,?,?,?,?)"
      )
      let insertVersion = try prepare(
        "INSERT OR REPLACE INTO catalogue_versions VALUES(?,?,?,?,?)")
      defer {
        sqlite3_finalize(insertTitle)
        sqlite3_finalize(insertVersion)
      }
      var versionTotal = 0
      for title in titles {
        try Task.checkCancellation()
        let entry = metadata[title.id]
        sqlite3_reset(insertTitle)
        sqlite3_clear_bindings(insertTitle)
        bind(title.id, to: insertTitle, at: 1)
        bind(title.name, to: insertTitle, at: 2)
        bind(EntertainmentGrouping.sortKey(title.name), to: insertTitle, at: 3)
        bind(title.year, to: insertTitle, at: 4)
        bind(title.kind.rawValue, to: insertTitle, at: 5)
        bind(entry?.payload, to: insertTitle, at: 6)
        sqlite3_bind_double(insertTitle, 7, entry?.fetched ?? 0)
        sqlite3_bind_double(insertTitle, 8, entry?.attempt ?? 0)
        sqlite3_bind_int64(insertTitle, 9, Int64(title.versions.count))
        try stepDone(insertTitle)
        for version in title.versions {
          sqlite3_reset(insertVersion)
          sqlite3_clear_bindings(insertVersion)
          bind(version.media.categoryID.uuidString, to: insertVersion, at: 1)
          bind(version.media.entry.url.absoluteString, to: insertVersion, at: 2)
          bind(title.id, to: insertVersion, at: 3)
          if let season = version.season { sqlite3_bind_int64(insertVersion, 4, Int64(season)) }
          if let episode = version.episode { sqlite3_bind_int64(insertVersion, 5, Int64(episode)) }
          try stepDone(insertVersion)
          versionTotal += 1
        }
      }
      let state = try prepare(
        "INSERT OR REPLACE INTO catalogue_state(id,format,corrections,built,versions,titles,skipped,legacy_retired,aliases_synced) VALUES(1,?,?,?,?,?,?,COALESCE((SELECT legacy_retired FROM catalogue_state WHERE id=1),0),0)"
      )
      defer { sqlite3_finalize(state) }
      sqlite3_bind_int64(state, 1, Int64(Self.catalogueFormat))
      corrections.withUnsafeBytes {
        _ = sqlite3_bind_blob(state, 2, $0.baseAddress, Int32(corrections.count), Self.transient)
      }
      sqlite3_bind_double(state, 3, Date.now.timeIntervalSince1970)
      sqlite3_bind_int64(state, 4, Int64(versionTotal))
      sqlite3_bind_int64(state, 5, Int64(titles.count))
      sqlite3_bind_int64(state, 6, Int64(skipped))
      try stepDone(state)
    }
  }

  // MARK: - Reading

  private struct RawTitle: Sendable {
    var id: String
    var name: String
    var year: String?
    var kind: String
    var payload: String?
    var fetched: Double
    var attempt: Double
  }

  private struct RawVersion: Sendable {
    var title: Int
    var source: Int
    var url: String
    var name: String
    var relativePath: String
    var artwork: String?
    var size: Int64?
    var modified: Double?
    var discovered: Double
    var progress: Double
    var duration: Double
    var lastPlayed: Double?
    var season: Int?
    var episode: Int?
  }

  /// Reads the whole catalogue in display order with one join. This is the fast path of every
  /// launch after the first. Rows are read in one sequential pass; addresses and metadata are then
  /// parsed across the processor cores.
  func loadCatalogue(now: Date = .now) throws -> CatalogueLoad {
    // A source's name and root are stored on every file row; read them once per source.
    var sourceIndex: [String: Int] = [:]
    var sources: [(id: UUID, name: String, root: URL)] = []
    let sourceStatement = try prepare(
      "SELECT category,category_name,root FROM videos GROUP BY category")
    while sqlite3_step(sourceStatement) == SQLITE_ROW {
      if let id = UUID(uuidString: string(sourceStatement, 0)),
        let root = URL(string: string(sourceStatement, 2))
      {
        sourceIndex[string(sourceStatement, 0)] = sources.count
        sources.append((id, string(sourceStatement, 1), root))
      }
    }
    sqlite3_finalize(sourceStatement)

    let statement = try prepare(
      """
      SELECT t.id,t.name,t.year,t.kind,t.metadata,t.meta_fetched,t.attempt_at,
        v.category,v.url,v.name,v.relative_path,v.artwork,v.size,v.modified,
        v.first_discovered,cv.season,cv.episode,COALESCE(p.seconds,0),COALESCE(p.duration,0),p.updated
      FROM catalogue_titles t
      JOIN catalogue_versions cv ON cv.title_id=t.id
      JOIN videos v ON v.category=cv.category AND v.url=cv.url
      LEFT JOIN playback p ON p.url=v.url
      ORDER BY t.sort_key,t.id,COALESCE(cv.season,0),COALESCE(cv.episode,0),v.name,v.url
      """)
    defer { sqlite3_finalize(statement) }
    var titles: [RawTitle] = []
    var versions: [RawVersion] = []
    var lastTitle = ""
    var lastCategory = ""
    var lastSource = -1
    var status = sqlite3_step(statement)
    while status == SQLITE_ROW {
      try Task.checkCancellation()
      let id = string(statement, 0)
      if titles.isEmpty || id != lastTitle {
        titles.append(
          RawTitle(
            id: id, name: string(statement, 1),
            year: sqlite3_column_type(statement, 2) == SQLITE_NULL ? nil : string(statement, 2),
            kind: string(statement, 3),
            payload: sqlite3_column_type(statement, 4) == SQLITE_NULL ? nil : string(statement, 4),
            fetched: sqlite3_column_double(statement, 5),
            attempt: sqlite3_column_double(statement, 6)))
        lastTitle = id
      }
      let category = string(statement, 7)
      if category != lastCategory {
        lastCategory = category
        lastSource = sourceIndex[category] ?? -1
      }
      if lastSource >= 0 {
        versions.append(
          RawVersion(
            title: titles.count - 1, source: lastSource, url: string(statement, 8),
            name: string(statement, 9), relativePath: string(statement, 10),
            artwork: sqlite3_column_type(statement, 11) == SQLITE_NULL
              ? nil : string(statement, 11),
            size: sqlite3_column_type(statement, 12) == SQLITE_NULL
              ? nil : sqlite3_column_int64(statement, 12),
            modified: sqlite3_column_type(statement, 13) == SQLITE_NULL
              ? nil : sqlite3_column_double(statement, 13),
            discovered: sqlite3_column_double(statement, 14),
            progress: sqlite3_column_double(statement, 17),
            duration: sqlite3_column_double(statement, 18),
            lastPlayed: sqlite3_column_type(statement, 19) == SQLITE_NULL
              ? nil : sqlite3_column_double(statement, 19),
            season: sqlite3_column_type(statement, 15) == SQLITE_NULL
              ? nil : Int(sqlite3_column_int64(statement, 15)),
            episode: sqlite3_column_type(statement, 16) == SQLITE_NULL
              ? nil : Int(sqlite3_column_int64(statement, 16))))
      }
      status = sqlite3_step(statement)
    }
    guard status == SQLITE_DONE else { throw databaseError() }
    try Task.checkCancellation()

    let sourceTable = sources
    let rawVersions = versions
    let built: [EntertainmentVersion?] = ParallelChunks.map(count: rawVersions.count) { range in
      var artwork: [String: URL?] = [:]
      return range.map { offset -> EntertainmentVersion? in
        let raw = rawVersions[offset]
        guard let url = URL(string: raw.url) else { return nil }
        var artworkURL: URL?
        if let text = raw.artwork {
          if let cached = artwork[text] {
            artworkURL = cached
          } else {
            artworkURL = URL(string: text)
            artwork[text] = artworkURL
          }
        }
        let source = sourceTable[raw.source]
        return EntertainmentVersion(
          media: GlobalSearchResult(
            categoryID: source.id, categoryName: source.name, categoryRoot: source.root,
            entry: DirectoryEntry(
              name: raw.name, url: url, kind: .file, size: raw.size,
              modifiedAt: raw.modified.map { Date(timeIntervalSince1970: $0) }),
            relativePath: raw.relativePath, artworkURL: artworkURL),
          firstDiscovered: Date(timeIntervalSince1970: raw.discovered),
          progressSeconds: raw.progress, duration: raw.duration,
          lastPlayed: raw.lastPlayed.map { Date(timeIntervalSince1970: $0) },
          season: raw.season, episode: raw.episode)
      }
    }
    let rawTitles = titles
    let metadata: [EntertainmentMetadata?] = ParallelChunks.map(count: rawTitles.count) { range in
      let decoder = JSONDecoder()
      return range.map { offset -> EntertainmentMetadata? in
        rawTitles[offset].payload.flatMap {
          try? decoder.decode(EntertainmentMetadata.self, from: Data($0.utf8))
        }
      }
    }
    try Task.checkCancellation()

    var result: [EntertainmentTitle] = []
    result.reserveCapacity(rawTitles.count)
    var enrichment: Set<String> = []
    let cutoff = now.timeIntervalSince1970 - Self.metadataFreshness
    var cursor = 0
    for (offset, raw) in rawTitles.enumerated() {
      var group: [EntertainmentVersion] = []
      while cursor < rawVersions.count, rawVersions[cursor].title == offset {
        if let version = built[cursor] { group.append(version) }
        cursor += 1
      }
      if raw.fetched < cutoff, raw.attempt < cutoff { enrichment.insert(raw.id) }
      guard !group.isEmpty else { continue }
      result.append(
        EntertainmentTitle(
          id: raw.id, name: raw.name, year: raw.year,
          kind: EntertainmentKind(rawValue: raw.kind) ?? .movie, versions: group,
          metadata: metadata[offset]))
    }
    return CatalogueLoad(titles: result, enrichmentIDs: enrichment)
  }

  // MARK: - Incremental update

  /// Applies match-correction changes and every file added, renamed or removed since the last
  /// call, touching only the titles those files belong to. One transaction: a crash leaves either
  /// the old or the new catalogue.
  func updateCatalogue(
    corrections: [String: EntertainmentMatchCorrection], correctionsData: Data
  ) throws -> CatalogueUpdateSummary {
    var summary = CatalogueUpdateSummary()
    guard let state = try catalogueState() else { return summary }
    // Files whose correction changed are re-placed like changed files.
    let previous =
      (try? JSONDecoder().decode(
        [String: EntertainmentMatchCorrection].self, from: state.corrections)) ?? [:]
    var changedIDs: Set<String> = []
    for (key, value) in corrections where previous[key] != value { changedIDs.insert(key) }
    for key in previous.keys where corrections[key] == nil { changedIDs.insert(key) }
    var affected: Set<String> = []
    try transaction {
      for id in changedIDs {
        try execute(
          "INSERT OR IGNORE INTO catalogue_dirty SELECT category,url FROM videos WHERE url=?", [id])
        // A corrected file that is no longer indexed still has a stale version row.
        try execute(
          "INSERT OR IGNORE INTO catalogue_dirty SELECT category,url FROM catalogue_versions WHERE url=?",
          [id])
      }
      let removeVersion = try prepare("DELETE FROM catalogue_versions WHERE category=? AND url=?")
      let upsertVersion = try prepare("INSERT OR REPLACE INTO catalogue_versions VALUES(?,?,?,?,?)")
      let insertTitle = try prepare(
        "INSERT OR IGNORE INTO catalogue_titles(id,name,sort_key,year,kind,version_count) VALUES(?,?,?,?,?,0)"
      )
      defer {
        sqlite3_finalize(removeVersion)
        sqlite3_finalize(upsertVersion)
        sqlite3_finalize(insertTitle)
      }
      while true {
        let batch = try prepare("SELECT category,url FROM catalogue_dirty LIMIT 2000")
        var entries: [(String, String)] = []
        while sqlite3_step(batch) == SQLITE_ROW { entries.append((string(batch, 0), string(batch, 1))) }
        sqlite3_finalize(batch)
        if entries.isEmpty { break }
        let video = try prepare("SELECT name FROM videos WHERE category=? AND url=?")
        let existing = try prepare(
          "SELECT title_id FROM catalogue_versions WHERE category=? AND url=?")
        let clear = try prepare("DELETE FROM catalogue_dirty WHERE category=? AND url=?")
        defer {
          sqlite3_finalize(video)
          sqlite3_finalize(existing)
          sqlite3_finalize(clear)
        }
        for (category, url) in entries {
          try Task.checkCancellation()
          summary.processedFiles += 1
          sqlite3_reset(existing)
          sqlite3_clear_bindings(existing)
          bind(category, to: existing, at: 1)
          bind(url, to: existing, at: 2)
          let oldTitle = sqlite3_step(existing) == SQLITE_ROW ? string(existing, 0) : nil
          sqlite3_reset(video)
          sqlite3_clear_bindings(video)
          bind(category, to: video, at: 1)
          bind(url, to: video, at: 2)
          if sqlite3_step(video) == SQLITE_ROW, let address = URL(string: url) {
            let placement = EntertainmentGrouping.placement(
              fileName: string(video, 0), url: address, correction: corrections[url])
            if placement.key != oldTitle {
              sqlite3_reset(insertTitle)
              sqlite3_clear_bindings(insertTitle)
              bind(placement.key, to: insertTitle, at: 1)
              bind(placement.name, to: insertTitle, at: 2)
              bind(EntertainmentGrouping.sortKey(placement.name), to: insertTitle, at: 3)
              bind(placement.year, to: insertTitle, at: 4)
              bind(placement.kind.rawValue, to: insertTitle, at: 5)
              try stepDone(insertTitle)
            }
            sqlite3_reset(upsertVersion)
            sqlite3_clear_bindings(upsertVersion)
            bind(category, to: upsertVersion, at: 1)
            bind(url, to: upsertVersion, at: 2)
            bind(placement.key, to: upsertVersion, at: 3)
            if let season = placement.season { sqlite3_bind_int64(upsertVersion, 4, Int64(season)) }
            if let episode = placement.episode {
              sqlite3_bind_int64(upsertVersion, 5, Int64(episode))
            }
            try stepDone(upsertVersion)
            affected.insert(placement.key)
          } else {
            sqlite3_reset(removeVersion)
            sqlite3_clear_bindings(removeVersion)
            bind(category, to: removeVersion, at: 1)
            bind(url, to: removeVersion, at: 2)
            try stepDone(removeVersion)
          }
          if let oldTitle { affected.insert(oldTitle) }
          sqlite3_reset(clear)
          sqlite3_clear_bindings(clear)
          bind(category, to: clear, at: 1)
          bind(url, to: clear, at: 2)
          try stepDone(clear)
        }
      }
      // Recount affected titles, drop empty ones, and re-resolve the survivors' metadata.
      var survivors: [EntertainmentTitle] = []
      for id in affected {
        let versions = try shellVersions(titleID: id)
        if versions.isEmpty {
          try execute("DELETE FROM catalogue_titles WHERE id=?", [id])
        } else {
          var shell = EntertainmentTitle(
            id: id, name: "", year: nil, kind: .movie, versions: versions)
          EntertainmentGrouping.orderVersions(&shell.versions)
          survivors.append(shell)
        }
      }
      summary.titlesTouched = affected.count
      if !survivors.isEmpty {
        let resolved = try resolveCatalogueMetadata(for: survivors, corrections: corrections)
        summary.metadataQueries = resolved.queries
        let update = try prepare(
          "UPDATE catalogue_titles SET version_count=?,metadata=?,meta_fetched=?,attempt_at=? WHERE id=?"
        )
        defer { sqlite3_finalize(update) }
        for title in survivors {
          sqlite3_reset(update)
          sqlite3_clear_bindings(update)
          sqlite3_bind_int64(update, 1, Int64(title.versions.count))
          bind(resolved.entries[title.id]?.payload, to: update, at: 2)
          sqlite3_bind_double(update, 3, resolved.entries[title.id]?.fetched ?? 0)
          sqlite3_bind_double(update, 4, resolved.entries[title.id]?.attempt ?? 0)
          bind(title.id, to: update, at: 5)
          try stepDone(update)
        }
      }
      let versions = try count("SELECT COUNT(*) FROM catalogue_versions")
      let titles = try count("SELECT COUNT(*) FROM catalogue_titles")
      let statement = try prepare(
        "UPDATE catalogue_state SET corrections=?,versions=?,titles=?,aliases_synced=0 WHERE id=1")
      defer { sqlite3_finalize(statement) }
      correctionsData.withUnsafeBytes {
        _ = sqlite3_bind_blob(
          statement, 1, $0.baseAddress, Int32(correctionsData.count), Self.transient)
      }
      sqlite3_bind_int64(statement, 2, Int64(versions))
      sqlite3_bind_int64(statement, 3, Int64(titles))
      try stepDone(statement)
    }
    return summary
  }

  /// The files of one title with just enough detail to compute its cache key.
  private func shellVersions(titleID: String) throws -> [EntertainmentVersion] {
    let statement = try prepare(
      """
      SELECT v.category,v.url,v.name,cv.season,cv.episode FROM catalogue_versions cv
      JOIN videos v ON v.category=cv.category AND v.url=cv.url WHERE cv.title_id=?
      """)
    defer { sqlite3_finalize(statement) }
    bind(titleID, to: statement, at: 1)
    var versions: [EntertainmentVersion] = []
    let placeholder = URL(string: "https://catalogue.invalid/")!
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let category = UUID(uuidString: string(statement, 0)),
        let url = URL(string: string(statement, 1))
      else { continue }
      versions.append(
        EntertainmentVersion(
          media: GlobalSearchResult(
            categoryID: category, categoryName: "", categoryRoot: placeholder,
            entry: DirectoryEntry(name: string(statement, 2), url: url, kind: .file),
            relativePath: "", artworkURL: nil),
          firstDiscovered: .distantPast,
          season: sqlite3_column_type(statement, 3) == SQLITE_NULL
            ? nil : Int(sqlite3_column_int64(statement, 3)),
          episode: sqlite3_column_type(statement, 4) == SQLITE_NULL
            ? nil : Int(sqlite3_column_int64(statement, 4))))
    }
    return versions
  }

  // MARK: - Verification

  func verifyCatalogue() throws -> CatalogueVerification {
    CatalogueVerification(
      videos: try count("SELECT COUNT(*) FROM videos"),
      versions: try count("SELECT COUNT(*) FROM catalogue_versions"),
      skipped: try catalogueState()?.skipped ?? 0,
      titles: try count("SELECT COUNT(*) FROM catalogue_titles"),
      versionsOfTitles: try count("SELECT COALESCE(SUM(version_count),0) FROM catalogue_titles"),
      orphanVersions: try count(
        "SELECT COUNT(*) FROM catalogue_versions cv WHERE NOT EXISTS(SELECT 1 FROM catalogue_titles t WHERE t.id=cv.title_id) OR NOT EXISTS(SELECT 1 FROM videos v WHERE v.category=cv.category AND v.url=cv.url)"
      ))
  }

  // MARK: - Metadata writes from enrichment

  /// Stores freshly fetched metadata for a title so the next launch starts with it.
  func updateCatalogueMetadata(titleID: String, metadata: EntertainmentMetadata) throws {
    let payload = String(decoding: try JSONEncoder().encode(metadata), as: UTF8.self)
    let statement = try prepare(
      "UPDATE catalogue_titles SET metadata=?,meta_fetched=? WHERE id=?")
    defer { sqlite3_finalize(statement) }
    bind(payload, to: statement, at: 1)
    sqlite3_bind_double(statement, 2, Date.now.timeIntervalSince1970)
    bind(titleID, to: statement, at: 3)
    try stepDone(statement)
    try execute("UPDATE catalogue_state SET aliases_synced=0 WHERE id=1")
  }

  /// Remembers that a lookup ended without a confident match, so it is not repeated for a week.
  func markCatalogueAttempt(titleID: String) throws {
    let statement = try prepare("UPDATE catalogue_titles SET attempt_at=? WHERE id=?")
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_double(statement, 1, Date.now.timeIntervalSince1970)
    bind(titleID, to: statement, at: 2)
    try stepDone(statement)
  }

  /// Mirrors a metadata-cache write into the catalogue row it belongs to. Keys are
  /// `tmdb|<title id>|<provider>|<episodes>` (a lookup) and `tmdb-attempt|<that key>` (no match).
  /// The title id itself contains `|`, so the key is split from the right.
  func applyMetadataToCatalogue(key: String, payload: String) throws {
    var isAttempt = false
    var body = Substring(key)
    if body.hasPrefix("tmdb-attempt|") {
      isAttempt = true
      body = body.dropFirst("tmdb-attempt|".count)
    }
    guard body.hasPrefix("tmdb|") else { return }
    body = body.dropFirst("tmdb|".count)
    let parts = body.split(separator: "|", omittingEmptySubsequences: false)
    guard parts.count >= 3 else { return }
    let titleID = parts.dropLast(2).joined(separator: "|")
    if isAttempt {
      try markCatalogueAttempt(titleID: titleID)
      return
    }
    guard (try? JSONDecoder().decode(EntertainmentMetadata.self, from: Data(payload.utf8))) != nil
    else { return }
    let statement = try prepare(
      "UPDATE catalogue_titles SET metadata=?,meta_fetched=? WHERE id=?")
    defer { sqlite3_finalize(statement) }
    bind(payload, to: statement, at: 1)
    sqlite3_bind_double(statement, 2, Date.now.timeIntervalSince1970)
    bind(titleID, to: statement, at: 3)
    try stepDone(statement)
    if changedRows() > 0 {
      try execute("UPDATE catalogue_state SET aliases_synced=0 WHERE id=1")
    }
  }

  // MARK: - Search aliases

  /// Brings the search index's title aliases in line with the catalogue in one set-based pass,
  /// and only when the catalogue changed since the last pass. Returns the number of changed rows.
  @discardableResult
  func syncSearchAliasesIfNeeded() throws -> Int {
    guard let state = try catalogueState(), !state.aliasesSynced else { return 0 }
    try buildPendingSearchDocuments()
    var changed = 0
    try transaction {
      try execute("DROP TABLE IF EXISTS temp.alias_map")
      try execute(
        "CREATE TEMP TABLE alias_map(c TEXT NOT NULL,u TEXT NOT NULL,a TEXT NOT NULL,PRIMARY KEY(c,u)) WITHOUT ROWID"
      )
      try execute(
        """
        INSERT INTO temp.alias_map SELECT cv.category,cv.url,
          CASE WHEN COALESCE(json_extract(t.metadata,'$.title'),'')='' THEN t.name
            ELSE t.name||char(10)||json_extract(t.metadata,'$.title') END
        FROM catalogue_versions cv JOIN catalogue_titles t ON t.id=cv.title_id
        """)
      changed = try count(
        "SELECT COUNT(*) FROM search_documents d JOIN temp.alias_map m ON m.c=d.category AND m.u=d.url WHERE d.aliases!=m.a"
      )
      try execute(
        "INSERT OR IGNORE INTO search_dirty SELECT d.category,d.url FROM search_documents d JOIN temp.alias_map m ON m.c=d.category AND m.u=d.url WHERE d.aliases!=m.a"
      )
      try execute(
        "UPDATE search_documents SET aliases=(SELECT a FROM temp.alias_map m WHERE m.c=search_documents.category AND m.u=search_documents.url) WHERE EXISTS(SELECT 1 FROM temp.alias_map m WHERE m.c=search_documents.category AND m.u=search_documents.url AND m.a!=search_documents.aliases)"
      )
      try execute("DROP TABLE temp.alias_map")
      try execute("UPDATE catalogue_state SET aliases_synced=1 WHERE id=1")
    }
    if changed > 0 { try buildPendingSearchDocuments() }
    return changed
  }
}

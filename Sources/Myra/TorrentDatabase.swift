import CSQLite
import Foundation

private final class TorrentConnection: @unchecked Sendable {
  let handle: OpaquePointer
  init(url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    var pointer: OpaquePointer?
    let result = sqlite3_open_v2(
      url.path, &pointer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
    guard result == SQLITE_OK, let pointer else {
      if let pointer { sqlite3_close(pointer) }
      throw TorrentError.database("Could not open the local store.")
    }
    handle = pointer
    sqlite3_busy_timeout(handle, 3000)
  }
  deinit { sqlite3_close(handle) }
}

/// Separate database: adding torrent persistence cannot migrate or corrupt the HTTP library index.
actor TorrentDatabase {
  private let connection: TorrentConnection
  private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
  init(url: URL) throws {
    let connection = try TorrentConnection(url: url)
    self.connection = connection
    let schema = """
      PRAGMA journal_mode=WAL;
      PRAGMA foreign_keys=ON;
      CREATE TABLE IF NOT EXISTS torrent_jobs(identity TEXT PRIMARY KEY, payload BLOB NOT NULL, added REAL NOT NULL);
      CREATE TABLE IF NOT EXISTS torrent_playback(identity TEXT NOT NULL REFERENCES torrent_jobs(identity) ON DELETE CASCADE,
        file_index INTEGER NOT NULL, seconds REAL NOT NULL, duration REAL NOT NULL, updated REAL NOT NULL,
        PRIMARY KEY(identity,file_index));
      CREATE TABLE IF NOT EXISTS torrent_settings(id INTEGER PRIMARY KEY CHECK(id=1), payload BLOB NOT NULL);
      """
    guard sqlite3_exec(connection.handle, schema, nil, nil, nil) == SQLITE_OK else {
      throw TorrentError.database(String(cString: sqlite3_errmsg(connection.handle)))
    }
  }
  func save(_ job: TorrentJob) throws {
    guard job.files.allSatisfy(\.hasSafePath), Set(job.files.map(\.index)).count == job.files.count,
      job.selectedFileIndex == nil
        || job.files.contains(where: { $0.index == job.selectedFileIndex && $0.isPlayable })
    else {
      throw TorrentError.unsafePath
    }
    let statement = try prepare(
      "INSERT INTO torrent_jobs VALUES(?,?,?) ON CONFLICT(identity) DO UPDATE SET payload=excluded.payload"
    )
    defer { sqlite3_finalize(statement) }
    bind(job.identity.rawValue, at: 1, to: statement)
    try bind(JSONEncoder().encode(job), at: 2, to: statement)
    sqlite3_bind_double(statement, 3, job.addedAt.timeIntervalSince1970)
    try done(statement)
  }
  func jobs() throws -> [TorrentJob] {
    let statement = try prepare("SELECT payload FROM torrent_jobs ORDER BY added DESC,identity")
    defer { sqlite3_finalize(statement) }
    var jobs: [TorrentJob] = []
    var result = sqlite3_step(statement)
    while result == SQLITE_ROW {
      jobs.append(try JSONDecoder().decode(TorrentJob.self, from: blob(statement, column: 0)))
      result = sqlite3_step(statement)
    }
    guard result == SQLITE_DONE else { throw failure() }
    return jobs
  }
  func remove(_ identity: TorrentIdentity) throws {
    let statement = try prepare("DELETE FROM torrent_jobs WHERE identity=?")
    defer { sqlite3_finalize(statement) }
    bind(identity.rawValue, at: 1, to: statement)
    try done(statement)
  }
  func saveProgress(identity: TorrentIdentity, fileIndex: Int, seconds: Double, duration: Double)
    throws
  {
    guard fileIndex >= 0, seconds.isFinite, duration.isFinite, seconds >= 0, duration >= 0 else {
      return
    }
    let statement = try prepare(
      "INSERT INTO torrent_playback VALUES(?,?,?,?,?) ON CONFLICT(identity,file_index) DO UPDATE SET seconds=excluded.seconds,duration=excluded.duration,updated=excluded.updated"
    )
    defer { sqlite3_finalize(statement) }
    bind(identity.rawValue, at: 1, to: statement)
    sqlite3_bind_int64(statement, 2, Int64(fileIndex))
    sqlite3_bind_double(statement, 3, duration > 0 ? min(seconds, duration) : seconds)
    sqlite3_bind_double(statement, 4, duration)
    sqlite3_bind_double(statement, 5, Date.now.timeIntervalSince1970)
    try done(statement)
  }
  func progress(identity: TorrentIdentity, fileIndex: Int) throws -> TorrentPlaybackProgress? {
    let statement = try prepare(
      "SELECT seconds,duration,updated FROM torrent_playback WHERE identity=? AND file_index=?")
    defer { sqlite3_finalize(statement) }
    bind(identity.rawValue, at: 1, to: statement)
    sqlite3_bind_int64(statement, 2, Int64(fileIndex))
    let result = sqlite3_step(statement)
    if result == SQLITE_DONE { return nil }
    guard result == SQLITE_ROW else { throw failure() }
    return TorrentPlaybackProgress(
      seconds: sqlite3_column_double(statement, 0), duration: sqlite3_column_double(statement, 1),
      updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)))
  }
  func preferences() throws -> TorrentPreferences {
    let statement = try prepare("SELECT payload FROM torrent_settings WHERE id=1")
    defer { sqlite3_finalize(statement) }
    let result = sqlite3_step(statement)
    if result == SQLITE_DONE { return TorrentPreferences() }
    guard result == SQLITE_ROW else { throw failure() }
    return try JSONDecoder().decode(TorrentPreferences.self, from: blob(statement, column: 0))
      .validated()
  }
  func savePreferences(_ preferences: TorrentPreferences) throws {
    let statement = try prepare(
      "INSERT INTO torrent_settings VALUES(1,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload"
    )
    defer { sqlite3_finalize(statement) }
    try bind(JSONEncoder().encode(preferences.validated()), at: 1, to: statement)
    try done(statement)
  }
  private func failure() -> TorrentError {
    .database(String(cString: sqlite3_errmsg(connection.handle)))
  }
  private func prepare(_ sql: String) throws -> OpaquePointer {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(connection.handle, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else { throw failure() }
    return statement
  }
  private func bind(_ text: String, at index: Int32, to statement: OpaquePointer) {
    sqlite3_bind_text(statement, index, text, -1, Self.transient)
  }
  private func bind(_ data: Data, at index: Int32, to statement: OpaquePointer) throws {
    let result = data.withUnsafeBytes { bytes in
      sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), Self.transient)
    }
    guard result == SQLITE_OK else { throw failure() }
  }
  private func blob(_ statement: OpaquePointer, column: Int32) throws -> Data {
    guard let bytes = sqlite3_column_blob(statement, column) else { throw failure() }
    return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
  }
  private func done(_ statement: OpaquePointer) throws {
    guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
  }
}

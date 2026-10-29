import CSQLite
import Foundation

/// What Myra remembers about one source between launches: when it last answered, when it last
/// failed, how quickly it responds, and when the next automatic retry is due.
struct SourceHealthRecord: Equatable, Sendable {
  var lastSuccess: Date?
  var lastProblem: Date?
  var lastError: String?
  /// Mean listing round trip during the last run, in seconds.
  var latency: TimeInterval?
  var consecutiveFailures: Int = 0
  var nextRetry: Date?
}

extension LibraryIndex {
  /// Number of indexed videos across all sources.
  func videoCount() throws -> Int { try count("SELECT COUNT(*) FROM videos") }

  /// Indexed videos per source.
  func videoCounts() throws -> [UUID: Int] {
    let statement = try prepare("SELECT category,COUNT(*) FROM videos GROUP BY category")
    defer { sqlite3_finalize(statement) }
    var result: [UUID: Int] = [:]
    while sqlite3_step(statement) == SQLITE_ROW {
      if let id = UUID(uuidString: string(statement, 0)) {
        result[id] = Int(sqlite3_column_int64(statement, 1))
      }
    }
    return result
  }

  /// When each source last completed a full scan.
  func sourceScanDates() throws -> [UUID: Date] {
    let statement = try prepare("SELECT category,completed FROM source_scans")
    defer { sqlite3_finalize(statement) }
    var result: [UUID: Date] = [:]
    while sqlite3_step(statement) == SQLITE_ROW {
      if let id = UUID(uuidString: string(statement, 0)) {
        result[id] = Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
      }
    }
    return result
  }

  func sourceHealth() throws -> [UUID: SourceHealthRecord] {
    let statement = try prepare(
      "SELECT category,last_success,last_problem,last_error,latency,failures,next_retry FROM source_health"
    )
    defer { sqlite3_finalize(statement) }
    var result: [UUID: SourceHealthRecord] = [:]
    func date(_ column: Int32) -> Date? {
      sqlite3_column_type(statement, column) == SQLITE_NULL
        ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, column))
    }
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let id = UUID(uuidString: string(statement, 0)) else { continue }
      result[id] = SourceHealthRecord(
        lastSuccess: date(1), lastProblem: date(2),
        lastError: sqlite3_column_type(statement, 3) == SQLITE_NULL ? nil : string(statement, 3),
        latency: sqlite3_column_type(statement, 4) == SQLITE_NULL
          ? nil : sqlite3_column_double(statement, 4),
        consecutiveFailures: Int(sqlite3_column_int64(statement, 5)), nextRetry: date(6))
    }
    return result
  }

  func saveSourceHealth(_ record: SourceHealthRecord, source: UUID) throws {
    let statement = try prepare(
      "INSERT OR REPLACE INTO source_health(category,last_success,last_problem,last_error,latency,failures,next_retry) VALUES(?,?,?,?,?,?,?)"
    )
    defer { sqlite3_finalize(statement) }
    bind(source.uuidString, to: statement, at: 1)
    func bindDate(_ value: Date?, _ column: Int32) {
      if let value {
        sqlite3_bind_double(statement, column, value.timeIntervalSince1970)
      } else {
        sqlite3_bind_null(statement, column)
      }
    }
    bindDate(record.lastSuccess, 2)
    bindDate(record.lastProblem, 3)
    bind(record.lastError, to: statement, at: 4)
    if let latency = record.latency {
      sqlite3_bind_double(statement, 5, latency)
    } else {
      sqlite3_bind_null(statement, 5)
    }
    sqlite3_bind_int64(statement, 6, Int64(record.consecutiveFailures))
    bindDate(record.nextRetry, 7)
    try stepDone(statement)
  }
}

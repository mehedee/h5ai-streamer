import Foundation

/// Observable refresh lifecycle. Completion is distinct from cancellation and partial failure.
enum IndexRefreshState: Equatable, Sendable {
  case notScanned, noSources, refreshing, paused, completed, partial, failed, cancelled

  var title: String {
    switch self {
    case .notScanned: "Library not yet scanned"
    case .noSources: "No library sources"
    case .refreshing: "Indexing library"
    case .paused: "Indexing paused"
    case .completed: "Library refreshed"
    case .partial: "Refresh completed with issues"
    case .failed: "Refresh failed"
    case .cancelled: "Indexing cancelled"
    }
  }

  var symbol: String {
    switch self {
    case .refreshing: "arrow.triangle.2.circlepath"
    case .paused: "pause.circle"
    case .completed: "checkmark.circle"
    case .partial, .failed: "exclamationmark.triangle"
    case .cancelled: "stop.circle"
    case .notScanned, .noSources: "externaldrive"
    }
  }
}

/// Where one source stands. `queued` and `indexing` only occur during a run.
enum SourceIndexState: String, Equatable, Sendable {
  case notScanned, queued, indexing, ok, failed
}

/// Everything the Sources page and the header indicator show about one source.
struct SourceIndexStatus: Identifiable, Equatable, Sendable {
  let id: UUID
  var name: String
  var state: SourceIndexState = .notScanned
  /// Videos found in this source during the current run, or the saved total when idle.
  var videosFound = 0
  /// Folders visited in the current run.
  var foldersVisited = 0
  var lastScan: Date?
  var lastSuccess: Date?
  var lastProblem: Date?
  var lastError: String?
  /// Mean listing round trip in the last run, in seconds.
  var latency: TimeInterval?
  var consecutiveFailures = 0
  /// When the automatic retry for a failing source is due.
  var nextRetry: Date?
}

/// Run-level numbers for a progress bar and a fixed-width header indicator.
struct IndexingProgress: Equatable, Sendable {
  /// 1-based position of the source being indexed; 0 when idle.
  var currentSource = 0
  var sourceCount = 0
  var videosFound = 0
  var foldersVisited = 0
  /// 0...1 across all sources of the current run; 0 when idle.
  var fraction = 0.0
  var percent: Int { Int((fraction * 100).rounded()) }
}

/// One source's progress inside a run, delivered by `LibraryIndexer`.
struct SourceRunUpdate: Sendable {
  let sourceID: UUID
  var state: SourceIndexState
  var videosFound = 0
  var foldersVisited = 0
  var error: String?
  var latency: TimeInterval?
  /// Set when the source finished (successfully or not): the health to persist and display.
  var health: SourceHealthRecord?
}

/// Backoff for sources that fail: 1 minute, doubling, capped at 30 minutes.
struct IndexRetryPolicy: Sendable {
  var base: TimeInterval = 60
  var factor = 2.0
  var maximum: TimeInterval = 1800

  func delay(afterFailures failures: Int) -> TimeInterval {
    guard failures > 0 else { return 0 }
    return min(maximum, base * pow(factor, Double(failures - 1)))
  }

  static let none = IndexRetryPolicy(base: 0, factor: 1, maximum: 0)
}

enum IndexSourceError: LocalizedError {
  case unavailable
  var errorDescription: String? {
    switch self {
    case .unavailable:
      "The source is not responding. Remaining folders were skipped; Myra will retry automatically."
    }
  }
}

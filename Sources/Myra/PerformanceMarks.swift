import Darwin
import Foundation
import OSLog

/// Names of the measured stages. Each is an os_signpost interval (visible in Instruments under the
/// "Myra" subsystem, category "Performance") and is also kept in `MyraPerformance.recorder`.
enum PerfMark {
  /// Process start until the first automatic Home shelf exists.
  static let launchToFirstShelf = "launch.firstHomeShelf"
  /// Whole `EntertainmentCatalogueWorker.prepare`, whichever route supplied the catalogue.
  static let cataloguePrepare = "catalogue.prepare"
  /// Reading the saved catalogue (the compact database catalogue; formerly the JSON home cache).
  static let homeCacheLoad = "catalogue.homeCacheLoad"
  /// Building the catalogue from the indexed videos (full or incremental).
  static let catalogueBuild = "catalogue.build"
  /// Shelves and filter projection that the Home page needs before it can draw.
  static let homeRender = "home.renderPreparation"
  /// One complete library index run.
  static let indexRun = "index.run"
}

/// Thread-safe store of the most recent timing of each mark. No UI and no I/O.
final class PerformanceRecorder: @unchecked Sendable {
  struct Sample: Sendable, Equatable {
    let name: String
    let seconds: Double
    let detail: String
    let recorded: Date
  }
  private let lock = NSLock()
  private var samples: [Sample] = []

  func record(_ name: String, seconds: Double, detail: String = "") {
    lock.lock()
    defer { lock.unlock() }
    samples.append(Sample(name: name, seconds: seconds, detail: detail, recorded: .now))
    if samples.count > 500 { samples.removeFirst(samples.count - 500) }
  }
  func latest(_ name: String) -> Sample? {
    lock.lock()
    defer { lock.unlock() }
    return samples.last { $0.name == name }
  }
  func all(_ name: String) -> [Sample] {
    lock.lock()
    defer { lock.unlock() }
    return samples.filter { $0.name == name }
  }
  var snapshot: [Sample] {
    lock.lock()
    defer { lock.unlock() }
    return samples
  }
  func reset() {
    lock.lock()
    defer { lock.unlock() }
    samples.removeAll()
  }
}

enum MyraPerformance {
  static let signposter = OSSignposter(subsystem: "Myra", category: "Performance")
  static let logger = Logger(subsystem: "Myra", category: "Performance")
  static let recorder = PerformanceRecorder()

  /// An open interval. `end` closes the signpost, logs the duration and records the sample.
  struct Interval: @unchecked Sendable {
    fileprivate let name: String
    fileprivate let state: OSSignpostIntervalState
    fileprivate let started: ContinuousClock.Instant

    @discardableResult
    func end(_ detail: String = "") -> Double {
      let elapsed = started.duration(to: .now)
      let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
      MyraPerformance.signposter.endInterval("mark", state, "\(detail, privacy: .public)")
      MyraPerformance.logger.info(
        "\(name, privacy: .public): \(seconds, format: .fixed(precision: 3)) s \(detail, privacy: .public)"
      )
      MyraPerformance.recorder.record(name, seconds: seconds, detail: detail)
      return seconds
    }
  }

  static func begin(_ name: String) -> Interval {
    let id = signposter.makeSignpostID()
    let state = signposter.beginInterval("mark", id: id, "\(name, privacy: .public)")
    return Interval(name: name, state: state, started: .now)
  }

  /// Times a synchronous block.
  static func measure<T>(_ name: String, detail: String = "", _ body: () throws -> T) rethrows -> T {
    let interval = begin(name)
    defer { interval.end(detail) }
    return try body()
  }

  /// When this process started, from the kernel. Used for launch-to-first-shelf.
  static let processStart: Date = {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0 else { return .now }
    let start = info.kp_proc.p_un.__p_starttime
    return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1e6)
  }()

  private static let firstShelfLock = NSLock()
  nonisolated(unsafe) private static var firstShelfNoted = false

  /// Records the launch-to-first-Home-shelf duration once per process.
  static func noteFirstHomeShelf() {
    firstShelfLock.lock()
    defer { firstShelfLock.unlock() }
    guard !firstShelfNoted else { return }
    firstShelfNoted = true
    let seconds = Date.now.timeIntervalSince(processStart)
    logger.info("\(PerfMark.launchToFirstShelf, privacy: .public): \(seconds, format: .fixed(precision: 3)) s")
    recorder.record(PerfMark.launchToFirstShelf, seconds: seconds)
  }

  /// Test hook: allows the once-per-process mark to be recorded again.
  static func resetFirstShelfForTesting() {
    firstShelfLock.lock()
    firstShelfNoted = false
    firstShelfLock.unlock()
  }
}

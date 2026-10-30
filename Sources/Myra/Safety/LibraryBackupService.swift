import Foundation
import OSLog

/// Runs backups, the daily schedule, restore and its undo, and the storage totals for Settings >
/// Data. The pure rules live in `LibraryBackupStore` and `BackupRetention`; this type sequences them.
@MainActor
final class LibraryBackupService: ObservableObject {
  static let keepKey = "backupKeepCount"
  static let dailyKey = "backupDailyEnabled"

  @Published private(set) var records: [BackupRecord] = []
  @Published private(set) var isWorking = false
  @Published private(set) var storage: StorageSummary?
  @Published private(set) var rollbackAvailable = false
  /// Result of the last action, shown beside the Data settings.
  @Published var message: String?

  private let library: LibraryController
  private let entertainment: EntertainmentStore
  private let personalURL: URL
  let backupStore: LibraryBackupStore
  private let defaults: UserDefaults
  private let logger = Logger(subsystem: "Myra", category: "Backups")

  init(
    library: LibraryController, entertainment: EntertainmentStore, personalURL: URL,
    backupRoot: URL, defaults: UserDefaults = .standard
  ) {
    self.library = library
    self.entertainment = entertainment
    self.personalURL = personalURL
    self.backupStore = LibraryBackupStore(root: backupRoot)
    self.defaults = defaults
  }

  /// How many backups to keep. Applies to daily and manual backups alike.
  var keep: Int {
    get {
      let value = defaults.integer(forKey: Self.keepKey)
      return BackupRetention.keepChoices.contains(value) ? value : BackupRetention.defaultKeep
    }
    set {
      defaults.set(BackupRetention.keepChoices.contains(newValue) ? newValue : BackupRetention.defaultKeep, forKey: Self.keepKey)
      objectWillChange.send()
    }
  }

  var dailyEnabled: Bool {
    get { defaults.object(forKey: Self.dailyKey) as? Bool ?? true }
    set {
      defaults.set(newValue, forKey: Self.dailyKey)
      objectWillChange.send()
    }
  }

  func refresh() {
    records = backupStore.records()
    rollbackAvailable = !backupStore.rollbackSnapshots().isEmpty
  }

  /// Creates a backup of the library index and the personal data now.
  func backUpNow(kind: BackupKind = .manual) async {
    guard !isWorking else { return }
    isWorking = true
    defer { isWorking = false }
    do {
      let index = try await library.database()
      let store = backupStore
      let personal = personalURL
      let keep = keep
      let record = try await store.create(
        kind: kind, now: .now, appVersion: Self.appVersion, personalSource: personal,
        writeDatabase: { url in try await index.backup(to: url) })
      let removed = try store.prune(keep: keep)
      refresh()
      message =
        "Backed up \(record.manifest.createdAt.formatted(date: .abbreviated, time: .shortened))."
        + (removed.isEmpty ? "" : " Removed \(removed.count) older backup(s) beyond \(keep).")
    } catch {
      logger.error("Backup failed: \(error.localizedDescription, privacy: .public)")
      message = "Backup failed: \(error.localizedDescription)"
    }
  }

  /// Runs the daily backup when none has been made in the last day. Called at launch.
  func runDailyIfDue(now: Date = .now) async {
    guard dailyEnabled else { return }
    refresh()
    guard BackupRetention.isDailyDue(newest: records.first?.createdAt, now: now) else { return }
    await backUpNow(kind: .daily)
  }

  /// Restores watched state and preferences from a backup. The current state is kept first, so
  /// Undo can return to it. The library index is not changed.
  func restore(_ record: BackupRecord) async {
    guard !isWorking else { return }
    isWorking = true
    defer { isWorking = false }
    do {
      let staged = try backupStore.stageRestore(of: record)
      _ = try backupStore.preserveRollback(current: personalURL, now: .now, keep: keep)
      try entertainment.restorePersonalBackup(staged.data)
      refresh()
      message = "Restored watched state and preferences from \(record.createdAt.formatted(date: .abbreviated, time: .shortened)). Use Undo to return to the state before."
    } catch {
      message = "Restore did not change anything: \(error.localizedDescription)"
    }
  }

  /// Returns to the personal data kept before the most recent restore.
  func undoLastRestore() async {
    guard !isWorking else { return }
    isWorking = true
    defer { isWorking = false }
    guard let url = backupStore.rollbackSnapshots().first else {
      message = "There is no earlier state to return to."
      return
    }
    do {
      let data = try LibraryBackupStore.readPersonal(at: url)
      // Keep the state being replaced, so an undo can itself be undone.
      _ = try backupStore.preserveRollback(current: personalURL, now: .now, keep: keep)
      try entertainment.restorePersonalBackup(data)
      refresh()
      message = "Returned to the state before the last restore."
    } catch {
      message = "Undo did not change anything: \(error.localizedDescription)"
    }
  }

  func refreshStorage() async {
    let reclaimable = await library.reclaimableCaches()
    let indexURL = (try? await library.database())?.url
    storage = StorageSummary.make(
      indexURL: indexURL ?? personalURL.deletingLastPathComponent().appending(path: LibraryBackupStore.databaseName),
      backupsURL: backupStore.root,
      artworkURL: ArtworkDiskCache.defaultDirectory(),
      reclaimable: reclaimable)
  }

  /// Removes regenerable caches only. The library index, settings, backups and credentials are kept.
  func cleanUp() async {
    guard !isWorking else { return }
    isWorking = true
    defer { isWorking = false }
    let report = await library.cleanUpRegenerableCaches()
    await refreshStorage()
    if report.failed.isEmpty {
      message = "Reclaimed \(StorageSummary.formatted(report.reclaimedBytes))."
    } else {
      message = "Reclaimed \(StorageSummary.formatted(report.reclaimedBytes)). Some items could not be removed."
    }
  }

  static var appVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "4.1"
  }
}

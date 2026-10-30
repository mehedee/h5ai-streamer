import XCTest

@testable import Myra

/// Phase 4: backup retention, the daily schedule, backup and restore on an isolated temporary
/// folder, the first-run checks and the storage totals. No real library is opened.
final class SafetyTests: XCTestCase {
  private var scratch: URL!
  private let fileManager = FileManager.default

  override func setUpWithError() throws {
    scratch = fileManager.temporaryDirectory.appending(
      path: "myra-safety-\(UUID().uuidString)", directoryHint: .isDirectory)
    try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? fileManager.removeItem(at: scratch)
  }

  private var store: LibraryBackupStore {
    LibraryBackupStore(root: scratch.appending(path: "Backups", directoryHint: .isDirectory))
  }

  private func personal(watched: Set<String>, schema: Int = 1) throws -> Data {
    var data = EntertainmentPersonalData()
    data.schemaVersion = schema
    data.watched = watched
    data.preferences.preferredQuality = "1080p"
    return try JSONEncoder().encode(data)
  }

  private func writePersonal(watched: Set<String>, to url: URL) throws {
    try personal(watched: watched).write(to: url)
  }

  // MARK: - Retention and schedule

  func testRetentionKeepsNewestAndNamesTheRest() {
    let base = Date(timeIntervalSince1970: 1_000)
    let items = (0..<10).map { ($0, base.addingTimeInterval(TimeInterval($0) * 3_600)) }
    let removed = BackupRetention.removals(items, keep: 7) { $0.1 }.map(\.0).sorted()
    XCTAssertEqual(removed, [0, 1, 2])
  }

  func testRetentionNeverRemovesEverythingWhenKeepIsZero() {
    let items = [1, 2, 3]
    let removed = BackupRetention.removals(items, keep: 0) { Date(timeIntervalSince1970: Double($0)) }
    XCTAssertEqual(removed.count, 2)
  }

  func testDailyBackupIsDueOnlyAfterADay() {
    let now = Date(timeIntervalSince1970: 2_000_000)
    XCTAssertTrue(BackupRetention.isDailyDue(newest: nil, now: now))
    XCTAssertFalse(BackupRetention.isDailyDue(newest: now.addingTimeInterval(-3_600), now: now))
    XCTAssertTrue(
      BackupRetention.isDailyDue(newest: now.addingTimeInterval(-86_400), now: now))
  }

  // MARK: - Backup creation and pruning

  func testCreateWritesManifestDatabaseAndPersonalCopy() async throws {
    let source = scratch.appending(path: "EntertainmentPersonal.json")
    try writePersonal(watched: ["movie|a|2020"], to: source)
    let record = try await store.create(
      kind: .manual, now: Date(timeIntervalSince1970: 1_700_000_000), appVersion: "4.1",
      personalSource: source,
      writeDatabase: { url in try Data("database".utf8).write(to: url) })
    XCTAssertEqual(record.manifest.kind, .manual)
    XCTAssertTrue(record.manifest.hasDatabase)
    XCTAssertTrue(record.manifest.hasPersonal)
    XCTAssertGreaterThan(record.bytes, 0)
    let folder = store.root.appending(path: record.id, directoryHint: .isDirectory)
    XCTAssertTrue(fileManager.fileExists(atPath: folder.appending(path: "LibraryIndex.sqlite").path))
    XCTAssertEqual(try store.personalData(in: record).watched, ["movie|a|2020"])
  }

  func testFailedBackupLeavesNoFinishedFolder() async throws {
    struct Boom: Error {}
    do {
      _ = try await store.create(
        kind: .daily, now: .now, appVersion: "4.1", personalSource: nil,
        writeDatabase: { _ in throw Boom() })
      XCTFail("The backup should have failed")
    } catch {
      XCTAssertTrue(error is Boom)
    }
    XCTAssertTrue(store.records().isEmpty)
    let names = (try? fileManager.contentsOfDirectory(atPath: store.root.path)) ?? []
    XCTAssertTrue(names.allSatisfy { !$0.hasSuffix(LibraryBackupStore.partialSuffix) })
  }

  func testRecordsListNewestFirstAndIgnoreUnfinishedFolders() async throws {
    let older = try await store.create(
      kind: .daily, now: Date(timeIntervalSince1970: 1_000), appVersion: "4.1", personalSource: nil,
      writeDatabase: nil)
    let newer = try await store.create(
      kind: .manual, now: Date(timeIntervalSince1970: 5_000), appVersion: "4.1", personalSource: nil,
      writeDatabase: nil)
    try fileManager.createDirectory(
      at: store.root.appending(path: "stale\(LibraryBackupStore.partialSuffix)", directoryHint: .isDirectory),
      withIntermediateDirectories: true)
    XCTAssertEqual(store.records().map(\.id), [newer.id, older.id])
  }

  func testPruneRemovesOldestBeyondKeep() async throws {
    var ids: [String] = []
    for offset in 0..<9 {
      let record = try await store.create(
        kind: .daily, now: Date(timeIntervalSince1970: Double(offset) * 86_400), appVersion: "4.1",
        personalSource: nil, writeDatabase: nil)
      ids.append(record.id)
    }
    let removed = try store.prune(keep: 7)
    XCTAssertEqual(removed.count, 2)
    XCTAssertEqual(store.records().count, 7)
    XCTAssertFalse(store.records().map(\.id).contains(ids[0]))
    XCTAssertFalse(store.records().map(\.id).contains(ids[1]))
    XCTAssertTrue(store.records().map(\.id).contains(ids[8]))
  }

  // MARK: - Restore

  func testStageRestoreReadsBackupWithoutTouchingIt() async throws {
    let source = scratch.appending(path: "EntertainmentPersonal.json")
    try writePersonal(watched: ["movie|old|1999"], to: source)
    let record = try await store.create(
      kind: .manual, now: .now, appVersion: "4.1", personalSource: source, writeDatabase: nil)
    let staged = try store.stageRestore(of: record)
    XCTAssertEqual(staged.data.watched, ["movie|old|1999"])
    XCTAssertTrue(fileManager.fileExists(atPath: staged.staged.path))
    XCTAssertTrue(staged.staged.path.hasPrefix(store.stagingDirectory.path))
    XCTAssertEqual(try store.personalData(in: record).watched, ["movie|old|1999"])
  }

  func testRestoreRefusesBackupWithoutPersonalData() async throws {
    let record = try await store.create(
      kind: .daily, now: .now, appVersion: "4.1", personalSource: nil, writeDatabase: nil)
    XCTAssertThrowsError(try store.stageRestore(of: record)) { error in
      XCTAssertEqual(error as? LibraryBackupError, .noPersonalData)
    }
  }

  func testNewerSchemaIsRejectedBeforeRestore() async throws {
    let source = scratch.appending(path: "EntertainmentPersonal.json")
    try personal(watched: [], schema: 2).write(to: source)
    let record = try await store.create(
      kind: .manual, now: .now, appVersion: "4.1", personalSource: source, writeDatabase: nil)
    XCTAssertThrowsError(try store.stageRestore(of: record)) { error in
      XCTAssertEqual(error as? LibraryBackupError, .unsupportedSchema)
    }
  }

  func testRollbackKeepsPreRestoreStateAndIsRetained() async throws {
    let current = scratch.appending(path: "EntertainmentPersonal.json")
    try writePersonal(watched: ["movie|current|2024"], to: current)
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    let kept = try store.preserveRollback(current: current, now: base, keep: 2)
    let rollback = try XCTUnwrap(kept)
    XCTAssertEqual(
      try LibraryBackupStore.readPersonal(at: rollback).watched, ["movie|current|2024"])
    for step in 1...3 {
      try writePersonal(watched: ["movie|step\(step)|2024"], to: current)
      _ = try store.preserveRollback(
        current: current, now: base.addingTimeInterval(Double(step) * 60), keep: 2)
    }
    XCTAssertEqual(store.rollbackSnapshots().count, 2)
  }

  func testRollbackIsNilWhenNothingExistsYet() async throws {
    let missing = scratch.appending(path: "none.json")
    XCTAssertNil(try store.preserveRollback(current: missing, now: .now, keep: 7))
  }

  // MARK: - Setup checks

  func testFirstRunOnlyWithoutSourcesOrLibraryFile() {
    XCTAssertTrue(SetupCheck.needsFirstRun(sourceCount: 0, libraryFileExists: false))
    XCTAssertFalse(SetupCheck.needsFirstRun(sourceCount: 1, libraryFileExists: false))
    XCTAssertFalse(SetupCheck.needsFirstRun(sourceCount: 0, libraryFileExists: true))
  }

  func testSourceAddressMustBeWebAddress() {
    XCTAssertEqual(SetupCheck.sourceAddressCheck("http://nas.local/movies/").status, .ok)
    XCTAssertEqual(SetupCheck.sourceAddressCheck("nas.local/movies").status, .ok)
    XCTAssertEqual(SetupCheck.sourceAddressCheck("ftp://nas.local/").status, .failed)
    XCTAssertEqual(SetupCheck.sourceAddressCheck("   ").status, .failed)
  }

  func testDownloadFolderCheckCoversMissingFileAndWritable() async throws {
    XCTAssertEqual(
      SetupCheck.downloadFolderCheck(path: scratch.appending(path: "later").path).status, .warning)
    let file = scratch.appending(path: "not-a-folder")
    try Data().write(to: file)
    XCTAssertEqual(SetupCheck.downloadFolderCheck(path: file.path).status, .failed)
    XCTAssertEqual(SetupCheck.downloadFolderCheck(path: scratch.path).status, .ok)
  }

  // MARK: - Storage

  func testStorageSummaryCountsIndexFilesAndReclaimableOnly() async throws {
    let index = scratch.appending(path: "LibraryIndex.sqlite")
    try Data(repeating: 1, count: 100).write(to: index)
    try Data(repeating: 2, count: 40).write(to: URL(fileURLWithPath: index.path + "-wal"))
    let artwork = scratch.appending(path: "Artwork", directoryHint: .isDirectory)
    try fileManager.createDirectory(at: artwork, withIntermediateDirectories: true)
    try Data(repeating: 3, count: 25).write(to: artwork.appending(path: "a"))
    let reclaim = [
      LibraryCleanup.Candidate(url: index, kind: .legacyHomeCache, bytes: 300),
      LibraryCleanup.Candidate(url: index, kind: .oldBackup, bytes: 50),
    ]
    let summary = StorageSummary.make(
      indexURL: index, backupsURL: scratch.appending(path: "Missing", directoryHint: .isDirectory),
      artworkURL: artwork, reclaimable: reclaim)
    XCTAssertEqual(summary.libraryIndexBytes, 140)
    XCTAssertEqual(summary.artworkBytes, 25)
    XCTAssertEqual(summary.backupBytes, 0)
    XCTAssertEqual(summary.reclaimableBytes, 350)
    XCTAssertEqual(summary.homeCacheBytes, 300)
    XCTAssertEqual(summary.totalBytes, 140 + 25 + 350)
    XCTAssertEqual(StorageSummary.share(50, of: 200), 0.25)
    XCTAssertEqual(StorageSummary.share(10, of: 0), 0)
  }
}

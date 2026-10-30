import Foundation

enum BackupKind: String, Codable, Sendable, Equatable {
  case daily, manual

  var title: String {
    switch self {
    case .daily: "Daily"
    case .manual: "Manual"
    }
  }
}

/// Written last into each backup folder. A folder without a readable manifest is not a backup.
struct BackupManifest: Codable, Equatable, Sendable {
  var schemaVersion = 1
  var createdAt: Date
  var kind: BackupKind
  var appVersion: String
  var hasDatabase: Bool
  var hasPersonal: Bool
}

struct BackupRecord: Identifiable, Equatable, Sendable {
  let id: String
  let manifest: BackupManifest
  let bytes: Int64

  var createdAt: Date { manifest.createdAt }
}

/// Backup retention and the daily schedule. Pure, so the rules are tested without a disk.
enum BackupRetention {
  static let defaultKeep = 7
  static let keepChoices = [7, 14, 30]
  static let dailyInterval: TimeInterval = 24 * 3_600

  /// A daily backup is due when none exists or the newest one is at least a day old.
  static func isDailyDue(newest: Date?, now: Date) -> Bool {
    guard let newest else { return true }
    return now.timeIntervalSince(newest) >= dailyInterval
  }

  /// Entries to remove so that only the newest `keep` remain. Input order does not matter.
  static func removals<Item>(_ items: [Item], keep: Int, date: (Item) -> Date) -> [Item] {
    let limit = max(1, keep)
    let newestFirst = items.sorted { date($0) > date($1) }
    return Array(newestFirst.dropFirst(limit))
  }
}

/// Files that hold the watched state, preferences and the library index, each backup folder
/// `<root>/<id>/`. Writes go to a `.partial` folder first and are renamed once complete, so an
/// interrupted backup never looks like a finished one.
struct LibraryBackupStore {
  static let databaseName = "LibraryIndex.sqlite"
  static let personalName = "EntertainmentPersonal.json"
  static let manifestName = "manifest.json"
  static let partialSuffix = ".partial"

  let root: URL

  var rollbackDirectory: URL { root.appending(path: "Rollbacks", directoryHint: .isDirectory) }
  var stagingDirectory: URL { root.appending(path: "Staging", directoryHint: .isDirectory) }

  /// Finished backups, newest first.
  func records(fileManager: FileManager = .default) -> [BackupRecord] {
    let names = (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []
    return names.compactMap { name -> BackupRecord? in
      guard !name.hasSuffix(Self.partialSuffix) else { return nil }
      let folder = root.appending(path: name, directoryHint: .isDirectory)
      guard let data = try? Data(contentsOf: folder.appending(path: Self.manifestName)),
        let manifest = try? Self.decoder.decode(BackupManifest.self, from: data)
      else { return nil }
      return BackupRecord(
        id: name, manifest: manifest, bytes: DirectorySize.bytes(of: folder, fileManager: fileManager))
    }
    .sorted { $0.createdAt > $1.createdAt }
  }

  /// Writes a complete backup. `writeDatabase` must produce a consistent copy of the library index
  /// at the URL it is given. `personalSource` is copied as it is; nil skips it.
  @discardableResult
  func create(
    kind: BackupKind, now: Date, appVersion: String, personalSource: URL?,
    writeDatabase: (@Sendable (URL) async throws -> Void)?, fileManager: FileManager = .default
  ) async throws -> BackupRecord {
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    let id = Self.folderName(for: now, kind: kind)
    let partial = root.appending(path: id + Self.partialSuffix, directoryHint: .isDirectory)
    let final = root.appending(path: id, directoryHint: .isDirectory)
    try? fileManager.removeItem(at: partial)
    try fileManager.createDirectory(at: partial, withIntermediateDirectories: true)
    do {
      var hasDatabase = false
      if let writeDatabase {
        try await writeDatabase(partial.appending(path: Self.databaseName))
        hasDatabase = true
      }
      var hasPersonal = false
      if let personalSource, fileManager.fileExists(atPath: personalSource.path) {
        try fileManager.copyItem(
          at: personalSource, to: partial.appending(path: Self.personalName))
        hasPersonal = true
      }
      let manifest = BackupManifest(
        createdAt: now, kind: kind, appVersion: appVersion, hasDatabase: hasDatabase,
        hasPersonal: hasPersonal)
      try Self.encoder.encode(manifest).write(
        to: partial.appending(path: Self.manifestName), options: .atomic)
      try fileManager.moveItem(at: partial, to: final)
      return BackupRecord(
        id: id, manifest: manifest, bytes: DirectorySize.bytes(of: final, fileManager: fileManager))
    } catch {
      try? fileManager.removeItem(at: partial)
      throw error
    }
  }

  /// Removes the oldest backups beyond `keep`. Returns the removed folder names.
  @discardableResult
  func prune(keep: Int, fileManager: FileManager = .default) throws -> [String] {
    let removals = BackupRetention.removals(records(fileManager: fileManager), keep: keep) {
      $0.createdAt
    }
    for record in removals {
      try fileManager.removeItem(at: root.appending(path: record.id, directoryHint: .isDirectory))
    }
    return removals.map(\.id)
  }

  /// The personal data stored in a backup, decoded and checked. Nothing is changed on disk.
  func personalData(in record: BackupRecord) throws -> EntertainmentPersonalData {
    let url = root.appending(path: record.id, directoryHint: .isDirectory).appending(
      path: Self.personalName)
    return try Self.readPersonal(at: url)
  }

  /// Copies a backup's personal data into the staging folder and decodes that copy, so the restore
  /// is applied from a verified file and the original backup is never touched.
  func stageRestore(of record: BackupRecord, fileManager: FileManager = .default) throws -> (
    data: EntertainmentPersonalData, staged: URL
  ) {
    guard record.manifest.hasPersonal else { throw LibraryBackupError.noPersonalData }
    try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
    let staged = stagingDirectory.appending(path: "\(record.id).json")
    try? fileManager.removeItem(at: staged)
    let source = root.appending(path: record.id, directoryHint: .isDirectory).appending(
      path: Self.personalName)
    try fileManager.copyItem(at: source, to: staged)
    return (try Self.readPersonal(at: staged), staged)
  }

  /// Keeps the current personal data before a restore so the restore can be undone.
  /// Returns nil when there is nothing to keep.
  func preserveRollback(
    current: URL, now: Date, keep: Int, fileManager: FileManager = .default
  ) throws -> URL? {
    guard fileManager.fileExists(atPath: current.path) else { return nil }
    try fileManager.createDirectory(at: rollbackDirectory, withIntermediateDirectories: true)
    let name = Self.stamp(now) + "-before-restore.json"
    let target = rollbackDirectory.appending(path: name)
    try fileManager.copyItem(at: current, to: target)
    let kept = rollbackSnapshots(fileManager: fileManager)
    for url in BackupRetention.removals(kept, keep: keep, date: Self.modified) {
      try? fileManager.removeItem(at: url)
    }
    return target
  }

  /// Rollback copies, newest first.
  func rollbackSnapshots(fileManager: FileManager = .default) -> [URL] {
    let names = (try? fileManager.contentsOfDirectory(atPath: rollbackDirectory.path)) ?? []
    return names.filter { $0.hasSuffix("-before-restore.json") }
      .map { rollbackDirectory.appending(path: $0) }
      .sorted { Self.modified($0) > Self.modified($1) }
  }

  static func readPersonal(at url: URL) throws -> EntertainmentPersonalData {
    let data = try Data(contentsOf: url)
    let decoded = try JSONDecoder().decode(EntertainmentPersonalData.self, from: data)
    guard decoded.schemaVersion == 1 else { throw LibraryBackupError.unsupportedSchema }
    return decoded
  }

  static func folderName(for date: Date, kind: BackupKind) -> String {
    stamp(date) + "-" + kind.rawValue + "-" + String(UUID().uuidString.prefix(6)).lowercased()
  }

  static func stamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
    return formatter.string(from: date)
  }

  private static func modified(_ url: URL) -> Date {
    (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
      ?? .distantPast
  }

  private static var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }

  private static var decoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}

enum LibraryBackupError: LocalizedError, Equatable {
  case noPersonalData
  case unsupportedSchema

  var errorDescription: String? {
    switch self {
    case .noPersonalData: "This backup has no watched or preferences data to restore."
    case .unsupportedSchema: "This backup was written by a newer version of Myra and cannot be read."
    }
  }
}

/// Byte totals for files and folders, used by the Storage view and the backup records.
enum DirectorySize {
  static func bytes(of url: URL, fileManager: FileManager = .default) -> Int64 {
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
    guard isDirectory.boolValue else {
      let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?
        .int64Value
      return size ?? 0
    }
    var total: Int64 = 0
    let enumerator = fileManager.enumerator(
      at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
    while let item = enumerator?.nextObject() as? URL {
      let values = try? item.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
      if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
    }
    return total
  }
}

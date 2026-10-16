import Foundation

/// Owns only hash-named children of a dedicated torrent cache, never HTTP downloads or library folders.
actor TorrentCache {
  nonisolated let root: URL
  private var limitBytes: Int64
  private var reservations: [TorrentIdentity: Int64] = [:]
  private var active = Set<TorrentIdentity>()
  private var retained = Set<TorrentIdentity>()
  var reservedBytes: Int64 { reservations.values.reduce(0, +) }

  init(root: URL, limitBytes: Int64) throws {
    guard root.isFileURL, limitBytes > 0 else { throw TorrentError.invalidSettings }
    let manager = FileManager.default
    try manager.createDirectory(
      at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    guard try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
      throw TorrentError.unsafePath
    }
    let standardized = root.standardizedFileURL.resolvingSymlinksInPath()
    self.root = standardized
    self.limitBytes = limitBytes
    // Account for existing payloads after a crash/restart, before permitting a new download.
    for child in try manager.contentsOfDirectory(
      at: standardized, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    {
      guard let identity = try? TorrentIdentity(rawValue: child.lastPathComponent),
        try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]).isDirectory
          == true,
        try child.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true
      else { continue }
      reservations[identity] = try Self.payloadBytes(in: child)
    }
  }
  func setLimit(bytes: Int64) throws {
    guard bytes > 0 else { throw TorrentError.invalidSettings }
    guard bytes >= reservedBytes else {
      throw TorrentError.quota(required: reservedBytes, available: bytes)
    }
    limitBytes = bytes
  }
  func reserve(_ identity: TorrentIdentity, bytes: Int64) throws -> URL {
    guard bytes > 0 else { throw TorrentError.invalidSettings }
    let folder = try checkedFolder(identity)
    let existing = reservations[identity] ?? 0
    let requested = max(existing, bytes)
    let available = max(0, limitBytes - (reservedBytes - existing))
    guard requested <= available else {
      throw TorrentError.quota(required: requested, available: available)
    }
    // A logical reservation also checks physical disk capacity before the engine starts downloading.
    if let capacity = try root.resourceValues(forKeys: [
      .volumeAvailableCapacityForImportantUsageKey
    ]).volumeAvailableCapacityForImportantUsage {
      let additional = max(0, requested - (try Self.payloadBytes(in: folder)))
      guard additional <= capacity else {
        throw TorrentError.quota(required: additional, available: capacity)
      }
    }
    if !FileManager.default.fileExists(atPath: folder.path) {
      try FileManager.default.createDirectory(
        at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    reservations[identity] = requested
    return folder
  }
  func protect(_ identity: TorrentIdentity, active isActive: Bool, retained isRetained: Bool) {
    // Protection is retained while the engine is alive, including graceful stop.
    if isActive { active.insert(identity) } else { active.remove(identity) }
    if isRetained { retained.insert(identity) } else { retained.remove(identity) }
  }
  func remove(_ identity: TorrentIdentity) throws {
    guard !active.contains(identity), !retained.contains(identity) else {
      throw TorrentError.protectedDownload
    }
    let folder = try checkedFolder(identity)
    if FileManager.default.fileExists(atPath: folder.path) {
      try FileManager.default.removeItem(at: folder)
    }
    reservations.removeValue(forKey: identity)
  }
  func reserveVideo(_ identity: TorrentIdentity, file: TorrentFile) throws -> URL {
    guard file.isPlayable else { throw TorrentError.unsafePath }
    let folder = try checkedFolder(identity)
    let used = try Self.payloadBytes(in: folder)
    let selected = folder.appending(path: file.path)
    guard selected.resolvingSymlinksInPath().path.hasPrefix(folder.path + "/") else {
      throw TorrentError.unsafePath
    }
    let existing = Int64((try? selected.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    let (required, overflow) = (used - existing).addingReportingOverflow(file.size)
    guard !overflow, required <= Int64.max - 48 * 1024 * 1024 else { throw TorrentError.unsafePath }
    return try reserve(identity, bytes: required + 48 * 1024 * 1024)
  }
  private func checkedFolder(_ identity: TorrentIdentity) throws -> URL {
    // Recheck the root each time; do not rely solely on initialization when performing deletion.
    guard root.resolvingSymlinksInPath().path == root.path else { throw TorrentError.unsafePath }
    let folder = root.appending(path: identity.rawValue, directoryHint: .isDirectory)
    guard folder.deletingLastPathComponent().path == root.path,
      folder.resolvingSymlinksInPath().path == folder.path
    else { throw TorrentError.unsafePath }
    if FileManager.default.fileExists(atPath: folder.path) {
      let attributes = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard attributes.isDirectory == true, attributes.isSymbolicLink != true else {
        throw TorrentError.unsafePath
      }
    }
    return folder
  }
  private static func payloadBytes(in folder: URL) throws -> Int64 {
    guard FileManager.default.fileExists(atPath: folder.path) else { return 0 }
    guard
      let enumerator = FileManager.default.enumerator(
        at: folder,
        includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
    else {
      throw TorrentError.unsafePath
    }
    var total: Int64 = 0
    for case let url as URL in enumerator {
      let values = try url.resourceValues(forKeys: [
        .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
      ])
      guard values.isSymbolicLink != true else { throw TorrentError.unsafePath }
      if values.isRegularFile == true {
        let (sum, overflow) = total.addingReportingOverflow(Int64(values.fileSize ?? 0))
        guard !overflow else { throw TorrentError.unsafePath }
        total = sum
      }
    }
    return total
  }
}

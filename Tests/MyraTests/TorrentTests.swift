import XCTest

@testable import Myra

final class TorrentTests: XCTestCase {
  private let fixtureHash = String(repeating: "a", count: 40)

  func testIdentityIsStableAcrossMagnetTitlesAndTrackers() throws {
    let first = try TorrentIdentity(
      magnet: "magnet:?xt=urn:btih:\(fixtureHash)&dn=Episode&tr=https%3A%2F%2Fexample.org")
    let second = try TorrentIdentity(
      magnet: "magnet:?dn=Other&xt=urn:btih:\(fixtureHash.uppercased())")
    XCTAssertEqual(first, second)
    XCTAssertEqual(first.rawValue, "btih-\(fixtureHash)")
    XCTAssertEqual(first.fileKey(index: 7), "myra-torrent:btih-\(fixtureHash):7")
    XCTAssertEqual(
      try TorrentIdentity(magnet: "magnet:?xt=urn:btih:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA").rawValue,
      "btih-" + String(repeating: "0", count: 40))
    XCTAssertEqual(
      try TorrentIdentity(magnet: "magnet:?xt=urn:btmh:1220" + String(repeating: "B", count: 64))
        .rawValue,
      "btmh-" + String(repeating: "b", count: 64))
    for invalid in [
      "https://example.org/movie", "magnet:?xt=urn:btih:../movie", "magnet:?xt=urn:btih:abc",
      "magnet:?dn=NoHash",
    ] {
      XCTAssertThrowsError(try TorrentIdentity(magnet: invalid))
    }
  }

  func testVideoSelectionRejectsTraversalSymlinksAndNonVideo() throws {
    XCTAssertTrue(TorrentFile(index: 0, path: "Show/Season 1/Episode 2.mkv", size: 900).isPlayable)
    for path in [
      "/movie.mkv", "../movie.mkv", "Show/../movie.mkv", "Show//movie.mkv", "Show\\movie.mkv",
      "Show/./movie.mkv", "movie.mkv\u{0}",
    ] {
      XCTAssertFalse(TorrentFile(index: 0, path: path, size: 900).isPlayable, path)
    }
    XCTAssertFalse(TorrentFile(index: 0, path: "poster.jpg", size: 100).isPlayable)
    XCTAssertFalse(TorrentFile(index: 0, path: "movie.mp4", size: 0).isPlayable)
    XCTAssertFalse(TorrentFile(index: 0, path: "movie.mp4", size: 100, isSymlink: true).isPlayable)
    let files = ["Show/Episode 10.mkv", "Show/Episode 2.mkv", "Show/poster.jpg"].enumerated().map {
      TorrentFile(index: $0.offset, path: $0.element, size: 100)
    }
    XCTAssertEqual(TorrentFile.playbackOrder(files).map(\.index), [1, 0])
  }

  func testSQLiteRoundTripUsesStableIdentityAndRetainsProgress() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "Myra-torrent-test-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appending(path: "torrents.sqlite")
    let identity = try TorrentIdentity(rawValue: "btih-\(fixtureHash)")
    let job = TorrentJob(
      identity: identity, name: "Series", source: .magnet("magnet:?xt=urn:btih:\(fixtureHash)"),
      files: [TorrentFile(index: 3, path: "Series/Episode 2.mkv", size: 1000)])
    let database = try TorrentDatabase(url: url)
    try await database.save(job)
    try await database.saveProgress(identity: identity, fileIndex: 3, seconds: 123, duration: 1000)
    let updated = TorrentJob(
      identity: identity, name: "Renamed", source: job.source, files: job.files,
      selectedFileIndex: 3, keepDownload: true)
    try await database.save(updated)
    let reopened = try TorrentDatabase(url: url)
    let jobs = try await reopened.jobs()
    XCTAssertEqual(jobs.count, 1)
    XCTAssertEqual(jobs.first?.name, "Renamed")
    XCTAssertEqual(jobs.first?.keepDownload, true)
    let progress = try await reopened.progress(identity: identity, fileIndex: 3)
    XCTAssertEqual(progress?.seconds, 123)
    XCTAssertEqual(progress?.duration, 1000)
    try await reopened.remove(identity)
    let remaining = try await reopened.jobs()
    let removedProgress = try await reopened.progress(identity: identity, fileIndex: 3)
    XCTAssertTrue(remaining.isEmpty)
    XCTAssertNil(removedProgress)
  }

  func testCacheQuotaCountsReservationsAndKeepsActiveAndRetainedFiles() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "Myra-cache-test-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let first = try TorrentIdentity(rawValue: "btih-\(fixtureHash)")
    let second = try TorrentIdentity(rawValue: "btih-" + String(repeating: "b", count: 40))
    let third = try TorrentIdentity(rawValue: "btih-" + String(repeating: "c", count: 40))
    let cache = try TorrentCache(root: root, limitBytes: 1000)
    let folder = try await cache.reserve(first, bytes: 600)
    try Data(repeating: 1, count: 100).write(to: folder.appending(path: "movie.mp4"))
    do {
      _ = try await cache.reserve(second, bytes: 500)
      XCTFail("quota must include reserved bytes")
    } catch { XCTAssertTrue(error is TorrentError) }
    // Selecting a second episode in the same torrent expands, not duplicates, its reservation.
    _ = try await cache.reserve(first, bytes: 650)
    let reserved = await cache.reservedBytes
    XCTAssertEqual(reserved, 650)
    await cache.protect(first, active: true, retained: false)
    do {
      try await cache.remove(first)
      XCTFail("active cache removed")
    } catch {}
    await cache.protect(first, active: false, retained: true)
    do {
      try await cache.remove(first)
      XCTFail("kept download removed")
    } catch {}
    XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appending(path: "movie.mp4").path))
    await cache.protect(first, active: false, retained: false)
    try await cache.remove(first)
    _ = try await cache.reserve(second, bytes: 900)
    do {
      try await cache.setLimit(bytes: 800)
      XCTFail("cannot silently shrink below reservations")
    } catch {}
    // An unexpected symlink may never redirect cache allocation or deletion.
    try FileManager.default.createSymbolicLink(
      at: root.appending(path: third.rawValue), withDestinationURL: root.deletingLastPathComponent()
    )
    do {
      _ = try await cache.reserve(third, bytes: 1)
      XCTFail("symlink accepted")
    } catch {}
    XCTAssertTrue(FileManager.default.fileExists(atPath: root.deletingLastPathComponent().path))
  }

  func testSettingsDefaultAndValidation() throws {
    XCTAssertThrowsError(
      try JSONDecoder().decode(
        TorrentIdentity.self, from: Data("{\"rawValue\":\"../outside\"}".utf8)))
    let settings = TorrentPreferences()
    XCTAssertEqual(settings.cacheLimitGB, 10)
    XCTAssertFalse(settings.seedAfterCompletion)
    XCTAssertEqual(settings.cacheLimitBytes, 10 * 1024 * 1024 * 1024)
    XCTAssertThrowsError(try TorrentPreferences(cacheLimitGB: 0).validated())
    XCTAssertThrowsError(try TorrentPreferences(uploadLimitKB: -1).validated())
  }

  func testPreferencesPersistAndInvalidSelectionsNeverEnterDatabase() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "Myra-torrent-settings-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appending(path: "torrents.sqlite")
    let database = try TorrentDatabase(url: url)
    let preferences = TorrentPreferences(
      cacheLimitGB: 20, seedAfterCompletion: true, uploadLimitKB: 512)
    try await database.savePreferences(preferences)
    let reopened = try TorrentDatabase(url: url)
    let restored = try await reopened.preferences()
    XCTAssertEqual(restored, preferences)
    let identity = try TorrentIdentity(rawValue: "btih-\(fixtureHash)")
    var job = TorrentJob(
      identity: identity, name: "Invalid selection",
      source: .magnet("magnet:?xt=urn:btih:\(fixtureHash)"),
      files: [TorrentFile(index: 0, path: "movie.mkv", size: 1000)], selectedFileIndex: 1)
    do {
      try await database.save(job)
      XCTFail("unknown video selection persisted")
    } catch {}
    job.selectedFileIndex = nil
    job.files.append(job.files[0])
    do {
      try await database.save(job)
      XCTFail("duplicate file indices persisted")
    } catch {}
    let jobs = try await database.jobs()
    XCTAssertTrue(jobs.isEmpty)
  }

  func testCacheRestartCountsPayloadAlreadyOnDisk() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "Myra-torrent-cache-restart-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let identity = try TorrentIdentity(rawValue: "btih-\(fixtureHash)")
    let other = try TorrentIdentity(rawValue: "btih-" + String(repeating: "b", count: 40))
    let first = try TorrentCache(root: root, limitBytes: 1000)
    let folder = try await first.reserve(identity, bytes: 600)
    try Data(repeating: 9, count: 300).write(to: folder.appending(path: "movie.mkv"))
    let reopened = try TorrentCache(root: root, limitBytes: 500)
    let recoveredSize = await reopened.reservedBytes
    XCTAssertEqual(recoveredSize, 300)
    do {
      _ = try await reopened.reserve(other, bytes: 250)
      XCTFail("existing disk payload ignored")
    } catch {}
    XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appending(path: "movie.mkv").path))
  }
}

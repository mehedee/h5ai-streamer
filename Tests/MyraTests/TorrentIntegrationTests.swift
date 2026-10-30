import AppKit
import SwiftUI
import VLCKit
import XCTest

@testable import Myra

final class TorrentIntegrationTests: XCTestCase {
  /// Each test gets its own defaults suite so the real app's consent is never read or written.
  private func isolatedConsent() -> TorrentConsent {
    let suite = "Myra-torrent-consent-\(UUID())"
    let defaults = UserDefaults(suiteName: suite) ?? .standard
    return TorrentConsent(defaults: defaults)
  }

  func testDiscoverySourceValidationSeparatesKeysAndRejectsUnsafeTransports() throws {
    XCTAssertEqual(
      try TorznabSource.validatedEndpoint("https://index.example/api").host, "index.example")
    XCTAssertEqual(try TorznabSource.validatedEndpoint("http://127.0.0.1:9117/api").port, 9117)
    for invalid in [
      "http://public.example/api", "https://user:secret@index.example/api",
      "https://index.example/api?apikey=secret", "file:///tmp/api",
      "https://index.example/api#fragment",
    ] {
      XCTAssertThrowsError(try TorznabSource.validatedEndpoint(invalid))
    }
    let source = TorznabSource(
      name: "Test", endpoint: URL(string: "https://index.example/api?custom=1")!)
    let url = try TorrentDiscoveryService.torznabURL(
      source: source, key: "fixture + key", query: "Series & Episode", page: 2)
    let params = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
    XCTAssertEqual(params.first { $0.name == "offset" }?.value, "20")
    XCTAssertEqual(params.first { $0.name == "apikey" }?.value, "fixture + key")
    XCTAssertEqual(params.first { $0.name == "q" }?.value, "Series & Episode")
    XCTAssertEqual(params.first { $0.name == "custom" }?.value, "1")
    let encoded = try JSONEncoder().encode(source)
    XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("fixture + key"))
  }

  func testArchiveParsingKeepsDeclaredOpenLicensesAndSafeIdentifiers() throws {
    let data = Data(
      #"{"response":{"docs":[{"identifier":"open-movie","title":"Movie","licenseurl":"https://creativecommons.org/licenses/by/4.0/"},{"identifier":"public-domain","title":"PD","licenseurl":["http://creativecommons.org/publicdomain/mark/1.0/"]},{"identifier":"../bad","title":"Bad","licenseurl":"https://creativecommons.org/licenses/by/4.0/"},{"identifier":"closed","title":"Closed","licenseurl":"https://example.org/closed"},{"identifier":"missing","title":"Missing"}]}}"#
        .utf8)
    let items = try TorrentDiscoveryService.parseArchive(data)
    XCTAssertEqual(items.map(\.archiveID), ["open-movie", "public-domain"])
    XCTAssertNil(items.first?.torrentURL)
    let url = TorrentDiscoveryService.archiveURL(query: #"movie" OR licenseurl:*"#, page: 1)
    let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first {
      $0.name == "q"
    }?.value
    XCTAssertEqual(query, #"mediatype:movies AND licenseurl:* AND title:"movie\" OR licenseurl:*""#)
    XCTAssertThrowsError(try TorrentDiscoveryService.parseArchive(Data("{}".utf8)))
  }

  func testTorznabMagnetAndEnclosureParsingRejectsEntities() throws {
    let source = TorznabSource(name: "Fixture", endpoint: URL(string: "https://index.example/api")!)
    let hash = String(repeating: "b", count: 40)
    let xml = """
      <rss xmlns:torznab="http://torznab.com/schemas/2015/feed"><channel>
      <item><title>Episode 1 &amp; more</title><enclosure url="https://index.example/get?id=2&amp;apikey=fixture" type="application/x-bittorrent" length="4096"/><torznab:attr name="magneturl" value="magnet:?xt=urn:btih:\(hash)"/><torznab:attr name="seeders" value="5"/></item>
      <item><title>Episode 2</title><enclosure url="https://index.example/get?id=3&amp;apikey=fixture" type="application/x-bittorrent" length="8192"/></item>
      <item><title>Not torrent</title><enclosure url="file:///etc/passwd" type="text/plain"/></item>
      </channel></rss>
      """
    let indexer = TorrentIndexer(
      id: source.id, name: source.name, kind: .torznab, url: source.endpoint, enabled: true,
      isBuiltIn: false)
    let items = try TorznabParser.parse(Data(xml.utf8), indexer: indexer).results
    XCTAssertEqual(items.count, 2)
    XCTAssertEqual(items.first?.title, "Episode 1 & more")
    XCTAssertEqual(items.first?.seeders, 5)
    XCTAssertEqual(items.first?.size, 4096)
    XCTAssertNotNil(items.first?.magnet)
    XCTAssertNotNil(items.last?.torrentURL)
    XCTAssertEqual(items.last?.sourceURL, source.endpoint)
    XCTAssertFalse(items.last!.sourceURL!.absoluteString.contains("fixture"))
    XCTAssertThrowsError(
      try TorznabParser.parse(
        Data("<!DOCTYPE rss [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><rss>&x;</rss>".utf8),
        indexer: indexer))
    XCTAssertThrowsError(
      try TorznabParser.parse(Data("<error code='100'/>".utf8), indexer: indexer))
  }

  func testVideoReservationDoesNotDoubleCountSelectedFile() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "Myra-torrent-video-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = try TorrentCache(root: root, limitBytes: 60 * 1024 * 1024)
    let identity = try TorrentIdentity(rawValue: "btih-" + String(repeating: "c", count: 40))
    let file = TorrentFile(index: 0, path: "movie.mp4", size: 1024)
    let folder = try await cache.reserveVideo(identity, file: file)
    let before = await cache.reservedBytes
    try Data(repeating: 1, count: 1024).write(to: folder.appending(path: file.path))
    _ = try await cache.reserveVideo(identity, file: file)
    let after = await cache.reservedBytes
    XCTAssertEqual(before, after)
    do {
      _ = try await cache.reserveVideo(
        identity, file: TorrentFile(index: 1, path: "second.mp4", size: 20 * 1024 * 1024))
      XCTFail("Over quota selection must not start")
    } catch TorrentError.quota {}
  }

  @MainActor
  func testRestartIsPausedAndNetworkingRequiresConsent() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "Myra-torrent-controller-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let db = try TorrentDatabase(url: root.appending(path: "torrents.sqlite"))
    let id = try TorrentIdentity(rawValue: "btih-" + String(repeating: "a", count: 40))
    try await db.save(
      TorrentJob(
        identity: id, name: "Series",
        source: .magnet("magnet:?xt=urn:btih:" + String(repeating: "a", count: 40)),
        files: [TorrentFile(index: 0, path: "Episode 1.mp4", size: 1024)], keepDownload: true))
    let controller = TorrentController(consent: isolatedConsent())
    controller.storageURL = root
    await controller.load()
    XCTAssertTrue(controller.ready)
    XCTAssertFalse(controller.hasConsent)
    XCTAssertEqual(controller.jobs.count, 1)
    XCTAssertTrue(controller.transfers[id.rawValue]?.paused == true)
    await controller.resume(id)
    XCTAssertTrue(controller.error?.contains("privacy notice") == true)
    controller.error = nil
    await controller.remove(id)
    XCTAssertNotNil(controller.error)
    XCTAssertEqual(controller.jobs.count, 1)
    controller.shutdown()
  }

  @MainActor
  func testRealHelperImportStreamingPauseResumeRestartAndRemoval() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let engine = env["MYRA_TORRENT_ENGINE"], let torrent = env["MYRA_TORRENT_FIXTURE_FILE"],
      let port = env["MYRA_TORRENT_FIXTURE_PORT"].flatMap(Int.init)
    else {
      throw XCTSkip(
        "Set the local native torrent fixture and engine to exercise full app integration.")
    }
    // The native helper requires a canonical path. macOS exposes temporaryDirectory
    // through /var, which resolves to /private/var after std::filesystem::canonical.
    let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appending(
      path: "Myra-torrent-end-to-end-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let consent = isolatedConsent()
    consent.grant()
    let controller = TorrentController(consent: consent)
    controller.storageURL = root
    controller.engineURL = URL(fileURLWithPath: engine)
    controller.testPeerPort = port
    await controller.load()
    let data = try Data(contentsOf: URL(fileURLWithPath: torrent))
    await controller.importTorrent(data)
    XCTAssertNil(controller.error)
    let job = try XCTUnwrap(controller.jobs.first)
    // Keep after watching: playback closure must not forget this fixture's cache.
    await controller.setKeep(job.identity, keep: true)
    let file = try XCTUnwrap(job.files.first)
    XCTAssertTrue(file.isPlayable)
    var played: GlobalSearchResult?
    var resumed: Double?
    controller.playStream = { media, seconds in
      played = media
      resumed = seconds
    }
    let selected = await controller.select(job.identity, file: file, play: true)
    XCTAssertTrue(selected)
    let deadline = Date.now.addingTimeInterval(20)
    while played == nil && Date.now < deadline { try await Task.sleep(for: .milliseconds(100)) }
    let media = try XCTUnwrap(played, controller.error ?? "No stream delivered")
    XCTAssertEqual(resumed, 0)
    XCTAssertEqual(media.entry.url.pathExtension, "mp4")
    XCTAssertTrue(controller.isTorrent(media))
    var request = URLRequest(url: media.entry.url)
    request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
    let (bytes, response) = try await URLSession.shared.data(for: request)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 206)
    XCTAssertEqual(bytes.count, 1024)
    XCTAssertEqual(String(data: bytes[4..<8], encoding: .ascii), "ftyp")
    let player = EmbeddedPlayerModel()
    let library = LibraryController(
      index: try LibraryIndex(url: root.appending(path: "isolated-library.sqlite")))
    let window = NSWindow(
      contentRect: NSRect(x: 100, y: 100, width: 640, height: 360),
      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let video = VLCVideoView(frame: window.contentView!.bounds)
    window.contentView?.addSubview(video)
    player.setWindow(window)
    player.attach(view: video)
    window.makeKeyAndOrderFront(nil)
    player.setVolume(0)
    player.shouldRecordPosition = { _ in false }
    player.start(media, library: library, resumeSeconds: 0)
    defer {
      player.close()
      player.setWindow(nil)
      window.close()
    }
    let playbackDeadline = Date.now.addingTimeInterval(20)
    while (!player.isPlaying || player.elapsed < 1) && Date.now < playbackDeadline {
      try await Task.sleep(for: .milliseconds(100))
    }
    XCTAssertTrue(player.isPlaying, player.status)
    XCTAssertGreaterThan(player.elapsed, 0)
    player.seek(to: 0.75)
    let seekDeadline = Date.now.addingTimeInterval(20)
    while player.elapsed < 30 && Date.now < seekDeadline {
      try await Task.sleep(for: .milliseconds(100))
    }
    XCTAssertGreaterThanOrEqual(player.elapsed, 30)
    player.close()
    controller.record(media, seconds: 12, duration: 40)
    try await Task.sleep(for: .milliseconds(150))
    controller.pause(job.identity)
    try await Task.sleep(for: .seconds(2))
    XCTAssertTrue(controller.transfers[job.id]?.paused == true)
    await controller.resume(job.identity)
    controller.playerClosed()
    controller.cancel(job.identity)
    try await Task.sleep(for: .seconds(6))
    let restored = TorrentController(consent: consent)
    restored.storageURL = root
    restored.engineURL = URL(fileURLWithPath: engine)
    restored.testPeerPort = port
    await restored.load()
    XCTAssertTrue(restored.transfers[job.id]?.paused == true)
    let database = try TorrentDatabase(url: root.appending(path: "torrents.sqlite"))
    let progress = try await database.progress(identity: job.identity, fileIndex: file.index)
    XCTAssertEqual(progress?.seconds, 12)
    restored.playStream = { _, seconds in resumed = seconds }
    let restoredSelection = await restored.select(job.identity, file: file, play: true)
    XCTAssertTrue(restoredSelection)
    let resumeDeadline = Date.now.addingTimeInterval(15)
    resumed = nil
    while resumed == nil && Date.now < resumeDeadline {
      try await Task.sleep(for: .milliseconds(100))
    }
    XCTAssertEqual(resumed, 12)
    restored.cancel(job.identity)
    try await Task.sleep(for: .seconds(6))
    await restored.remove(job.identity)
    XCTAssertNil(restored.error)
    XCTAssertTrue(restored.jobs.isEmpty)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: root.appending(path: "Cache/" + job.id).path))
    controller.shutdown()
    restored.shutdown()
  }

  @MainActor
  func testTorrentScreenAndSettingsNativeLayout() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "Myra-torrent-layout-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let controller = TorrentController(consent: isolatedConsent())
    controller.storageURL = root
    await controller.load()
    let host = NSHostingView(rootView: TorrentsView(controller: controller))
    host.frame = NSRect(x: 0, y: 0, width: 1150, height: 760)
    let window = NSWindow(
      contentRect: host.frame, styleMask: [.titled, .resizable, .closable], backing: .buffered,
      defer: false)
    window.contentView = host
    window.isReleasedWhenClosed = false
    defer {
      window.close()
      controller.shutdown()
    }
    window.orderFront(nil)
    try await Task.sleep(for: .milliseconds(500))
    host.layoutSubtreeIfNeeded()
    XCTAssertEqual(host.bounds.width, 1150)
    if let path = ProcessInfo.processInfo.environment["MYRA_UI_SNAPSHOT_DIR"],
      let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)
    {
      host.cacheDisplay(in: host.bounds, to: bitmap)
      let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
      try png.write(to: URL(fileURLWithPath: path).appending(path: "torrent-discovery.png"))
    }
  }
}

import XCTest

@testable import Myra

/// Play / Download flow, consent, link routing and transfer rows. No public swarm is contacted:
/// these tests never start an engine.
final class TorrentFlowTests: XCTestCase {
  private let fixtureHash = String(repeating: "d", count: 40)

  private func isolatedDefaults() -> UserDefaults {
    UserDefaults(suiteName: "Myra-torrent-flow-\(UUID())") ?? .standard
  }

  private func file(_ index: Int, _ path: String, size: Int64 = 1000) -> TorrentFile {
    TorrentFile(index: index, path: path, size: size)
  }

  // MARK: Link routing

  func testLinksRouteToMagnetOrTorrentFileOnly() throws {
    let magnet = URL(string: "magnet:?xt=urn:btih:\(fixtureHash)&dn=Series")!
    XCTAssertEqual(TorrentLinkRouter.route(magnet), .magnet(magnet.absoluteString))
    let torrent = URL(fileURLWithPath: "/Users/example/Downloads/Movie.TORRENT")
    XCTAssertEqual(TorrentLinkRouter.route(torrent), .torrentFile(torrent))
    XCTAssertEqual(TorrentLinkRouter.route(URL(string: "https://example.org/a.torrent")!), .ignored)
    XCTAssertEqual(TorrentLinkRouter.route(URL(fileURLWithPath: "/tmp/notes.txt")), .ignored)
    XCTAssertEqual(TorrentLinkRouter.route(URL(string: "myra://open")!), .ignored)
  }

  func testDisplayNameComesFromDnParameterOnly() {
    XCTAssertEqual(
      TorrentLinkRouter.displayName(magnet: "magnet:?xt=urn:btih:\(fixtureHash)&dn=Show%20Name+S01"),
      "Show Name S01")
    XCTAssertNil(TorrentLinkRouter.displayName(magnet: "magnet:?xt=urn:btih:\(fixtureHash)"))
    XCTAssertNil(TorrentLinkRouter.displayName(magnet: "magnet:?xt=urn:btih:\(fixtureHash)&dn=%20%20"))
  }

  // MARK: Consent

  func testConsentIsOneTimeAndStoredUnderNamedKey() throws {
    let defaults = isolatedDefaults()
    let consent = TorrentConsent(defaults: defaults)
    XCTAssertFalse(consent.isGranted)
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    consent.grant(at: date)
    XCTAssertEqual(defaults.object(forKey: "torrentNetworkConsentDate") as? Date, date)
    XCTAssertEqual(TorrentConsent(defaults: defaults).grantedAt, date)
    XCTAssertTrue(TorrentConsent(defaults: defaults).isGranted)
    consent.withdraw()
    XCTAssertFalse(TorrentConsent(defaults: defaults).isGranted)
  }

  @MainActor
  func testAddingLinkWithoutConsentAsksOnceAndStartsNothing() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "Myra-torrent-consent-gate-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let controller = TorrentController(consent: TorrentConsent(defaults: isolatedDefaults()))
    controller.storageURL = root
    await controller.load()
    XCTAssertFalse(controller.hasConsent)
    let magnet = "magnet:?xt=urn:btih:\(fixtureHash)&dn=Gate"
    await controller.addMagnet(magnet)
    XCTAssertEqual(controller.consentRequest, .magnet(magnet))
    XCTAssertTrue(controller.jobs.isEmpty, "no job may exist before consent")
    XCTAssertNil(controller.error)
    controller.declineConsent()
    XCTAssertNil(controller.consentRequest)
    XCTAssertFalse(controller.hasConsent)
    controller.shutdown()
  }

  @MainActor
  func testOpenedMagnetRunsSameConsentGateAsPaste() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "Myra-torrent-open-url-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let controller = TorrentController(consent: TorrentConsent(defaults: isolatedDefaults()))
    controller.storageURL = root
    controller.handleOpenURL(URL(string: "magnet:?xt=urn:btih:\(fixtureHash)&dn=Opened")!)
    let deadline = Date.now.addingTimeInterval(5)
    while controller.consentRequest == nil && Date.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertEqual(controller.consentRequest, .magnet("magnet:?xt=urn:btih:\(fixtureHash)&dn=Opened"))
    XCTAssertTrue(controller.jobs.isEmpty)
    controller.shutdown()
  }

  @MainActor
  func testUnsupportedOpenedURLChangesNothing() async throws {
    let controller = TorrentController(consent: TorrentConsent(defaults: isolatedDefaults()))
    controller.handleOpenURL(URL(string: "https://example.org/movie")!)
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertNil(controller.consentRequest)
    XCTAssertNil(controller.error)
    XCTAssertTrue(controller.jobs.isEmpty)
    controller.shutdown()
  }

  func testConsentErrorNamesThePrivacyNotice() {
    XCTAssertTrue(
      TorrentError.consentRequired.errorDescription?.contains("privacy notice") == true)
  }

  // MARK: File selection order

  func testSeriesEpisodesSortBySeasonAndEpisodeNotLexically() {
    let files = [
      file(0, "Show/Season 10/S10E01.mkv"), file(1, "Show/S01E10.mkv"),
      file(2, "Show/S01E2.mkv"), file(3, "Show/S02E01.mkv"), file(4, "Show/Extras/Making of.mp4"),
      file(5, "Show/2x03.mkv"), file(6, "Show/poster.jpg"),
    ]
    let order = TorrentFile.playbackOrder(files).map(\.index)
    // Season/episode first (S01E02, S01E10, S02E01, 2x03 = S02E03, S10E01), then the unmarked extra.
    XCTAssertEqual(order, [2, 1, 3, 5, 0, 4])
  }

  func testEpisodeMarkersAreRecognisedInCommonForms() {
    XCTAssertEqual(TorrentEpisode(fileName: "Show.S01E02.1080p.mkv")?.number, 2)
    XCTAssertEqual(TorrentEpisode(fileName: "Show S1 E12.mkv")?.number, 12)
    XCTAssertEqual(TorrentEpisode(fileName: "show 3x07.mp4")?.season, 3)
    XCTAssertNil(TorrentEpisode(fileName: "Movie 2019 1080p.mkv"))
    XCTAssertNil(TorrentEpisode(fileName: "S999999E1.mkv"))
  }

  func testDefaultSelectionPicksFirstEpisodeForSeriesAndLargestForMovies() {
    let series = [file(0, "Show/E02.mkv"), file(1, "Show/S01E01.mkv"), file(2, "Show/S01E02.mkv")]
    XCTAssertEqual(TorrentFile.defaultSelection(in: series)?.index, 1)

    let movieParts = [file(0, "movie-part1.mkv", size: 100), file(1, "movie-part2.mkv", size: 900)]
    XCTAssertEqual(TorrentFile.defaultSelection(in: movieParts)?.index, 1)

    let single = [file(4, "Feature.mp4", size: 42)]
    XCTAssertEqual(TorrentFile.defaultSelection(in: single)?.index, 4)

    let tie = [file(3, "a.mkv", size: 500), file(1, "b.mkv", size: 500)]
    XCTAssertEqual(TorrentFile.defaultSelection(in: tie)?.index, 1, "lowest index breaks ties")

    XCTAssertNil(TorrentFile.defaultSelection(in: [file(0, "cover.jpg")]))
  }

  // MARK: Play / Download row model

  func testRowModelReportsPlayStreamingAndDownloadCompletion() throws {
    let identity = try TorrentIdentity(rawValue: "btih-\(fixtureHash)")
    let job = TorrentJob(
      identity: identity, name: "Series", source: .magnet("magnet:?xt=urn:btih:\(fixtureHash)"),
      files: [file(0, "Series/S01E01.mkv")], selectedFileIndex: 0)
    let streaming = TorrentTransfer(
      state: "Buffering · 2 s ahead", downloaded: 50, total: 100, downloadSpeed: 10,
      uploadSpeed: 0, peers: 3, paused: false, completed: false, exported: false,
      bufferedSeconds: 2, streamPercent: 50)
    let playing = TorrentTransferRow(job: job, transfer: streaming, isStreaming: true)
    XCTAssertEqual(playing.id, identity.rawValue)
    XCTAssertEqual(playing.name, "Series")
    XCTAssertEqual(playing.state, "Buffering · 2 s ahead")
    XCTAssertEqual(playing.bytesDone, 50)
    XCTAssertEqual(playing.bytesTotal, 100)
    XCTAssertEqual(playing.downloadSpeed, 10)
    XCTAssertEqual(playing.peers, 3)
    XCTAssertTrue(playing.isStreaming)
    XCTAssertFalse(playing.isComplete)
    XCTAssertEqual(playing.bufferedSeconds, 2)

    var finished = streaming
    finished.completed = true
    finished.paused = true
    let downloaded = TorrentTransferRow(job: job, transfer: finished, isStreaming: false)
    XCTAssertTrue(downloaded.isComplete)
    XCTAssertFalse(downloaded.isStreaming)
    XCTAssertTrue(downloaded.isPaused)
  }

  func testExportPathStaysBelowSharedDownloadFolderAndSanitisesNames() {
    let path = TorrentExportPath.relativePath(
      jobName: "Series: Part/1", file: file(0, "Season 1/Episode 1.mkv"))
    XCTAssertEqual(path, "Torrents/Series_ Part_1/Season 1/Episode 1.mkv")
    XCTAssertFalse(path.hasPrefix("/"))
    XCTAssertFalse(path.contains(".."))
  }

  func testExportNeverOverwritesAnExistingDownload() throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "Myra-torrent-export-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appending(path: "source.mkv")
    try Data(repeating: 7, count: 16).write(to: source)
    let destination = root.appending(path: "Torrents/Show/Episode 1.mkv")
    let first = try TorrentController.copyUnique(source, to: destination)
    XCTAssertEqual(first.lastPathComponent, "Episode 1.mkv")
    let second = try TorrentController.copyUnique(source, to: destination)
    XCTAssertEqual(second.lastPathComponent, "Episode 1 2.mkv")
    XCTAssertEqual(try Data(contentsOf: first), Data(repeating: 7, count: 16))
  }
}

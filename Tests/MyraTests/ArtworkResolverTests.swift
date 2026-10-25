import Foundation
import XCTest

@testable import Myra

final class ArtworkResolverTests: XCTestCase {
  private let helper = HomeCategoryClassifierTests()

  private func metadata(poster: String?, backdrop: String?) -> EntertainmentMetadata {
    var value = helper.metadata("Film", language: "en")
    value.posterURL = poster.flatMap(URL.init(string:))
    value.backdropURL = backdrop.flatMap(URL.init(string:))
    return value
  }

  func testFallbackOrderIsSourceThenTMDBThenOMDbThenTitleCard() throws {
    var title = helper.makeTitle(
      "Film", metadata: metadata(
        poster: "https://image.tmdb.org/t/p/w500/poster.jpg",
        backdrop: "https://image.tmdb.org/t/p/w780/backdrop.jpg"))
    title.versions[0] = withArtwork(title.versions[0], URL(fileURLWithPath: "/library/poster.jpg"))
    let movie = try omdb(poster: "https://m.media-amazon.com/images/M/omdb.jpg")

    XCTAssertEqual(
      ArtworkResolver.candidates(for: title, movie: movie),
      [
        .image(.source, URL(fileURLWithPath: "/library/poster.jpg")),
        .image(.tmdbPoster, URL(string: "https://image.tmdb.org/t/p/w500/poster.jpg")!),
        .image(.tmdbBackdrop, URL(string: "https://image.tmdb.org/t/p/w780/backdrop.jpg")!),
        .image(.omdbPoster, URL(string: "https://m.media-amazon.com/images/M/omdb.jpg")!),
        .titleCard,
      ])
  }

  func testMissingArtworkLeavesOnlyTitleCard() {
    let title = helper.makeTitle("Film")
    XCTAssertEqual(ArtworkResolver.candidates(for: title), [.titleCard])
  }

  func testDisallowedHostsAreSkipped() {
    let title = helper.makeTitle(
      "Film", metadata: metadata(poster: "https://example.com/p.jpg", backdrop: "http://image.tmdb.org/b.jpg"))
    XCTAssertEqual(ArtworkResolver.candidates(for: title), [.titleCard])
  }

  func testDuplicateURLsAppearOnce() {
    let url = "https://image.tmdb.org/t/p/w500/same.jpg"
    let title = helper.makeTitle("Film", metadata: metadata(poster: url, backdrop: url))
    XCTAssertEqual(
      ArtworkResolver.candidates(for: title),
      [.image(.tmdbPoster, URL(string: url)!), .titleCard])
  }

  func testOMDbNAPosterIsIgnored() throws {
    let title = helper.makeTitle("Film")
    XCTAssertEqual(
      ArtworkResolver.candidates(for: title, movie: try omdb(poster: "N/A")), [.titleCard])
  }

  func testBackdropFieldDecodesWhenMissing() throws {
    let legacy = Data(
      #"{"providerID":1,"title":"Film","overview":"","rating":7,"voteCount":1,"genres":[],"language":"en"}"#
        .utf8)
    let decoded = try JSONDecoder().decode(EntertainmentMetadata.self, from: legacy)
    XCTAssertNil(decoded.backdropURL)
    XCTAssertEqual(decoded.title, "Film")

    var withBackdrop = decoded
    withBackdrop.backdropURL = URL(string: "https://image.tmdb.org/t/p/w780/b.jpg")
    let roundTrip = try JSONDecoder().decode(
      EntertainmentMetadata.self, from: JSONEncoder().encode(withBackdrop))
    XCTAssertEqual(roundTrip.backdropURL, withBackdrop.backdropURL)
  }

  func testTitleCardHueIsStableAcrossCalls() {
    XCTAssertEqual(TitleCardPalette.hash(for: ""), 0xcbf2_9ce4_8422_2325)
    XCTAssertEqual(TitleCardPalette.hash(for: " Dangal "), TitleCardPalette.hash(for: "dangal"))
    XCTAssertEqual(TitleCardPalette.hue(for: "Dangal"), TitleCardPalette.hue(for: "Dangal"))
    XCTAssertTrue((0..<1).contains(TitleCardPalette.hue(for: "Dangal")))
  }

  func testPolicyAllowsOnlyHTTPSAllowlistedRemoteHosts() {
    XCTAssertTrue(ArtworkHostPolicy.allowsRemote(URL(string: "https://image.tmdb.org/a.jpg")!))
    XCTAssertTrue(ArtworkHostPolicy.allowsRemote(URL(string: "https://m.media-amazon.com/a.jpg")!))
    XCTAssertFalse(ArtworkHostPolicy.allowsRemote(URL(string: "http://image.tmdb.org/a.jpg")!))
    XCTAssertFalse(ArtworkHostPolicy.allowsRemote(URL(string: "https://evil.example/a.jpg")!))
  }

  // MARK: - Helpers

  private func withArtwork(_ version: EntertainmentVersion, _ url: URL) -> EntertainmentVersion {
    var copy = version
    copy.media = GlobalSearchResult(
      categoryID: version.media.categoryID, categoryName: version.media.categoryName,
      categoryRoot: version.media.categoryRoot, entry: version.media.entry,
      relativePath: version.media.relativePath, artworkURL: url)
    return copy
  }

  private func omdb(poster: String) throws -> MovieMetadata {
    let data = try JSONSerialization.data(withJSONObject: ["Poster": poster, "Response": "True"])
    return try JSONDecoder().decode(MovieMetadata.self, from: data)
  }
}

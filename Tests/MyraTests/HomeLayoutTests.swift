import Foundation
import XCTest

@testable import Myra

/// Home layout measurements and helpers that the redesign preview defines.
final class HomeLayoutTests: XCTestCase {
  private let helper = HomeCategoryClassifierTests()

  func testMeasurementsMatchThePreview() {
    XCTAssertEqual(HomeLayout.pageInset, 26)
    XCTAssertEqual(HomeLayout.heroHeight, 290)
    XCTAssertEqual(HomeLayout.heroRadius, 18)
    XCTAssertEqual(HomeLayout.posterWidth, 148)
    XCTAssertEqual(HomeLayout.stillWidth, 260)
    XCTAssertEqual(HomeLayout.shelfSpacing, 16)
    XCTAssertEqual(HomeLayout.upNextLeadingInset, 16)
  }

  func testShelfShowsAtMostSixtyCardsUntilExpanded() {
    XCTAssertEqual(HomeLayout.visibleCount(total: 200, expanded: false), 60)
    XCTAssertEqual(HomeLayout.visibleCount(total: 200, expanded: true), 200)
    XCTAssertEqual(HomeLayout.visibleCount(total: 12, expanded: false), 12)
  }

  func testSeeAllTitleFollowsExpansion() {
    XCTAssertEqual(HomeLayout.seeAllTitle(expanded: false), "See All")
    XCTAssertEqual(HomeLayout.seeAllTitle(expanded: true), "Show Fewer")
  }

  func testFilterChipShowsSelectedValueOrLabel() {
    XCTAssertEqual(HomeLayout.filterChipTitle(label: "Genre", selection: ""), "Genre")
    XCTAssertEqual(HomeLayout.filterChipTitle(label: "Genre", selection: "Comedy"), "Comedy")
  }

  func testBackdropPrefersBackdropThenPosterThenTitleCard() {
    let backdrop = URL(string: "https://image.tmdb.org/t/p/w780/backdrop.jpg")!
    let poster = URL(string: "https://image.tmdb.org/t/p/w500/poster.jpg")!
    var metadata = helper.metadata("Backdrop", language: "en")
    metadata.backdropURL = backdrop
    metadata.posterURL = poster
    let backdropTitle = helper.makeTitle("Backdrop", metadata: metadata)
    var posterOnly = helper.metadata("Poster", language: "en")
    posterOnly.posterURL = poster
    let posterTitle = helper.makeTitle("Poster", metadata: posterOnly)
    let bare = helper.makeTitle("Bare")

    XCTAssertEqual(
      HomeLayout.backdropCandidates(backdropTitle),
      [.image(.tmdbBackdrop, backdrop), .image(.tmdbPoster, poster)])
    XCTAssertEqual(HomeLayout.backdropCandidates(posterTitle), [.image(.tmdbPoster, poster)])
    XCTAssertEqual(HomeLayout.backdropCandidates(bare), [.titleCard])
  }

  func testPosterFallsBackToTitleCardWithoutArtwork() {
    let bare = helper.makeTitle("Bare")
    XCTAssertEqual(HomeLayout.posterCandidates(bare), [.titleCard])
  }
}

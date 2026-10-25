import Foundation
import XCTest

@testable import Myra

final class HomeCategoryClassifierTests: XCTestCase {
  private let root = URL(fileURLWithPath: "/library")

  /// Builds an indexed title. `folder` is the path under the library root, `file` the file name.
  func makeTitle(
    _ name: String, kind: EntertainmentKind = .movie, folder: String? = nil,
    file: String? = nil, metadata: EntertainmentMetadata? = nil, categoryName: String = "Library"
  ) -> EntertainmentTitle {
    let fileName = file ?? "\(name).mkv"
    let relative = folder.map { "\($0)/\(fileName)" } ?? fileName
    let url = root.appending(path: relative)
    let entry = DirectoryEntry(name: fileName, url: url, kind: .file)
    let media = GlobalSearchResult(
      categoryID: UUID(), categoryName: categoryName, categoryRoot: root, entry: entry,
      relativePath: relative, artworkURL: nil)
    let version = EntertainmentVersion(
      media: media, firstDiscovered: Date(timeIntervalSince1970: 0))
    return EntertainmentTitle(
      id: "\(kind.rawValue)|\(name)", name: name, year: nil, kind: kind, versions: [version],
      metadata: metadata)
  }

  func metadata(
    _ name: String, language: String, genres: [String] = [], rating: Double = 7
  ) -> EntertainmentMetadata {
    EntertainmentMetadata(
      providerID: 1, title: name, overview: "", posterURL: nil, rating: rating, voteCount: 10,
      releaseDate: nil, genres: genres, language: language)
  }

  func omdb(
    language: String? = nil, country: String? = nil, genre: String? = nil
  ) throws -> MovieMetadata {
    var fields: [String: String] = ["Response": "True"]
    fields["Language"] = language
    fields["Country"] = country
    fields["Genre"] = genre
    let data = try JSONSerialization.data(withJSONObject: fields.compactMapValues { $0 })
    return try JSONDecoder().decode(MovieMetadata.self, from: data)
  }

  // MARK: - Source order

  func testTMDBLanguageBeatsFolderName() {
    let title = makeTitle(
      "Film", folder: "Hindi", metadata: metadata("Film", language: "en"))
    let result = HomeCategoryClassifier.classify(title)
    XCTAssertEqual(result.primary, .englishMovies)
    XCTAssertEqual(result.primarySource, .tmdb)
  }

  func testFolderBeatsFileNameTag() {
    let title = makeTitle("Dangal", folder: "Bollywood", file: "Dangal.Korean.2016.mkv")
    let result = HomeCategoryClassifier.classify(title)
    XCTAssertEqual(result.primary, .hindiMovies)
    XCTAssertEqual(result.primarySource, .folder)
  }

  func testFolderNameClassifiesWhenNoMetadata() {
    let title = makeTitle("Dangal", folder: "Bollywood")
    let result = HomeCategoryClassifier.classify(title)
    XCTAssertEqual(result.primary, .hindiMovies)
    XCTAssertEqual(result.primarySource, .folder)
  }

  func testFileNameTagIsLastResort() {
    let title = makeTitle("Movie", file: "Movie.Hindi.2010.1080p.mkv")
    let result = HomeCategoryClassifier.classify(title)
    XCTAssertEqual(result.primary, .hindiMovies)
    XCTAssertEqual(result.primarySource, .fileName)
  }

  func testOMDbLanguageUsedWhenTMDBMissing() throws {
    let title = makeTitle("Dangal")
    let result = HomeCategoryClassifier.classify(
      title, movie: try omdb(language: "Hindi, English", country: "India"))
    XCTAssertEqual(result.primary, .hindiMovies)
    XCTAssertEqual(result.primarySource, .omdb)
  }

  func testTMDBLanguageBeatsOMDbLanguage() throws {
    let title = makeTitle("Film", metadata: metadata("Film", language: "hi"))
    let result = HomeCategoryClassifier.classify(
      title, movie: try omdb(language: "English"))
    XCTAssertEqual(result.primary, .hindiMovies)
    XCTAssertEqual(result.primarySource, .tmdb)
  }

  func testFolderIsNotConsultedWhenMetadataHasLanguage() {
    // A Hindi folder with a Japanese live-action movie: TMDB says it is not Hindi, so no language shelf.
    let title = makeTitle(
      "Film", folder: "Hindi", metadata: metadata("Film", language: "ja", genres: ["Drama"]))
    XCTAssertNil(HomeCategoryClassifier.classify(title).primary)
  }

  // MARK: - Anime

  func testJapaneseAnimationFromTMDBIsAnime() {
    let title = makeTitle(
      "Show", kind: .series,
      metadata: metadata("Show", language: "ja", genres: ["Animation", "Drama"]))
    let result = HomeCategoryClassifier.classify(title)
    XCTAssertEqual(result.primary, .anime)
    XCTAssertEqual(result.primarySource, .tmdb)
  }

  func testJapaneseLiveActionSeriesIsNotAnime() {
    let title = makeTitle(
      "Show", kind: .series, metadata: metadata("Show", language: "ja", genres: ["Drama"]))
    XCTAssertEqual(HomeCategoryClassifier.classify(title).primary, .tvSeries)
  }

  func testAnimeFolderIsAnimeWhateverTheMetadataSays() {
    let title = makeTitle(
      "Show", kind: .series, folder: "Anime", metadata: metadata("Show", language: "en"))
    let result = HomeCategoryClassifier.classify(title)
    XCTAssertEqual(result.primary, .anime)
    XCTAssertEqual(result.primarySource, .folder)
  }

  func testOMDbJapaneseAnimationIsAnime() throws {
    let title = makeTitle("Film")
    let result = HomeCategoryClassifier.classify(
      title, movie: try omdb(language: "Japanese", country: "Japan", genre: "Animation, Fantasy"))
    XCTAssertEqual(result.primary, .anime)
    XCTAssertEqual(result.primarySource, .omdb)
  }

  func testAnimationFromOtherCountryIsNotAnime() throws {
    let title = makeTitle("Film")
    let result = HomeCategoryClassifier.classify(
      title, movie: try omdb(language: "English", country: "United States", genre: "Animation"))
    XCTAssertEqual(result.primary, .englishMovies)
  }

  // MARK: - Other language and type shelves

  func testKoreanSeriesFromTMDB() {
    let title = makeTitle(
      "Drama", kind: .series, metadata: metadata("Drama", language: "ko", genres: ["Drama"]))
    XCTAssertEqual(HomeCategoryClassifier.classify(title).primary, .koreanSeries)
  }

  func testKoreanFilmHasNoLanguageShelf() {
    let title = makeTitle("Film", metadata: metadata("Film", language: "ko", genres: ["Drama"]))
    XCTAssertNil(HomeCategoryClassifier.classify(title).primary)
  }

  func testKDramaFolderMakesKoreanSeries() {
    let title = makeTitle("Show", kind: .series, folder: "K-Drama")
    XCTAssertEqual(HomeCategoryClassifier.classify(title).primary, .koreanSeries)
  }

  func testSeriesWithoutLanguageIsTVSeries() {
    let title = makeTitle("Show", kind: .series)
    let result = HomeCategoryClassifier.classify(title)
    XCTAssertEqual(result.primary, .tvSeries)
    XCTAssertEqual(result.primarySource, .type)
  }

  func testTVShowsFolderMakesTVSeries() {
    let title = makeTitle("Show", kind: .series, folder: "TV Shows")
    XCTAssertEqual(HomeCategoryClassifier.classify(title).primary, .tvSeries)
  }

  func testMovieWithNoEvidenceHasNoPrimaryShelf() {
    let result = HomeCategoryClassifier.classify(makeTitle("Mystery"))
    XCTAssertNil(result.primary)
    XCTAssertNil(result.primarySource)
  }

  func testPrimaryShelvesAreExclusiveButGenreShelvesOverlap() {
    let title = makeTitle(
      "Film", metadata: metadata("Film", language: "hi", genres: ["Documentary", "Family"]))
    let result = HomeCategoryClassifier.classify(title)
    XCTAssertEqual(result.primary, .hindiMovies)
    XCTAssertEqual(result.genreShelves, [.documentaries, .kidsAndFamily])
  }

  // MARK: - Genre shelves

  func testTMDBGenreIsFinalForDocumentaries() {
    // A drama in a Documentaries folder stays out of Documentaries: TMDB beats the folder.
    let title = makeTitle(
      "Film", folder: "Documentaries", metadata: metadata("Film", language: "en", genres: ["Drama"]))
    XCTAssertFalse(HomeCategoryClassifier.classify(title).genreShelves.contains(.documentaries))
  }

  func testDocumentaryFolderWhenNoGenreIsKnown() {
    let title = makeTitle("Film", folder: "Documentaries")
    XCTAssertTrue(HomeCategoryClassifier.classify(title).genreShelves.contains(.documentaries))
  }

  func testKidsGenreFromTMDB() {
    let title = makeTitle(
      "Film", metadata: metadata("Film", language: "en", genres: ["Family", "Comedy"]))
    XCTAssertTrue(HomeCategoryClassifier.classify(title).genreShelves.contains(.kidsAndFamily))
  }

  func testFamilyGuyFolderIsNotKidsAndFamily() {
    // Folder tags match whole components, so a title name that contains "Family" does not count.
    let title = makeTitle("Family Guy", kind: .series, folder: "Family Guy (1999)")
    XCTAssertFalse(HomeCategoryClassifier.classify(title).genreShelves.contains(.kidsAndFamily))
  }

  func testCategoryNameContributesFolderTags() {
    let title = makeTitle("Show", kind: .series, categoryName: "Anime")
    XCTAssertEqual(HomeCategoryClassifier.classify(title).primary, .anime)
  }
}

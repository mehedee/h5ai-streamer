import XCTest

@testable import Myra

/// Personal ratings, private notes, cast and trailer data. Pure model behaviour only: nothing here
/// touches the real profile or the network.
@MainActor
final class PersonalRatingNotesTests: XCTestCase {
  private func metadata(trailer: URL? = nil, credits: [EntertainmentCredit]? = nil)
    -> EntertainmentMetadata
  {
    EntertainmentMetadata(
      providerID: 7, title: "Sample", overview: "", posterURL: nil, rating: 6, voteCount: 3,
      releaseDate: nil, genres: [], language: "en", credits: credits, trailerURL: trailer)
  }

  private func title(id: String, metadata: EntertainmentMetadata?) -> EntertainmentTitle {
    EntertainmentTitle(
      id: id, name: "Sample", year: "2024", kind: .movie, versions: [], metadata: metadata)
  }

  func testPersonalDataWithoutRatingsOrNotesStillDecodes() throws {
    // Nil ratings and notes are left out of the file, as in a profile written before they existed.
    var data = EntertainmentPersonalData()
    data.watched = ["movie|a|2020"]
    let encoded = try JSONEncoder().encode(data)
    XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("ratings"))
    XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("notes"))

    let decoded = try JSONDecoder().decode(EntertainmentPersonalData.self, from: encoded)
    XCTAssertNil(decoded.ratings)
    XCTAssertNil(decoded.notes)
    XCTAssertEqual(decoded.watched, ["movie|a|2020"])
  }

  func testRatingsAndNotesRoundTripThroughTheBackupFormat() throws {
    var data = EntertainmentPersonalData()
    data.ratings = ["movie|a|2020": 4]
    data.notes = ["movie|a|2020": "Rewatch with friends"]
    let archive = EntertainmentArchive(personal: data, sources: [], appPreferences: nil)

    let encoded = try JSONEncoder().encode(archive)
    let restored = try JSONDecoder().decode(EntertainmentArchive.self, from: encoded)
    XCTAssertEqual(restored.personal.ratings, ["movie|a|2020": 4])
    XCTAssertEqual(restored.personal.notes, ["movie|a|2020": "Rewatch with friends"])
  }

  func testMetadataWithoutCastOrTrailerStillDecodes() throws {
    // Metadata cached before credits and trailers existed decodes with both absent.
    let legacy = try JSONEncoder().encode(metadata())
    var object = (try JSONSerialization.jsonObject(with: legacy) as? [String: Any]) ?? [:]
    object.removeValue(forKey: "credits")
    object.removeValue(forKey: "trailerURL")
    let stripped = try JSONSerialization.data(withJSONObject: object)
    let decoded = try JSONDecoder().decode(EntertainmentMetadata.self, from: stripped)
    XCTAssertNil(decoded.credits)
    XCTAssertNil(decoded.trailerURL)
    XCTAssertNil(decoded.openableTrailerURL)
  }

  func testTrailerOpensOnlyForAStoredWebLink() {
    XCTAssertEqual(
      metadata(trailer: URL(string: "https://www.youtube.com/watch?v=abc"))
        .openableTrailerURL?.absoluteString,
      "https://www.youtube.com/watch?v=abc")
    XCTAssertNil(metadata(trailer: URL(string: "file:///Users/someone/clip.mov"))
      .openableTrailerURL, "Local files are not trailers")
    XCTAssertNil(metadata(trailer: URL(string: "javascript:alert(1)")).openableTrailerURL)
    XCTAssertNil(metadata(trailer: nil).openableTrailerURL, "No stored link, no trailer")
  }

  func testTitleIdentityDoesNotDependOnMetadata() {
    // Ratings and notes are keyed by title ID. Attaching or refreshing metadata must not change it.
    let before = title(id: "movie|sample|2024", metadata: nil)
    let after = title(id: "movie|sample|2024", metadata: metadata(trailer: nil))
    XCTAssertEqual(before.id, after.id)
  }

  func testImportMergeKeepsThisMacsRatingsAndNotes() {
    var local = EntertainmentPersonalData()
    local.ratings = ["movie|a|2020": 2]
    local.notes = ["movie|a|2020": "Mine"]
    var imported = EntertainmentPersonalData()
    imported.ratings = ["movie|a|2020": 5, "movie|b|2021": 4]
    imported.notes = ["movie|a|2020": "Theirs", "movie|b|2021": "Only in the backup"]

    let merged = EntertainmentStore.mergedPersonal(local: local, imported: imported)
    XCTAssertEqual(merged.ratings, ["movie|a|2020": 2, "movie|b|2021": 4])
    XCTAssertEqual(merged.notes, ["movie|a|2020": "Mine", "movie|b|2021": "Only in the backup"])
  }

  func testImportMergeLeavesNoEmptyMapsBehind() {
    let merged = EntertainmentStore.mergedPersonal(
      local: EntertainmentPersonalData(), imported: EntertainmentPersonalData())
    XCTAssertNil(merged.ratings)
    XCTAssertNil(merged.notes)
  }

  func testCorrectingAMatchCarriesRatingAndNotesToTheNewTitle() {
    var data = EntertainmentPersonalData()
    data.ratings = ["movie|old|2019": 3]
    data.notes = ["movie|old|2019": "Good"]
    EntertainmentStore.moveTitleReferences(&data, from: "movie|old|2019", to: "movie|new|2019")
    XCTAssertEqual(data.ratings, ["movie|new|2019": 3])
    XCTAssertEqual(data.notes, ["movie|new|2019": "Good"])
  }

  private func makeStorage() -> URL {
    FileManager.default.temporaryDirectory
      .appending(path: "Myra-rating-notes-\(UUID())")
      .appending(path: "personal.json")
  }

  func testRatingAndNoteArePersistedLocallyAndSurviveReopen() {
    let storage = makeStorage()
    let store = EntertainmentStore(library: LibraryController(), storageURL: storage)
    store.setRating("movie|a|2020", stars: 4)
    store.setNote("movie|a|2020", text: "  Great ending  \n")

    let reopened = EntertainmentStore(library: LibraryController(), storageURL: storage)
    XCTAssertEqual(reopened.personal.ratings, ["movie|a|2020": 4])
    XCTAssertEqual(reopened.personal.notes, ["movie|a|2020": "Great ending"])
  }

  func testRatingClampsToFiveAndClearsAndBlankNoteRemoves() {
    let store = EntertainmentStore(library: LibraryController(), storageURL: makeStorage())
    store.setRating("movie|a|2020", stars: 9)
    XCTAssertEqual(store.personal.ratings, ["movie|a|2020": 5])

    store.setRating("movie|a|2020", stars: nil)
    XCTAssertNil(store.personal.ratings)

    store.setNote("movie|a|2020", text: "Something")
    store.setNote("movie|a|2020", text: "   ")
    XCTAssertNil(store.personal.notes)
  }

  func testNoteIsCappedAtMaximumLength() {
    let store = EntertainmentStore(library: LibraryController(), storageURL: makeStorage())
    store.setNote(
      "movie|a|2020", text: String(repeating: "n", count: EntertainmentStore.maxNoteLength + 10))
    XCTAssertEqual(store.personal.notes?["movie|a|2020"]?.count, EntertainmentStore.maxNoteLength)
  }

  func testBackupExportCarriesRatingsAndNotes() throws {
    let store = EntertainmentStore(library: LibraryController(), storageURL: makeStorage())
    store.setRating("movie|a|2020", stars: 3)
    store.setNote("movie|a|2020", text: "Keep for the weekend")

    let data = try store.exportArchive(sources: [], appPreferences: nil)
    let archive = try JSONDecoder().decode(EntertainmentArchive.self, from: data)
    XCTAssertEqual(archive.personal.ratings, ["movie|a|2020": 3])
    XCTAssertEqual(archive.personal.notes, ["movie|a|2020": "Keep for the weekend"])
  }

  func testCorrectingAMatchIntoATitleWithANoteKeepsBothNotes() {
    var data = EntertainmentPersonalData()
    data.notes = ["movie|old|2019": "From the old entry", "movie|new|2019": "Already here"]
    EntertainmentStore.moveTitleReferences(&data, from: "movie|old|2019", to: "movie|new|2019")
    XCTAssertNil(data.notes?["movie|old|2019"])
    XCTAssertEqual(
      data.notes?["movie|new|2019"], "Already here\n\nFrom the old entry")
  }
}

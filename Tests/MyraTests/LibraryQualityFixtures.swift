import Foundation

@testable import Myra

/// Builds versions and titles in memory for the library-quality and safety tests.
enum QualityFixture {
  static let root = URL(filePath: "/tmp/myra-quality-tests")

  static func version(
    _ name: String, category: String = "Movies", season: Int? = nil, episode: Int? = nil,
    discovered: Date = Date(timeIntervalSince1970: 1_700_000_000)
  ) -> EntertainmentVersion {
    let url = root.appending(path: name)
    let entry = DirectoryEntry(name: name, url: url, kind: .file, size: 1_000)
    let media = GlobalSearchResult(
      categoryID: UUID(), categoryName: category, categoryRoot: root, entry: entry,
      relativePath: name, artworkURL: nil)
    return EntertainmentVersion(
      media: media, firstDiscovered: discovered, season: season, episode: episode)
  }

  static func metadata(
    title: String = "Title", year: String? = nil, poster: Bool = true, genres: [String] = [],
    language: String = "en", runtime: Int? = nil, rating: Double = 7.5
  ) -> EntertainmentMetadata {
    EntertainmentMetadata(
      providerID: 1, title: title, overview: "", posterURL: poster ? URL(string: "https://img.example/p.jpg") : nil,
      rating: rating, voteCount: 100, releaseDate: year.map { "\($0)-01-01" }, genres: genres,
      language: language, runtimeMinutes: runtime)
  }

  static func title(
    _ name: String, kind: EntertainmentKind = .movie, versions: [EntertainmentVersion],
    metadata: EntertainmentMetadata? = nil, year: String? = nil
  ) -> EntertainmentTitle {
    EntertainmentTitle(
      id: "\(kind.rawValue)|\(name.lowercased())|\(year ?? "")", name: name, year: year,
      kind: kind, versions: versions, metadata: metadata)
  }
}

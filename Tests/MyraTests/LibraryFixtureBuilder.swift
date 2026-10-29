import CSQLite
import Foundation

@testable import Myra

/// Builds an isolated, deterministic library for benchmarks and engine tests. It writes only into
/// a temporary folder and never opens the personal profile.
struct LibraryFixtureSpec {
  var movies = 26_000
  var series = 4_000
  var episodesPerSeries = 5
  /// Every n-th movie also has a second file (another quality), so titles have several versions.
  var duplicateEveryNthMovie = 40
  /// Share of titles with saved TMDB-style metadata (0...1).
  var metadataShare = 0.7
  var seed: UInt64 = 7

  static func small(titles: Int = 600) -> LibraryFixtureSpec {
    var spec = LibraryFixtureSpec()
    spec.movies = titles * 4 / 5
    spec.series = titles - spec.movies
    spec.episodesPerSeries = 3
    return spec
  }
  var expectedTitles: Int { movies + series }
  var expectedVideos: Int {
    movies + movies / duplicateEveryNthMovie + series * episodesPerSeries
  }
}

struct LibraryFixture {
  let directory: URL
  let index: LibraryIndex
  let roots: [GlobalSearchRoot]
  let server: FixtureDirectoryServer
  let videos: [GlobalSearchResult]
  let spec: LibraryFixtureSpec
  var databaseURL: URL { index.url }
  func remove() { try? FileManager.default.removeItem(at: directory) }

  /// Publishes directory listings that match the fixture videos, for crawl-based tests.
  func publishListings() {
    for root in roots {
      server.publish(
        root: root.url, files: videos.filter { $0.categoryID == root.id }.map(\.relativePath))
    }
  }
}

enum LibraryFixtureBuilder {
  private static let words = [
    "Amber", "Harbor", "Silent", "Crimson", "Velvet", "Iron", "Paper", "Golden", "Hidden", "Last",
    "Northern", "Electric", "Broken", "Midnight", "Winter", "Distant", "Burning", "Quiet", "Hollow",
    "Scarlet", "Lunar", "Savage", "Gentle", "Rapid", "Ancient", "Neon", "Wild", "Frozen", "Bitter",
    "Lonely", "Rising", "Fallen", "Secret", "Stormy", "Shadow", "River", "Mountain", "Garden",
    "Empire", "Signal", "Letters", "Horizon", "Kingdom", "Machine", "Orchard", "Harvest", "Voyage",
  ]
  private static let genreFolders = [
    "Action", "Comedy", "Drama", "Horror", "Thriller", "Animation", "Documentary", "Romance",
  ]
  private static let languageFolders = ["Hollywood", "Bollywood", "Korean"]
  private static let qualities = ["2160p.WEB-DL.x265", "1080p.BluRay.x264", "720p.WEBRip.x264"]

  private struct Generator {
    var state: UInt64
    mutating func next() -> UInt64 {
      state = state &* 6364136223846793005 &+ 1442695040888963407
      return state >> 33
    }
    mutating func below(_ bound: Int) -> Int { Int(next() % UInt64(bound)) }
  }

  /// A unique, parseable title: four words that encode the number (digits would read as a year).
  private static func title(_ number: Int) -> String {
    let base = words.count
    let parts = [number % base, (number / base) % base, (number / (base * base)) % base, number / (base * base * base)]
    return parts.map { words[$0 % base] }.joined(separator: ".")
  }

  static func makeVideos(spec: LibraryFixtureSpec, roots: [GlobalSearchRoot]) -> [GlobalSearchResult]
  {
    var generator = Generator(state: spec.seed)
    var videos: [GlobalSearchResult] = []
    videos.reserveCapacity(spec.expectedVideos)
    func add(_ root: GlobalSearchRoot, _ folder: String, _ name: String) {
      let path = folder.isEmpty ? name : folder + "/" + name
      let url = root.url.appending(path: path)
      videos.append(
        GlobalSearchResult(
          categoryID: root.id, categoryName: root.name, categoryRoot: root.url,
          entry: DirectoryEntry(
            name: name, url: url, kind: .file, size: Int64(700_000_000 + generator.below(5_000_000_000)),
            modifiedAt: Date(timeIntervalSince1970: 1_600_000_000 + Double(videos.count))),
          relativePath: path, artworkURL: nil))
    }
    let movieRoot = roots[0]
    let seriesRoot = roots[1]
    for number in 0..<spec.movies {
      let year = 1980 + generator.below(45)
      let language = languageFolders[number % languageFolders.count]
      let genre = genreFolders[(number / 3) % genreFolders.count]
      let quality = qualities[generator.below(qualities.count)]
      let folder = "\(language)/\(genre)"
      add(movieRoot, folder, "\(title(number)).\(year).\(quality).mkv")
      if spec.duplicateEveryNthMovie > 0, number % spec.duplicateEveryNthMovie == 0 {
        add(movieRoot, folder, "\(title(number)).\(year).480p.HDTV.x264.mkv")
      }
    }
    for number in 0..<spec.series {
      let year = 1995 + generator.below(30)
      let name = title(spec.movies + number)
      for episode in 1...max(1, spec.episodesPerSeries) {
        add(
          seriesRoot, "TVShows/\(name)",
          "\(name).\(year).S01E\(String(format: "%02d", episode)).1080p.WEB-DL.x264.mkv")
      }
    }
    return videos
  }

  /// Creates the fixture index with videos written in 500-row chunks, as the indexer does.
  static func build(
    spec: LibraryFixtureSpec = LibraryFixtureSpec(), withMetadata: Bool = true
  ) async throws -> LibraryFixture {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "Myra-fixture-\(UUID().uuidString)", directoryHint: .isDirectory)
    let server = FixtureDirectoryServer()
    let roots = [
      GlobalSearchRoot(id: UUID(), name: "Movies", url: server.rootURL("Movies")),
      GlobalSearchRoot(id: UUID(), name: "Series", url: server.rootURL("Series")),
    ]
    let videos = makeVideos(spec: spec, roots: roots)
    let index = try LibraryIndex(url: directory.appending(path: "LibraryIndex.sqlite"))
    let generation = UUID()
    for start in stride(from: 0, to: videos.count, by: 500) {
      try await index.upsert(Array(videos[start..<min(start + 500, videos.count)]), generation: generation)
    }
    for root in roots { try await index.completeSource(root, generation: generation) }
    let fixture = LibraryFixture(
      directory: directory, index: index, roots: roots, server: server, videos: videos,
      spec: spec)
    if withMetadata { try writeMetadata(fixture) }
    return fixture
  }

  /// Saves TMDB-shaped metadata for a share of the titles directly into the index's cache table.
  private static func writeMetadata(_ fixture: LibraryFixture) throws {
    let versions = fixture.videos.map {
      EntertainmentVersion(media: $0, firstDiscovered: Date(timeIntervalSince1970: 1_700_000_000))
    }
    let titles = EntertainmentGrouping.group(versions)
    var generator = Generator(state: fixture.spec.seed &+ 99)
    var db: OpaquePointer?
    guard sqlite3_open(fixture.databaseURL.path, &db) == SQLITE_OK, let db else {
      throw LibraryIndexError.database("Fixture metadata could not open the database")
    }
    defer { sqlite3_close(db) }
    sqlite3_busy_timeout(db, 5000)
    _ = sqlite3_exec(db, "BEGIN", nil, nil, nil)
    var statement: OpaquePointer?
    sqlite3_prepare_v2(
      db, "INSERT OR REPLACE INTO metadata VALUES(?,?,?)", -1, &statement, nil)
    defer { sqlite3_finalize(statement) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    let genres = [
      "Action", "Comedy", "Drama", "Horror", "Thriller", "Animation", "Documentary", "Romance",
      "Science Fiction", "Family",
    ]
    let overview = String(repeating: "A long, detailed synopsis of the story and its characters. ", count: 8)
    let encoder = JSONEncoder()
    for title in titles {
      guard Double(generator.below(1000)) / 1000 < fixture.spec.metadataShare else { continue }
      var metadata = EntertainmentMetadata(
        providerID: generator.below(900_000) + 1, title: title.name, overview: overview,
        posterURL: URL(string: "https://image.example/t/p/w342/\(title.id.hashValue.magnitude).jpg"),
        rating: 4 + Double(generator.below(55)) / 10, voteCount: generator.below(20_000),
        releaseDate: "\(title.year ?? "2010")-0\(1 + generator.below(9))-1\(generator.below(9))",
        genres: [genres[generator.below(genres.count)], genres[generator.below(genres.count)]],
        language: ["en", "hi", "ko", "ja"][generator.below(4)])
      metadata.backdropURL = URL(string: "https://image.example/t/p/w780/\(title.id.hashValue.magnitude).jpg")
      if title.kind == .series {
        var dates: [String: String] = [:]
        for version in title.versions {
          dates["\(version.season ?? 1):\(version.episode ?? 1)"] = "2024-02-1\(generator.below(9))"
        }
        metadata.episodeReleaseDates = dates
      }
      guard let data = try? encoder.encode(metadata) else { continue }
      let payload = String(decoding: data, as: UTF8.self)
      sqlite3_reset(statement)
      sqlite3_clear_bindings(statement)
      sqlite3_bind_text(statement, 1, title.metadataCacheKey(), -1, transient)
      sqlite3_bind_text(statement, 2, payload, -1, transient)
      sqlite3_bind_double(statement, 3, Date.now.timeIntervalSince1970)
      sqlite3_step(statement)
    }
    _ = sqlite3_exec(db, "COMMIT", nil, nil, nil)
  }
}

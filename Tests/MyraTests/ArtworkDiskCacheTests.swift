import Foundation
import XCTest

@testable import Myra

/// In-memory storage for eviction tests. No files are written and no network is used.
private final class MemoryArtworkStorage: ArtworkCacheStorage, @unchecked Sendable {
  private struct Slot {
    var data: Data
    var date: Date
  }
  private let lock = NSLock()
  private var slots: [String: Slot] = [:]

  func read(_ key: String) throws -> Data? {
    lock.withLock { slots[key]?.data }
  }

  func write(_ data: Data, for key: String, at date: Date) throws {
    lock.withLock { slots[key] = Slot(data: data, date: date) }
  }

  func touch(_ key: String, at date: Date) throws {
    lock.withLock { slots[key]?.date = date }
  }

  func remove(_ key: String) throws {
    _ = lock.withLock { slots.removeValue(forKey: key) }
  }

  func entries() throws -> [ArtworkCacheEntry] {
    lock.withLock {
      slots.map { ArtworkCacheEntry(key: $0.key, byteCount: $0.value.data.count, lastAccess: $0.value.date) }
    }
  }

  var keys: Set<String> { lock.withLock { Set(slots.keys) } }
}

/// A clock the test moves forward explicitly.
private final class TestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var current = Date(timeIntervalSince1970: 1_000)

  var now: Date { lock.withLock { current } }

  func advance(by seconds: TimeInterval) {
    lock.withLock { current.addTimeInterval(seconds) }
  }
}

final class ArtworkDiskCacheTests: XCTestCase {
  private func url(_ name: String) -> URL {
    URL(string: "https://image.tmdb.org/t/p/w500/\(name).jpg")!
  }

  func testStoresAndReadsBytes() async throws {
    let cache = ArtworkDiskCache(storage: MemoryArtworkStorage())
    try await cache.store(Data([1, 2, 3]), for: url("a"))
    let read = await cache.data(for: url("a"))
    XCTAssertEqual(read, Data([1, 2, 3]))
    let missing = await cache.data(for: url("b"))
    XCTAssertNil(missing)
  }

  func testKeysAreStableHexAndDistinct() {
    let key = ArtworkDiskCache.key(for: url("a"))
    XCTAssertEqual(key, ArtworkDiskCache.key(for: url("a")))
    XCTAssertNotEqual(key, ArtworkDiskCache.key(for: url("b")))
    XCTAssertEqual(key.count, 64)
    XCTAssertTrue(key.allSatisfy { $0.isHexDigit })
  }

  func testEvictsLeastRecentlyUsedFirst() async throws {
    let clock = TestClock()
    let storage = MemoryArtworkStorage()
    let cache = ArtworkDiskCache(storage: storage, byteLimit: 10, clock: { clock.now })

    try await cache.store(Data(repeating: 1, count: 4), for: url("a"))
    clock.advance(by: 1)
    try await cache.store(Data(repeating: 2, count: 4), for: url("b"))
    clock.advance(by: 1)
    // 12 bytes is over the 10-byte limit, so the oldest entry (a) goes.
    try await cache.store(Data(repeating: 3, count: 4), for: url("c"))

    XCTAssertEqual(storage.keys, [ArtworkDiskCache.key(for: url("b")), ArtworkDiskCache.key(for: url("c"))])
  }

  func testReadingRefreshesRecency() async throws {
    let clock = TestClock()
    let storage = MemoryArtworkStorage()
    let cache = ArtworkDiskCache(storage: storage, byteLimit: 10, clock: { clock.now })

    try await cache.store(Data(repeating: 1, count: 4), for: url("a"))
    clock.advance(by: 1)
    try await cache.store(Data(repeating: 2, count: 4), for: url("b"))
    clock.advance(by: 1)
    _ = await cache.data(for: url("a"))  // a is now the most recently used
    clock.advance(by: 1)
    try await cache.store(Data(repeating: 3, count: 4), for: url("c"))

    XCTAssertEqual(storage.keys, [ArtworkDiskCache.key(for: url("a")), ArtworkDiskCache.key(for: url("c"))])
  }

  func testNothingEvictedWithinLimit() async throws {
    let storage = MemoryArtworkStorage()
    let cache = ArtworkDiskCache(storage: storage, byteLimit: 100)
    for name in ["a", "b", "c"] {
      try await cache.store(Data(repeating: 0, count: 10), for: url(name))
    }
    XCTAssertEqual(storage.keys.count, 3)
  }

  func testDefaultLimitIsNamedAndPositive() {
    XCTAssertEqual(ArtworkDiskCache.defaultByteLimit, 256 * 1024 * 1024)
    XCTAssertEqual(ArtworkDiskCache.folderName, "Artwork")
    XCTAssertTrue(
      ArtworkDiskCache.defaultDirectory().path.hasSuffix(
        "\(AppPersistence.applicationSupportFolder)/Artwork"))
  }

  func testFileStorageRoundTripAndEviction() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "Myra-artwork-test-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let clock = TestClock()
    let cache = ArtworkDiskCache(
      storage: FileArtworkCacheStorage(directory: directory), byteLimit: 8, clock: { clock.now })

    try await cache.store(Data(repeating: 1, count: 4), for: url("a"))
    clock.advance(by: 1)
    try await cache.store(Data(repeating: 2, count: 4), for: url("b"))
    clock.advance(by: 1)
    try await cache.store(Data(repeating: 3, count: 4), for: url("c"))

    let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    XCTAssertEqual(remaining, [ArtworkDiskCache.key(for: url("b")), ArtworkDiskCache.key(for: url("c"))].sorted())
    let newest = await cache.data(for: url("c"))
    XCTAssertEqual(newest, Data(repeating: 3, count: 4))
  }

  func testLoaderRefusesDisallowedRemoteWithoutNetwork() async {
    let loader = ArtworkLoader(
      cache: ArtworkDiskCache(storage: MemoryArtworkStorage()))
    do {
      _ = try await loader.data(for: URL(string: "http://image.tmdb.org/a.jpg")!)
      XCTFail("Expected disallowedURL")
    } catch {
      XCTAssertEqual(error as? ArtworkLoader.LoadError, .disallowedURL)
    }
  }

  func testLoaderReadsLocalFilesWithoutCache() async throws {
    let file = FileManager.default.temporaryDirectory.appending(
      path: "Myra-poster-\(UUID().uuidString).jpg")
    defer { try? FileManager.default.removeItem(at: file) }
    try Data([9, 8, 7]).write(to: file)
    let loader = ArtworkLoader(cache: ArtworkDiskCache(storage: MemoryArtworkStorage()))
    let data = try await loader.data(for: file)
    XCTAssertEqual(data, Data([9, 8, 7]))
  }
}

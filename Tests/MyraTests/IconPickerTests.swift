import AppKit
import XCTest

@testable import Myra

@MainActor
final class IconPickerTests: XCTestCase {
  private static let runtimeNames: Set<String> = Set(
    ["aperture", "spotlight", "ribbon-m"].flatMap { family in
      ["default", "dark", "clear", "tinted"].map { "\(family)-\($0)" }
    })

  /// The repository root, derived from this file's location in Tests/MyraTests.
  private var repositoryRoot: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private func isolatedDefaults() -> UserDefaults {
    let suite = "IconPickerTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
  }

  func testChoicesMapToRenditionResourceNames() {
    XCTAssertEqual(
      MyraAppearance.resourceName(family: .aperture, appearance: .automatic, dark: false),
      "aperture-default")
    XCTAssertEqual(
      MyraAppearance.resourceName(family: .aperture, appearance: .automatic, dark: true),
      "aperture-dark")
    XCTAssertEqual(
      MyraAppearance.resourceName(family: .spotlight, appearance: .light, dark: true),
      "spotlight-default")
    XCTAssertEqual(
      MyraAppearance.resourceName(family: .spotlight, appearance: .dark, dark: false),
      "spotlight-dark")
    XCTAssertEqual(
      MyraAppearance.resourceName(family: .ribbonM, appearance: .clear, dark: false),
      "ribbon-m-clear")
    XCTAssertEqual(
      MyraAppearance.resourceName(family: .ribbonM, appearance: .tinted, dark: true),
      "ribbon-m-tinted")
  }

  func testChoiceRawValuesAndTitles() {
    XCTAssertEqual(MyraIconFamily.allCases.map(\.title), ["Aperture", "Spotlight", "Ribbon M"])
    XCTAssertEqual(MyraIconFamily.allCases.map(\.rawValue), ["aperture", "spotlight", "ribbon-m"])
    XCTAssertEqual(MyraIconFamily(storedValue: "ribbon-m"), .ribbonM)
    XCTAssertEqual(MyraIconAppearance(storedValue: "glass"), .clear)
    XCTAssertEqual(MyraIconAppearance(storedValue: "tinted"), .tinted)
    XCTAssertEqual(MyraIconAppearance(storedValue: nil), .automatic)
  }

  func testRetiredFamilyValuesMigrateToAperture() {
    for retired in ["cinema", "orbit", "minimal", "signature"] {
      let defaults = isolatedDefaults()
      defaults.set(retired, forKey: MyraAppearance.retiredFamilyKey)

      let migrated = MyraAppearance.migrateStoredFamily(defaults: defaults)

      XCTAssertEqual(migrated, .aperture, "\(retired) should migrate to Aperture")
      XCTAssertEqual(defaults.string(forKey: MyraAppearance.familyKey), "aperture")
      XCTAssertNil(defaults.object(forKey: MyraAppearance.retiredFamilyKey))
    }
  }

  func testMigrationKeepsAnExistingNewChoice() {
    let defaults = isolatedDefaults()
    defaults.set("orbit", forKey: MyraAppearance.retiredFamilyKey)
    defaults.set("spotlight", forKey: MyraAppearance.familyKey)

    XCTAssertEqual(MyraAppearance.migrateStoredFamily(defaults: defaults), .spotlight)
    XCTAssertNil(defaults.object(forKey: MyraAppearance.retiredFamilyKey))
  }

  func testMissingOrUnknownStoredChoiceFallsBackToAperture() {
    let defaults = isolatedDefaults()
    XCTAssertEqual(MyraAppearance.migrateStoredFamily(defaults: defaults), .aperture)
    defaults.set("unknown-family", forKey: MyraAppearance.familyKey)
    XCTAssertEqual(MyraAppearance.migrateStoredFamily(defaults: defaults), .aperture)
  }

  func testEveryChoiceAndRenditionIsBundled() {
    for family in MyraIconFamily.allCases {
      for appearance in MyraIconAppearance.allCases {
        for dark in [false, true] {
          let name = MyraAppearance.resourceName(family: family, appearance: appearance, dark: dark)
          XCTAssertNotNil(MyraAppearance.resourceURL(named: name), "Missing \(name).png")
          let image = MyraAppearance.image(family: family, appearance: appearance, dark: dark)
          XCTAssertEqual(image?.size.width, 512, name)
          XCTAssertEqual(image?.size.height, 512, name)
        }
      }
    }
  }

  func testRuntimeDirectoryContainsOnlyThePickerRenditions() throws {
    let directory = repositoryRoot.appendingPathComponent("Sources/Myra/Resources/MyraIcons")
    let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    let pngNames = Set(files.filter { $0.hasSuffix(".png") }.map { String($0.dropLast(4)) })
    XCTAssertEqual(pngNames, Self.runtimeNames)
    XCTAssertFalse(
      files.contains { name in
        ["cinema", "orbit", "minimal", "signature"].contains { name.hasPrefix($0) }
      }, "Retired icon family files must not remain")
  }

  func testIconComposerDocumentsMatchTheChoices() {
    let documents = repositoryRoot.appendingPathComponent("Resources/MyraIcons")
    for document in ["aperture.icon", "spotlight.icon", "ribbon-m.icon"] {
      let json = documents.appendingPathComponent(document).appendingPathComponent("icon.json")
      XCTAssertTrue(FileManager.default.fileExists(atPath: json.path), document)
    }
    XCTAssertEqual(
      (try? FileManager.default.contentsOfDirectory(atPath: documents.path))?.sorted(),
      ["aperture.icon", "ribbon-m.icon", "spotlight.icon"])
  }

  func testAppIconSetHasEveryMacSizeFromApertureRender() throws {
    let set = repositoryRoot.appendingPathComponent("Resources/Assets.xcassets/AppIcon.appiconset")
    let contents = try Data(contentsOf: set.appendingPathComponent("Contents.json"))
    let manifest = try XCTUnwrap(
      JSONSerialization.jsonObject(with: contents) as? [String: Any])
    let images = try XCTUnwrap(manifest["images"] as? [[String: String]])
    XCTAssertEqual(images.count, 10)

    for entry in images {
      let filename = try XCTUnwrap(entry["filename"])
      let points = try XCTUnwrap(entry["size"]).split(separator: "x").first.flatMap { Int($0) }
      let scale = Int(try XCTUnwrap(entry["scale"]).dropLast()) ?? 1
      let expectedPixels = try XCTUnwrap(points) * scale
      let url = set.appendingPathComponent(filename)
      let representation = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: url)))
      XCTAssertEqual(representation.pixelsWide, expectedPixels, "\(filename) width")
      XCTAssertEqual(representation.pixelsHigh, expectedPixels, "\(filename) height")
    }
  }
}

import AppKit
import XCTest

@testable import Myra

@MainActor
final class AccentPaletteTests: XCTestCase {
  private var suiteName: String!
  private var defaults: UserDefaults!

  override func setUp() {
    super.setUp()
    suiteName = "AccentPaletteTests.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
    defaults = nil
    super.tearDown()
  }

  func testChoicesFollowMacOSOrderWithMulticolorFirst() {
    XCTAssertEqual(
      MyraAccent.allCases.map(\.rawValue),
      ["multicolor", "blue", "purple", "pink", "red", "orange", "yellow", "green", "graphite"])
    XCTAssertEqual(MyraAccent.allCases.map(\.title).first, "Multicolor")
    XCTAssertEqual(MyraAccent.allCases.map(\.title).last, "Graphite")
  }

  func testDefaultAccentIsMulticolorWhenNothingIsStored() {
    XCTAssertEqual(MyraAccent.default, .multicolor)
    XCTAssertEqual(MyraAccentStore.load(defaults: defaults), .multicolor)
  }

  func testStoredChoiceRoundTripsThroughUserDefaultsKey() {
    MyraAccentStore.save(.pink, defaults: defaults)
    XCTAssertEqual(defaults.string(forKey: "myraAccent"), "pink")
    XCTAssertEqual(MyraAccentStore.load(defaults: defaults), .pink)
  }

  func testUnknownStoredValueFallsBackToDefault() {
    defaults.set("ultraviolet", forKey: "myraAccent")
    XCTAssertEqual(MyraAccentStore.load(defaults: defaults), .multicolor)
  }

  func testEveryChoiceHasDistinctLightAndDarkValues() {
    for accent in MyraAccent.allCases {
      let values = accent.hexValues
      XCTAssertNotEqual(values.light, values.dark, "\(accent.rawValue) has no dark variant")
    }
  }

  func testMacOSAccentValuesMatchSystemPalette() {
    XCTAssertEqual(MyraAccent.blue.hexValues.light, 0x007AFF)
    XCTAssertEqual(MyraAccent.blue.hexValues.dark, 0x0A84FF)
    XCTAssertEqual(MyraAccent.red.hexValues.light, 0xFF3B30)
    XCTAssertEqual(MyraAccent.green.hexValues.dark, 0x32D74B)
    XCTAssertEqual(MyraAccent.multicolor.hexValues.light, 0x5B4BDB)
  }

  func testDynamicColourResolvesPerAppearance() throws {
    let accent = MyraAccent.orange
    let light = try resolvedRGB(accent.nsColor, appearanceName: .aqua)
    let dark = try resolvedRGB(accent.nsColor, appearanceName: .darkAqua)
    XCTAssertEqual(light, expectedRGB(accent.hexValues.light), accuracy: 0.002)
    XCTAssertEqual(dark, expectedRGB(accent.hexValues.dark), accuracy: 0.002)
    XCTAssertNotEqual(light, dark)
  }

  func testHexConversionUsesSRGBChannels() throws {
    let color = try XCTUnwrap(MyraAccent.srgb(0x112233).usingColorSpace(.sRGB))
    XCTAssertEqual(color.redComponent, 0x11 / 255, accuracy: 0.002)
    XCTAssertEqual(color.greenComponent, 0x22 / 255, accuracy: 0.002)
    XCTAssertEqual(color.blueComponent, 0x33 / 255, accuracy: 0.002)
  }

  private func resolvedRGB(_ color: NSColor, appearanceName: NSAppearance.Name) throws
    -> [CGFloat]
  {
    let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
    var result: [CGFloat] = []
    appearance.performAsCurrentDrawingAppearance {
      let rgb = color.usingColorSpace(.sRGB)
      result = [rgb?.redComponent ?? -1, rgb?.greenComponent ?? -1, rgb?.blueComponent ?? -1]
    }
    return result
  }

  private func expectedRGB(_ hex: UInt32) -> [CGFloat] {
    [CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255]
  }
}

private func XCTAssertEqual(
  _ lhs: [CGFloat], _ rhs: [CGFloat], accuracy: CGFloat, file: StaticString = #filePath,
  line: UInt = #line
) {
  XCTAssertEqual(lhs.count, rhs.count, file: file, line: line)
  for (left, right) in zip(lhs, rhs) {
    XCTAssertEqual(left, right, accuracy: accuracy, file: file, line: line)
  }
}

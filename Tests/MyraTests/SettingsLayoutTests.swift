import Foundation
import XCTest

@testable import Myra

/// Settings layout values taken from the approved redesign preview (`.settings`, `.tabs`, `.group`, `.toggle`, `.select`).
@MainActor
final class SettingsLayoutTests: XCTestCase {
  func testTabIconsMatchThePreview() {
    XCTAssertEqual(
      MyraSettingsTab.allCases.map(\.symbol),
      [
        "gearshape", "books.vertical", "arrow.down.circle", "play.rectangle", "sparkles", "network",
      ])
  }

  func testTabBarMeasurementsMatchThePreview() {
    XCTAssertEqual(SettingsMetrics.windowWidth, 680)
    XCTAssertEqual(SettingsMetrics.tabMinWidth, 70)
    XCTAssertEqual(SettingsMetrics.tabRadius, 8)
    XCTAssertEqual(SettingsMetrics.tabIconSize, 20)
    XCTAssertEqual(SettingsMetrics.tabLabelSize, 11)
    XCTAssertEqual(SettingsMetrics.tabBarPadding, 10)
  }

  func testRowAndGroupMeasurementsMatchThePreview() {
    XCTAssertEqual(SettingsMetrics.groupRadius, 10)
    XCTAssertEqual(SettingsMetrics.rowHorizontalPadding, 12)
    XCTAssertEqual(SettingsMetrics.rowVerticalPadding, 9)
    XCTAssertEqual(SettingsMetrics.rowSpacing, 16)
    XCTAssertEqual(SettingsMetrics.selectRadius, 6)
  }

  func testSwitchMeasurementsMatchThePreview() {
    XCTAssertEqual(SettingsMetrics.switchWidth, 34)
    XCTAssertEqual(SettingsMetrics.switchHeight, 20)
    XCTAssertEqual(SettingsMetrics.knobDiameter, 16)
  }

  func testFooterSaysSettingsSaveAutomatically() {
    XCTAssertEqual(SettingsMetrics.footerText, "Settings save automatically")
  }

  func testThemeChoicesAreOfferedInOrder() {
    let options = AppThemeMode.allCases.map { SettingsOption(value: $0, title: $0.displayName) }
    XCTAssertEqual(options.count, AppThemeMode.allCases.count)
    XCTAssertEqual(options.map(\.value), AppThemeMode.allCases)
    XCTAssertTrue(options.allSatisfy { !$0.title.isEmpty })
  }

  func testSpeedLimitValidationStillFlagsInvalidDrafts() {
    XCTAssertNil(MyraSettingsValidation.speedLimitMessage("500K"))
    XCTAssertNotNil(MyraSettingsValidation.speedLimitMessage("10G"))
  }
}

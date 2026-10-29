import AppKit
import CoreGraphics
import XCTest

@testable import Myra

/// Every bitmap icon follows the macOS icon grid: the squircle body is about 80% of the canvas
/// (824 of 1024) and the rest is transparent margin with a soft shadow.
final class AppIconGeometryTests: XCTestCase {
  /// Alpha at or above this counts as the opaque body. The shadow peaks near 30% (77 of 255).
  private static let opaqueAlpha: UInt8 = 200

  private static var repositoryRoot: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  /// The bounding box of the opaque pixels, as fractions of the canvas width and height.
  private func opaqueBodyFraction(of url: URL) throws -> (width: Double, height: Double) {
    let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil), url.lastPathComponent)
    let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    let width = image.width
    let height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
      guard
        let context = CGContext(
          data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return false }
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    XCTAssertTrue(drawn)
    var minX = width
    var maxX = -1
    var minY = height
    var maxY = -1
    for y in 0..<height {
      for x in 0..<width where pixels[(y * width + x) * 4 + 3] >= Self.opaqueAlpha {
        minX = min(minX, x)
        maxX = max(maxX, x)
        minY = min(minY, y)
        maxY = max(maxY, y)
      }
    }
    XCTAssertGreaterThanOrEqual(maxX, minX, "\(url.lastPathComponent) has no opaque body")
    return (Double(maxX - minX + 1) / Double(width), Double(maxY - minY + 1) / Double(height))
  }

  private func assertBody(_ url: URL, file: StaticString = #filePath, line: UInt = #line) throws {
    let fraction = try opaqueBodyFraction(of: url)
    // 824/1024 is 0.805. Small sizes lose a pixel or two to rounding.
    for value in [fraction.width, fraction.height] {
      XCTAssertEqual(
        value, 824.0 / 1024.0, accuracy: 0.03, "\(url.lastPathComponent) body is \(value)",
        file: file, line: line)
    }
  }

  func testRuntimeRenditionsUseTheEightyPercentBody() throws {
    for family in MyraIconFamily.allCases {
      for appearance in ["default", "dark", "clear", "tinted"] {
        let name = "\(family.rawValue)-\(appearance)"
        let url = try XCTUnwrap(MyraAppearance.resourceURL(named: name), name)
        try assertBody(url)
      }
    }
  }

  func testBundleIconSetUsesTheEightyPercentBody() throws {
    let directory = Self.repositoryRoot.appending(
      path: "Resources/Assets.xcassets/AppIcon.appiconset")
    let files = try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil
    ).filter { $0.pathExtension == "png" }
    XCTAssertEqual(files.count, 10)
    for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
      // The 16 pt rendition has too few pixels for a stable fraction.
      if file.lastPathComponent == "icon_16x16.png" { continue }
      try assertBody(file)
    }
  }

  func testBodyLeavesRoomForTheShadow() throws {
    let url = try XCTUnwrap(MyraAppearance.resourceURL(named: "aperture-default"))
    let fraction = try opaqueBodyFraction(of: url)
    XCTAssertLessThan(fraction.width, 0.85)
    XCTAssertLessThan(fraction.height, 0.85)
  }
}

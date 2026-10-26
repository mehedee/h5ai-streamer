import AppKit
import CoreGraphics
import SwiftUI

/// Shared layout constants for the macOS shell and new components.
enum MyraSpacing {
  static let xxs: CGFloat = 4
  static let xs: CGFloat = 8
  static let s: CGFloat = 12
  static let m: CGFloat = 16
  static let l: CGFloat = 24
}

enum MyraRadius {
  static let control: CGFloat = 8
  static let card: CGFloat = 14
  /// Panels and rows containers (`--radius` in the preview).
  static let panel: CGFloat = 12
}

/// Surface and text colours from the approved redesign preview, resolved per appearance.
/// The accent is deliberately absent: read it from `\.myraAccent` so the Settings choice applies.
/// Status colours are system colours and are used directly by `StatusPill`.
enum MyraColor {
  static let window = Color(nsColor: .windowBackgroundColor)
  static let content = Color(nsColor: .textBackgroundColor)
  static let sidebar = Color(nsColor: .controlBackgroundColor)
  static let glass = Color(nsColor: .controlBackgroundColor)
  static let glassStrong = Color(nsColor: .windowBackgroundColor)

  static let text = Color.primary
  static let text2 = Color.secondary
  static let text3 = Color(nsColor: .secondaryLabelColor)

  static let fill = dynamic((0x000000, 0.045), (0xFFFFFF, 0.06))
  static let fill2 = dynamic((0x000000, 0.08), (0xFFFFFF, 0.11))
  static let line = dynamic((0x000000, 0.08), (0xFFFFFF, 0.08))
  static let lineStrong = dynamic((0x000000, 0.14), (0xFFFFFF, 0.16))

  /// A dynamic colour from a 0xRRGGBB value and an alpha, for light and dark appearance.
  static func dynamic(_ light: (UInt32, CGFloat), _ dark: (UInt32, CGFloat)) -> Color {
    Color(
      nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let value = isDark ? dark : light
        return MyraAccent.srgb(value.0).withAlphaComponent(value.1)
      })
  }
}

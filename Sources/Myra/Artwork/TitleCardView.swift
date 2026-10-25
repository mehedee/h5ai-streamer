import SwiftUI

/// Colours for generated title cards. The same title always gets the same colour.
enum TitleCardPalette {
  /// FNV-1a over the trimmed, lowercased title. `Hasher` is not used because it is seeded per process.
  static func hash(for title: String) -> UInt64 {
    let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    var value: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in normalized.utf8 {
      value ^= UInt64(byte)
      value = value &* 0x0000_0100_0000_01b3
    }
    return value
  }

  /// Hue in 0..<1, derived from the title.
  static func hue(for title: String) -> Double {
    Double(hash(for: title) % 3600) / 3600
  }
}

/// A generated poster for a title that has no artwork.
struct TitleCardView: View {
  let title: String

  var body: some View {
    let hue = TitleCardPalette.hue(for: title)
    ZStack {
      LinearGradient(
        colors: [
          Color(hue: hue, saturation: 0.55, brightness: 0.42),
          Color(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.7, brightness: 0.22),
        ],
        startPoint: .topLeading, endPoint: .bottomTrailing)
      Text(title)
        .font(.headline)
        .foregroundStyle(.white)
        .multilineTextAlignment(.center)
        .lineLimit(4)
        .minimumScaleFactor(0.7)
        .padding(12)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(title)
  }
}

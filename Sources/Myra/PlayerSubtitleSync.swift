import SwiftUI

/// Subtitle timing in whole milliseconds. Positive values show subtitles later.
enum PlayerSubtitleSync {
  static let stepMilliseconds = 100
  static let limitMilliseconds = 30_000

  static func clamped(_ milliseconds: Int) -> Int {
    min(limitMilliseconds, max(-limitMilliseconds, milliseconds))
  }

  static func adjusted(_ milliseconds: Int, by step: Int) -> Int {
    clamped(milliseconds + step)
  }

  /// VLCKit takes the subtitle delay in microseconds.
  static func microseconds(_ milliseconds: Int) -> Int { milliseconds * 1_000 }

  static func label(_ milliseconds: Int) -> String {
    let sign = milliseconds > 0 ? "+" : (milliseconds < 0 ? "−" : "")
    return "\(sign)\(abs(milliseconds)) ms"
  }

  /// One key per title. Episodes of a series and the versions of a movie share their offset.
  static func titleKey(filename: String) -> String {
    var identity = MediaIdentity.parse(filename: filename)
    identity.episode = nil
    identity.season = nil
    return identity.cacheKey
  }

  /// The remembered offset for a title. Zero is not stored, so the dictionary stays small.
  static func remembered(_ milliseconds: Int, key: String, in state: inout PlayerPersonalState) {
    var values = state.subtitleSync ?? [:]
    if milliseconds == 0 {
      values.removeValue(forKey: key)
    } else {
      values[key] = milliseconds
    }
    state.subtitleSync = values.isEmpty ? nil : values
  }

  static func stored(key: String, in state: PlayerPersonalState) -> Int {
    state.subtitleSync?[key] ?? 0
  }
}

/// Subtitle sync row shown in the player's subtitle popover: step buttons, value and reset.
struct PlayerSubtitleSyncControl: View {
  @ObservedObject var player: EmbeddedPlayerModel

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 10) {
        Text("Subtitle sync").font(.callout)
        Spacer(minLength: 12)
        Button {
          player.nudgeSubtitleSync(by: -PlayerSubtitleSync.stepMilliseconds)
        } label: {
          Text("−\(PlayerSubtitleSync.stepMilliseconds) ms")
        }
        .accessibilityLabel("Subtitles earlier by \(PlayerSubtitleSync.stepMilliseconds) milliseconds")
        Text(PlayerSubtitleSync.label(player.subtitleSyncMilliseconds))
          .monospacedDigit()
          .frame(minWidth: 84)
          .accessibilityLabel("Subtitle offset")
          .accessibilityValue(PlayerSubtitleSync.label(player.subtitleSyncMilliseconds))
        Button {
          player.nudgeSubtitleSync(by: PlayerSubtitleSync.stepMilliseconds)
        } label: {
          Text("+\(PlayerSubtitleSync.stepMilliseconds) ms")
        }
        .accessibilityLabel("Subtitles later by \(PlayerSubtitleSync.stepMilliseconds) milliseconds")
        Button("Reset") { player.setSubtitleSync(0) }
          .disabled(player.subtitleSyncMilliseconds == 0)
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
      Text("Remembered for this title.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .frame(width: 360, alignment: .leading)
  }
}

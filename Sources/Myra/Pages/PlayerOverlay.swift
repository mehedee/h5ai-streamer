import SwiftUI

/// Torrent facts the player chrome shows. Empty for local and indexed-file playback.
struct PlayerStreamStatus: Equatable {
  var isTorrentStream = false
  var streamingRow: TorrentTransferRow?
  /// Percent of the streamed video verified on disk, from the controller's transfer state.
  var streamPercent: Double = 0

  var bufferedSeconds: Double { streamingRow?.bufferedSeconds ?? 0 }
}

/// Re-renders the player chrome when the torrent controller publishes. The player stays
/// unaware of torrents: this reads controller state only and never changes playback.
struct TorrentStreamObserver<Content: View>: View {
  @ObservedObject var torrents: TorrentController
  @ObservedObject var player: EmbeddedPlayerModel
  let content: (PlayerStreamStatus) -> Content

  var body: some View {
    content(status)
  }

  private var status: PlayerStreamStatus {
    let row = torrents.streamingRow
    return PlayerStreamStatus(
      isTorrentStream: player.media.map { torrents.isTorrent($0) } ?? false,
      streamingRow: row,
      streamPercent: row.flatMap { torrents.transfers[$0.id]?.streamPercent } ?? 0)
  }
}

/// The centred card shown while a torrent stream is buffering: percentage and a status line.
struct PlayerBufferingCard: View {
  let status: PlayerStreamStatus

  var body: some View {
    VStack(spacing: 6) {
      ProgressView()
        .controlSize(.small)
        .tint(.white)
      Text(PlayerBufferingPresentation.percentText(status.streamPercent))
        .font(.system(size: 26, weight: .bold))
        .monospacedDigit()
      Text(statusLine)
        .font(.system(size: 12))
        .foregroundStyle(.white.opacity(0.7))
        .multilineTextAlignment(.center)
        .lineLimit(2)
    }
    .foregroundStyle(.white)
    .padding(20)
    .frame(width: 300, height: 150)
    .playerGlass(radius: 16)
    .accessibilityElement(children: .combine)
  }

  private var statusLine: String {
    guard let row = status.streamingRow else { return "Buffering" }
    return PlayerBufferingPresentation.statusLine(
      state: row.state, peers: row.peers, bytesPerSecond: row.downloadSpeed)
  }
}

/// Pure display rules for the buffering card, kept out of the view for direct tests.
enum PlayerBufferingPresentation {
  static func showsCard(isBuffering: Bool, isTorrentStream: Bool) -> Bool {
    isBuffering && isTorrentStream
  }

  static func percentText(_ percent: Double) -> String {
    let value = percent.isFinite ? min(100, max(0, percent)) : 0
    return "\(Int(value.rounded()))%"
  }

  static func speedText(bytesPerSecond: Int64) -> String {
    let bytes = Double(max(0, bytesPerSecond))
    if bytes >= 1_000_000 { return String(format: "%.1f MB/s", bytes / 1_000_000) }
    return String(format: "%.0f KB/s", bytes / 1_000)
  }

  static func statusLine(state: String, peers: Int, bytesPerSecond: Int64) -> String {
    let peerText = peers == 1 ? "1 peer" : "\(max(0, peers)) peers"
    return "\(state) · \(peerText) · \(speedText(bytesPerSecond: bytesPerSecond))"
  }
}

/// Scrub-bar fractions. The played part is the position; the buffered part runs ahead of it.
enum PlayerScrubLayout {
  static func bufferedFraction(
    position: Double, bufferedSeconds: Double, duration: Double
  ) -> Double {
    let played = position.isFinite ? min(1, max(0, position)) : 0
    guard duration > 0, duration.isFinite, bufferedSeconds > 0 else { return played }
    return min(1, max(played, played + bufferedSeconds / duration))
  }
}

/// A small white status capsule for torrent streams. It stays white on the always-dark chrome.
struct PlayerStatusPill: View {
  let text: String

  var body: some View {
    HStack(spacing: 5) {
      Circle()
        .fill(.white)
        .frame(width: 6, height: 6)
      Text(text)
    }
    .font(.system(size: 11, weight: .semibold))
    .foregroundStyle(.white)
    .padding(.horizontal, 8)
    .padding(.vertical, 2)
    .background(.white.opacity(0.15), in: Capsule())
  }
}

/// The 16pt translucent glass used by the bottom bar and the buffering card.
extension View {
  func playerGlass(radius: CGFloat) -> some View {
    modifier(PlayerGlassModifier(radius: radius))
  }
}

private struct PlayerGlassModifier: ViewModifier {
  let radius: CGFloat
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  func body(content: Content) -> some View {
    content
      .background {
        if reduceTransparency {
          RoundedRectangle(cornerRadius: radius).fill(Color(white: 0.12))
        } else {
          RoundedRectangle(cornerRadius: radius).fill(.regularMaterial)
            .overlay(RoundedRectangle(cornerRadius: radius).fill(.black.opacity(0.35)))
        }
      }
      .overlay(RoundedRectangle(cornerRadius: radius).stroke(.white.opacity(0.18), lineWidth: 1))
      .environment(\.colorScheme, .dark)
  }
}

/// A 36pt white glyph button with the preview's 15% white hover and press fill.
struct PlayerGlyphStyle: ButtonStyle {
  var size: CGFloat = 36

  func makeBody(configuration: Configuration) -> some View {
    PlayerGlyphBody(label: configuration.label, isPressed: configuration.isPressed, size: size)
  }
}

private struct PlayerGlyphBody<Label: View>: View {
  let label: Label
  let isPressed: Bool
  let size: CGFloat
  @State private var isHovering = false
  @Environment(\.isEnabled) private var isEnabled

  var body: some View {
    label
      .font(.system(size: 17, weight: .medium))
      .foregroundStyle(.white)
      .frame(width: size, height: size)
      .background(
        (isPressed || isHovering) ? Color.white.opacity(0.15) : Color.clear,
        in: RoundedRectangle(cornerRadius: 8)
      )
      .contentShape(RoundedRectangle(cornerRadius: 8))
      .opacity(isEnabled ? 1 : 0.4)
      .onHover { isHovering = $0 }
  }
}

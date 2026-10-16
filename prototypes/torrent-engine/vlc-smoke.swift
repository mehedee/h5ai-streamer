import Foundation
import VLCKit

@main
struct TorrentVLCSmoke {
  @MainActor static func main() async throws {
    guard CommandLine.arguments.count == 2,
      let url = URL(string: CommandLine.arguments[1]),
      url.host == "127.0.0.1"
    else { throw NSError(domain: "MyraTorrentFixture", code: 1) }
    let player = VLCMediaPlayer(options: ["--vout=dummy", "--aout=dummy", "--no-video-title-show"])
    player.media = VLCMedia(url: url)
    player.media?.addOptions(["network-caching": 500])
    player.play()
    defer { player.stop() }
    func wait(_ predicate: () -> Bool, message: String) async throws {
      let deadline = Date.now.addingTimeInterval(20)
      while !predicate() {
        guard Date.now < deadline, player.state != .error else {
          throw NSError(domain: "MyraTorrentFixture", code: 2,
            userInfo: [NSLocalizedDescriptionKey: message + " state=\(player.state.rawValue) playing=\(player.isPlaying) elapsed=\(player.time.intValue)"])
        }
        try await Task.sleep(for: .milliseconds(50))
      }
    }
    try await wait({ player.isPlaying && player.time.intValue >= 1500 },
      message: "VLC did not begin streamed playback")
    print("PASS VLC streamed playback elapsed \(player.time.intValue) ms")
    guard player.isSeekable else {
      throw NSError(domain: "MyraTorrentFixture", code: 3,
        userInfo: [NSLocalizedDescriptionKey: "VLC stream not seekable"])
    }
    player.position = 0.75
    try await wait({ player.isPlaying && player.time.intValue >= 30000 },
      message: "VLC seek did not reach 30 seconds")
    let start = player.time.intValue
    try await wait({ player.time.intValue >= start + 1000 },
      message: "VLC playback stalled after seek")
    print("PASS VLC seek and continued playback elapsed \(player.time.intValue) ms")
  }
}

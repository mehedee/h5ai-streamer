import AppKit
import SwiftUI
import VLCKit

struct LibraryPlayerContainer: View {
  @ObservedObject var coordinator: AppCoordinator
  @ObservedObject private var player: EmbeddedPlayerModel
  @ObservedObject private var inspector: MediaInspectorModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  init(coordinator: AppCoordinator) {
    self.coordinator = coordinator
    _player = ObservedObject(wrappedValue: coordinator.player)
    _inspector = ObservedObject(wrappedValue: coordinator.inspector)
  }

  var body: some View {
    ZStack {
      LibraryView(coordinator: coordinator)
        .opacity(player.media == nil ? 1 : 0)
        .allowsHitTesting(player.media == nil)
        .accessibilityHidden(player.media != nil)
    }
    .overlay(alignment: .trailing) {
      GeometryReader { geometry in
        if inspector.selected != nil && player.media == nil {
          MediaInspectorView(model: inspector, library: coordinator.library, play: coordinator.play)
            .frame(width: min(460, max(0, geometry.size.width)))
            .frame(maxHeight: .infinity)
            .background(.regularMaterial)
            .overlay(alignment: .leading) {
              Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1)
            }
            .shadow(color: .black.opacity(0.22), radius: 14, x: -5, y: 0)
            .transition(.move(edge: .trailing).combined(with: .opacity))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        }
      }
    }
    .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: inspector.selected?.id)
  }
}

struct EmbeddedPlayerView: View {
  var coordinator: AppCoordinator? = nil
  @ObservedObject var player: EmbeddedPlayerModel
  @Environment(\.colorScheme) private var colorScheme
  @State private var showRemaining = false
  @State private var showEpisodeBrowser = false
  @State private var showPreferences = false
  @State private var showMarkers = false
  @State private var showTrackOptions = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    streamObserver { stream in
      ZStack {
        Color.black
        videoLayer(stream)
        if PlayerBufferingPresentation.showsCard(
          isBuffering: player.isBuffering, isTorrentStream: stream.streamingRow != nil)
        {
          PlayerBufferingCard(status: stream)
        }
        chrome(stream)
      }
    }
    .environment(\.colorScheme, player.isFullscreen ? .dark : colorScheme)
    .ignoresSafeArea(edges: player.isFullscreen ? .all : [])
    .sheet(
      isPresented: Binding(
        get: { !player.versionChoices.isEmpty }, set: { if !$0 { player.cancelVersionChoice() } })
    ) {
      PlayerVersionChooser(player: player)
    }
    .sheet(isPresented: $showEpisodeBrowser) {
      PlayerEpisodeBrowser(player: player, coordinator: coordinator)
    }
    .sheet(isPresented: $showPreferences) { PlayerPreferencesView(player: player) }
    .sheet(isPresented: $showMarkers) { PlayerMarkersView(player: player) }
    .sheet(item: $player.subtitleSearch) { model in
      OnlineSubtitleSearchView(model: model)
    }
  }

  /// Observes torrent state only when a torrent controller exists; otherwise uses an empty status.
  @ViewBuilder
  private func streamObserver<Content: View>(
    @ViewBuilder _ content: @escaping (PlayerStreamStatus) -> Content
  ) -> some View {
    if let torrents = coordinator?.torrents {
      TorrentStreamObserver(torrents: torrents, player: player, content: content)
    } else {
      content(PlayerStreamStatus())
    }
  }

  /// The top bar, the bottom glass controls and the fullscreen auto-hide, over the video.
  private func chrome(_ stream: PlayerStreamStatus) -> some View {
    let visible = !player.isFullscreen || player.controlsVisible
    return VStack(spacing: 0) {
      topBar(stream)
      Spacer(minLength: 0)
      controlsBar(stream)
    }
    .environment(\.colorScheme, .dark)
    .opacity(visible ? 1 : 0)
    .allowsHitTesting(visible)
    .accessibilityHidden(!visible)
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: visible)
  }

  private var entryName: String { player.media?.entry.name ?? "" }

  private func topBar(_ stream: PlayerStreamStatus) -> some View {
    HStack(spacing: 10) {
      Button {
        player.close()
      } label: {
        Image(systemName: "chevron.left")
      }
      .buttonStyle(PlayerGlyphStyle())
      .accessibilityLabel("Back to Library")
      .playbackHelp("Back to Library", fullscreen: player.isFullscreen)
      Text(player.media.map { MediaIdentity.parse(filename: $0.entry.name).title } ?? "Player")
        .font(.system(size: 14, weight: .bold))
        .foregroundStyle(.white)
        .lineLimit(1)
        .help(entryName)
        .accessibilityLabel(entryName)
      if stream.isTorrentStream {
        PlayerStatusPill(text: "Torrent stream")
      }
      Spacer(minLength: 8)
      Text(player.status)
        .font(.system(size: 12))
        .foregroundStyle(.white.opacity(0.75))
        .lineLimit(1)
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 14)
    .background(
      LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom)
    )
    .onHover { player.hoverControls($0) }
  }

  private func videoLayer(_ stream: PlayerStreamStatus) -> some View {
    ZStack {
      Color.black
      VLCVideoSurface(model: player)
      if let error = player.errorMessage {
        VStack(spacing: 12) {
          Image(systemName: "exclamationmark.triangle").font(.largeTitle)
          Text(error).multilineTextAlignment(.center).frame(maxWidth: 440)
          if player.currentVersions.count > 1 {
            Button("Try another version") { player.requestPlayback(player.currentVersions) }
          }
        }
        .padding(24).foregroundStyle(.white).background(
          .black.opacity(0.75), in: RoundedRectangle(cornerRadius: 12))
      } else if player.isBuffering, stream.streamingRow == nil {
        ProgressView("Buffering…")
          .foregroundStyle(.white)
          .padding(.horizontal, 18)
          .padding(.vertical, 12)
          .playerGlass(radius: 12)
      }
      if let skip = player.activeSkip, player.isSeekable {
        VStack {
          Spacer()
          HStack {
            Spacer()
            Button(skip.0) { player.seek(to: skip.1.end / player.duration) }.padding(16)
          }
        }
        .padding(.bottom, 130)
      }
      if let resume = player.resumePosition, player.isSeekable,
        !player.isFullscreen || player.controlsVisible
      {
        VStack {
          HStack {
            Text("Resume from \(PlayerTime.string(resume))?")
            Button("Resume") { player.resumeSavedPosition() }
            Button("Start Over") { player.resumePosition = nil }
          }
          .padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
          .padding(.horizontal, 16)
          .padding(.top, 72)
          Spacer()
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  /// Timeline and grouped transport controls, with secondary actions kept in native menus.
  private func controlsBar(_ stream: PlayerStreamStatus) -> some View {
    VStack(spacing: 12) {
      HStack {
        Button {
          showRemaining.toggle()
        } label: {
          Text(
            PlayerTime.string(
              player.isScrubbing ? player.scrubPosition * player.duration : player.elapsed)
              + " / " + (showRemaining ? "−" : "")
              + PlayerTime.string(
                showRemaining ? max(0, player.duration - player.elapsed) : player.duration)
          )
          .monospacedDigit()
        }
        .buttonStyle(.plain)
        .help("Toggle duration and remaining time")
        .accessibilityLabel("Playback time")
        Spacer()
        if !player.isSeekable {
          Text("Seeking unavailable")
        } else if player.speed != 1 {
          Text(String(format: "%.2g×", player.speed))
        }
      }
      .font(.callout)
      .foregroundStyle(.white.opacity(0.85))

      VLCSeekBar(
        model: player,
        bufferedFraction: PlayerScrubLayout.bufferedFraction(
          position: player.position, bufferedSeconds: stream.bufferedSeconds,
          duration: player.duration)
      )
      .frame(height: 18)
      .disabled(!player.isSeekable)

      ViewThatFits(in: .horizontal) {
        HStack(spacing: 24) {
          transportControls
          Spacer(minLength: 24)
          utilityControls
        }
        VStack(spacing: 16) {
          transportControls.frame(maxWidth: .infinity)
          utilityControls.frame(maxWidth: .infinity)
        }
      }
    }
    .padding(24)
    .frame(maxWidth: 920)
    .playerGlass(radius: 16)
    .padding(.horizontal, 24)
    .padding(.bottom, 24)
    .frame(maxWidth: .infinity)
    .onHover { player.hoverControls($0 || showTrackOptions) }
    .onChange(of: showTrackOptions) { _, visible in player.hoverControls(visible) }
  }

  private var transportControls: some View {
    HStack(spacing: 12) {
      Button {
        player.navigate(offset: -1)
      } label: {
        Image(systemName: "backward.end.fill")
      }
      .disabled(!player.canGoPrevious)
      .accessibilityIdentifier("player.previous")
      .accessibilityLabel("Previous video").help("Previous video")

      Button {
        player.jump(seconds: -10)
      } label: {
        Image(systemName: "gobackward.10")
      }
      .disabled(!player.isSeekable)
      .accessibilityLabel("Back 10 seconds").help("Back 10 seconds")

      Button {
        player.togglePlayback()
      } label: {
        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
          .font(.system(size: 22, weight: .semibold))
      }
      .buttonStyle(PlayerGlyphStyle(size: 48))
      .accessibilityLabel(player.isPlaying ? "Pause" : "Play").help("Play or pause")

      Button {
        player.jump(seconds: 10)
      } label: {
        Image(systemName: "goforward.10")
      }
      .disabled(!player.isSeekable)
      .accessibilityLabel("Forward 10 seconds").help("Forward 10 seconds")

      Button {
        player.navigate(offset: 1)
      } label: {
        Image(systemName: "forward.end.fill")
      }
      .disabled(!player.canGoNext)
      .accessibilityIdentifier("player.next")
      .accessibilityLabel("Next video").help("Next video")
    }
    .buttonStyle(PlayerGlyphStyle())
    .fixedSize()
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Playback controls")
  }

  private var utilityControls: some View {
    HStack(spacing: 12) {
      Button {
        player.toggleMute()
      } label: {
        Image(systemName: player.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
      }
      .buttonStyle(PlayerGlyphStyle())
      .accessibilityLabel(player.isMuted ? "Unmute" : "Mute").help("Mute or unmute")
      Slider(value: Binding(get: { player.volume }, set: { player.setVolume($0) }), in: 0...100)
        .frame(width: 80).tint(.white)
        .accessibilityLabel("Volume")
        .accessibilityValue("\(Int(player.volume)) percent")

      Button {
        showTrackOptions.toggle()
      } label: {
        Image(systemName: "captions.bubble")
      }
      .buttonStyle(PlayerGlyphStyle())
      .accessibilityLabel("Audio, subtitles and speed").help("Audio, subtitles and speed")
      .popover(isPresented: $showTrackOptions) {
        VStack(alignment: .leading, spacing: 16) {
          Text("Playback Options").font(.headline)
          PlayerOptionsMenus(player: player)
            .fixedSize()
        }
        .padding(20)
        .environment(\.colorScheme, .dark)
      }

      Menu {
        Toggle("Repeat Video", isOn: $player.repeatEnabled)
        Button("Episodes / Files…") { showEpisodeBrowser = true }
          .disabled(player.sequenceLoading || player.sequence == nil)
        Button("Intro / Outro Markers…") { showMarkers = true }.disabled(!player.isSeekable)
        Button("Playback Preferences…") { showPreferences = true }
        Divider()
        Button("Stop") { player.stop() }
      } label: {
        Image(systemName: "ellipsis.circle")
          .font(.system(size: 17, weight: .medium)).frame(width: 36, height: 36)
      }
      .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
      .accessibilityLabel("More playback actions").help("More playback actions")

      Button {
        if player.isFullscreen { player.exitFullscreen() } else { player.toggleFullscreen() }
      } label: {
        Image(
          systemName: player.isFullscreen
            ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
      }
      .buttonStyle(PlayerGlyphStyle())
      .accessibilityLabel(player.isFullscreen ? "Exit fullscreen" : "Enter fullscreen")
      .playbackHelp(
        player.isFullscreen ? "Exit fullscreen" : "Enter fullscreen",
        fullscreen: player.isFullscreen
      )
      .accessibilityIdentifier("player.fullscreen")
    }
    .foregroundStyle(.white)
    .fixedSize()
  }
}

extension View {
  @ViewBuilder fileprivate func playbackHelp(_ text: String, fullscreen: Bool) -> some View {
    if fullscreen {
      accessibilityLabel(text)
    } else {
      help(text).accessibilityLabel(text)
    }
  }
}

private final class PlayerVideoView: VLCVideoView {
  var onKey: ((NSEvent) -> Bool)?
  var onFullscreen: (() -> Void)?
  var onWindow: ((NSWindow?) -> Void)?
  override var acceptsFirstResponder: Bool { true }
  override func keyDown(with event: NSEvent) {
    if onKey?(event) != true { super.keyDown(with: event) }
  }
  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    if event.clickCount == 2 { onFullscreen?() } else { super.mouseDown(with: event) }
  }
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    onWindow?(window)
    window?.makeFirstResponder(self)
  }
}

private struct VLCVideoSurface: NSViewRepresentable {
  @ObservedObject var model: EmbeddedPlayerModel
  func makeCoordinator() -> Coordinator { Coordinator(model: model) }
  func makeNSView(context: Context) -> PlayerVideoView {
    let view = PlayerVideoView(frame: .zero)
    view.onFullscreen = { [weak model] in model?.toggleFullscreen() }
    view.onWindow = { [weak model] in
      if let window = $0, model?.playbackWindow == nil { model?.setWindow(window) }
    }
    view.onKey = { [weak model] event in
      model?.handleKeyEvent(event) == true
    }
    model.attach(view: view)
    return view
  }
  func updateNSView(_ view: PlayerVideoView, context: Context) { model.attach(view: view) }
  static func dismantleNSView(_ view: PlayerVideoView, coordinator: Coordinator) {
    coordinator.model.detach(view: view)
  }
  final class Coordinator {
    let model: EmbeddedPlayerModel
    init(model: EmbeddedPlayerModel) { self.model = model }
  }
}

final class SeekSlider: NSSlider {
  var begin: (() -> Void)?
  var change: ((Double) -> Void)?
  var commit: ((Double) -> Void)?
  var duration: Double = 0
  var allowsTooltips = true {
    didSet { if !allowsTooltips { toolTip = nil } }
  }
  private var hoverArea: NSTrackingArea?

  override func mouseDown(with event: NSEvent) {
    guard isEnabled else { return }
    window?.makeFirstResponder(self)
    begin?()
    updateValue(event)
    while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
      updateValue(next)
      if next.type == .leftMouseUp { break }
    }
    commit?(doubleValue)
  }
  private func updateValue(_ event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    doubleValue = SeekBarGeometry.fraction(x: point.x, bounds: bounds)
    change?(doubleValue)
  }
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let hoverArea { removeTrackingArea(hoverArea) }
    let area = NSTrackingArea(
      rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
    addTrackingArea(area)
    hoverArea = area
  }
  override func mouseMoved(with event: NSEvent) {
    guard allowsTooltips else {
      toolTip = nil
      return
    }
    let point = convert(event.locationInWindow, from: nil)
    let fraction = SeekBarGeometry.fraction(x: point.x, bounds: bounds)
    toolTip =
      isEnabled
      ? "Seek to \(PlayerTime.string(fraction * duration))" : "This source is not seekable"
  }
  override func keyDown(with event: NSEvent) {
    guard isEnabled, event.keyCode == 123 || event.keyCode == 124 else {
      super.keyDown(with: event)
      return
    }
    begin?()
    doubleValue = min(
      1, max(0, doubleValue + (event.keyCode == 123 ? -1 : 1) * 10 / max(1, duration)))
    change?(doubleValue)
    commit?(doubleValue)
  }
}

private struct VLCSeekBar: NSViewRepresentable {
  @ObservedObject var model: EmbeddedPlayerModel
  /// Fraction of the bar buffered ahead of the playhead; drawn translucent behind the played part.
  var bufferedFraction: Double = 0
  func makeNSView(context: Context) -> SeekSlider {
    let slider = SeekSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    let cell = PlayerSeekSliderCell()
    cell.minValue = 0
    cell.maxValue = 1
    cell.sliderType = .linear
    slider.cell = cell
    slider.setAccessibilityLabel("Video playback position")
    slider.setAccessibilityIdentifier("player.seekbar")
    slider.isContinuous = true
    // The bar is drawn over video, so it always uses the dark appearance.
    slider.appearance = NSAppearance(named: .darkAqua)
    slider.begin = { [weak model] in model?.isScrubbing = true }
    slider.change = { [weak model] in model?.scrubPosition = $0 }
    slider.commit = { [weak model] value in
      model?.seek(to: value)
      model?.isScrubbing = false
    }
    return slider
  }
  func updateNSView(_ slider: SeekSlider, context: Context) {
    slider.isEnabled = model.isSeekable
    slider.duration = model.duration
    slider.allowsTooltips = !model.isFullscreen
    if let cell = slider.cell as? PlayerSeekSliderCell, cell.bufferedFraction != bufferedFraction {
      cell.bufferedFraction = bufferedFraction
      slider.needsDisplay = true
    }
    if !model.isScrubbing { slider.doubleValue = model.position }
  }
}

enum SeekBarGeometry {
  static func track(in bounds: NSRect) -> NSRect {
    NSRect(x: bounds.minX + 9, y: bounds.midY - 3, width: max(1, bounds.width - 18), height: 6)
  }
  static func fraction(x: CGFloat, bounds: NSRect) -> Double {
    let track = track(in: bounds)
    return min(1, max(0, Double((x - track.minX) / track.width)))
  }
}

final class PlayerSeekSliderCell: NSSliderCell {
  /// Buffered-ahead fraction of the bar, drawn as a translucent white part.
  var bufferedFraction: Double = 0

  override func barRect(flipped: Bool) -> NSRect {
    SeekBarGeometry.track(in: controlView?.bounds ?? NSRect(x: 0, y: 0, width: 100, height: 22))
  }
  override func knobRect(flipped: Bool) -> NSRect {
    let track = barRect(flipped: flipped)
    let fraction =
      maxValue > minValue ? min(1, max(0, (doubleValue - minValue) / (maxValue - minValue))) : 0
    return NSRect(
      x: track.minX + track.width * fraction - 8, y: track.midY - 8, width: 16, height: 16)
  }
  /// The preview's scrub bar: a 5pt track, a translucent buffered part and a solid played part.
  /// The player sits over video and is pinned to the dark appearance; light drawing keeps contrast.
  override func drawBar(inside rect: NSRect, flipped: Bool) {
    let bar = barRect(flipped: flipped).insetBy(dx: 0, dy: 0.5)
    let radius = bar.height / 2
    let dark = controlView?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    let trackColor =
      dark ? NSColor.white.withAlphaComponent(0.20) : NSColor.black.withAlphaComponent(0.24)
    let bufferedColor =
      dark ? NSColor.white.withAlphaComponent(0.35) : NSColor.black.withAlphaComponent(0.12)
    let playedColor = dark ? NSColor.white : NSColor.black.withAlphaComponent(0.70)
    trackColor.setFill()
    NSBezierPath(roundedRect: bar, xRadius: radius, yRadius: radius).fill()
    let fraction =
      maxValue > minValue ? min(1, max(0, (doubleValue - minValue) / (maxValue - minValue))) : 0
    let buffered = min(1, max(fraction, bufferedFraction))
    if buffered > 0 {
      let part = NSRect(x: bar.minX, y: bar.minY, width: bar.width * buffered, height: bar.height)
      bufferedColor.setFill()
      NSBezierPath(roundedRect: part, xRadius: radius, yRadius: radius).fill()
    }
    if fraction > 0 {
      let played = NSRect(
        x: bar.minX, y: bar.minY, width: bar.width * fraction, height: bar.height)
      playedColor.setFill()
      NSBezierPath(roundedRect: played, xRadius: radius, yRadius: radius).fill()
    }
  }
  /// The preview has no knob on the scrub bar; the played part shows the position.
  override func drawKnob(_ knobRect: NSRect) {}
}

import AppKit
import SwiftData
import SwiftUI

/// Sidebar destinations. Settings lives in the Settings window (⌘,), not the sidebar.
enum AppSection: String, CaseIterable, Identifiable {
  case home
  case sources
  case downloads
  case transfers

  var id: String { rawValue }

  var title: String {
    switch self {
    case .home: "Home"
    case .sources: "Sources"
    case .downloads: "Downloads"
    case .transfers: "Transfers"
    }
  }

  var icon: String {
    switch self {
    case .home: "house"
    case .sources: "server.rack"
    case .downloads: "arrow.down.circle"
    case .transfers: "arrow.left.arrow.right"
    }
  }

  /// The placeholder for the toolbar search field on this page.
  var searchPrompt: String {
    switch self {
    case .home: "Search or ask Myra"
    case .sources: "Search sources"
    case .downloads: "Search downloads"
    case .transfers: "Search torrents"
    }
  }
}

/// Counts shown beside sidebar items. The sidebar hides a badge whose count is zero.
enum ShellBadges {
  /// Downloads that are waiting or running. Paused and finished batches are not counted.
  static func downloads(_ batches: [DownloadBatch]) -> Int {
    batches.filter { $0.status == .active || $0.status == .queued }.count
  }

  /// Torrent transfers that are running: not finished and not paused.
  static func transfers(_ rows: [TorrentTransferRow]) -> Int {
    rows.filter { !$0.isComplete && !$0.isPaused }.count
  }
}

/// Text for the sidebar footer's last-scan line.
enum ShellFooterText {
  static func scanned(_ date: Date?, now: Date = .now) -> String {
    guard let date else { return "Not yet scanned" }
    return "Scanned " + RelativeDateTimeFormatter().localizedString(for: date, relativeTo: now)
  }
}

struct RootView: View {
  @ObservedObject var coordinator: AppCoordinator
  @ObservedObject private var player: EmbeddedPlayerModel
  @Environment(\.modelContext) private var modelContext
  @AppStorage(MyraAccent.defaultsKey) private var accentRaw = MyraAccent.default.rawValue
  @State private var section: AppSection = .home
  @State private var searchText = ""
  @FocusState private var searchFocused: Bool
  @ObservedObject private var torrents: TorrentController

  init(coordinator: AppCoordinator) {
    self.coordinator = coordinator
    _player = ObservedObject(wrappedValue: coordinator.player)
    _torrents = ObservedObject(wrappedValue: coordinator.torrents)
  }

  private var fullscreenPlayback: Bool { player.media != nil && player.isFullscreen }

  private var accent: MyraAccent { MyraAccent(rawValue: accentRaw) ?? .default }

  private var commandContext: MyraCommandContext {
    MyraCommandContext(coordinator: coordinator, player: player)
  }

  /// Overall progress for the toolbar ring and its popover. Built from controller state only.
  private var downloads: DownloadOverview {
    DownloadOverview.make(batches: coordinator.batches, torrents: torrents.transferRows)
  }

  var body: some View {
    ZStack {
      MyraColor.window
        .ignoresSafeArea()
      shell
        .opacity(player.media == nil ? 1 : 0)
        .allowsHitTesting(player.media == nil)
        .accessibilityHidden(player.media != nil)
      if player.media != nil {
        EmbeddedPlayerView(coordinator: coordinator, player: player)
      }
    }
    .ignoresSafeArea(edges: fullscreenPlayback ? .all : [])
    .sheet(item: $coordinator.playbackChoices) { choices in
      PlaybackChoicesView(choices: choices, play: coordinator.playChosenVersion)
    }
    // Torrent sheets live here so a link opened from any section still gets its sheet.
    .sheet(item: $torrents.selectingJob) { identity in
      TorrentAddSheet(controller: torrents, identity: identity)
    }
    .sheet(
      isPresented: Binding(
        get: { torrents.consentRequest != nil },
        set: { if !$0 { torrents.declineConsent() } })
    ) {
      TorrentConsentSheet(controller: torrents)
    }
    .overlay(alignment: .topTrailing) {
      if let message = coordinator.toastMessage, !fullscreenPlayback {
        ToastView(message: message)
          .padding(.top, 12)
          .padding(.trailing, 16)
          .transition(.move(edge: .top).combined(with: .opacity))
      }
    }
    .background(PlayerWindowAttachment(player: player))
    .font(.system(size: 13, weight: .regular, design: .default))
    .environment(\.defaultMinListRowHeight, 42)
    .environment(\.myraAccent, accent)
    .tint(accent.color)
    .preferredColorScheme(preferredColorScheme)
    .onChange(of: section, initial: true) { _, value in
      coordinator.currentSection = value
    }
    .onReceive(NotificationCenter.default.publisher(for: MyraCommand.notification)) { note in
      guard let command = MyraCommand(notification: note) else { return }
      handle(command)
    }
    .navigationTitle("Myra")
    // The shell draws its own 52pt header. The native toolbar is only used for the player.
    .toolbar(
      player.media == nil ? .hidden : (fullscreenPlayback ? .hidden : .automatic),
      for: .windowToolbar
    )
    .toolbarBackground(.regularMaterial, for: .windowToolbar)
    .toolbarBackground(.visible, for: .windowToolbar)
    .toolbar { playerToolbar }
  }

  /// Sidebar, header and the active page, laid out as the approved preview window.
  private var shell: some View {
    HStack(spacing: 0) {
      ShellSidebar(
        section: $section,
        coordinator: coordinator,
        library: coordinator.library,
        entertainment: coordinator.entertainment,
        torrents: torrents)
      VStack(spacing: 0) {
        header
        pageContent
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .task { coordinator.configure(modelContext: modelContext) }
    .alert(
      "Myra",
      isPresented: Binding(
        get: { coordinator.errorMessage != nil },
        set: { if !$0 { coordinator.errorMessage = nil } }
      )
    ) {
      Button("OK") { coordinator.errorMessage = nil }
    } message: {
      Text(coordinator.errorMessage ?? "Unknown error")
    }
  }

  @ViewBuilder private var pageContent: some View {
    switch section {
    case .home:
      HomeView(coordinator: coordinator, store: coordinator.entertainment)
    case .sources:
      LibraryPlayerContainer(coordinator: coordinator)
    case .downloads:
      OfflineLibraryView(coordinator: coordinator)
    case .transfers:
      TorrentsView(controller: coordinator.torrents)
    }
  }

  /// Title, the page's action pill, the search field and the download button, as in `.toolbar`.
  private var header: some View {
    HStack(spacing: 10) {
      Text(section.title)
        .font(.system(size: 15, weight: .bold))
        .lineLimit(1)
        .fixedSize()
      Spacer(minLength: 12)
      pageActions
      SearchField(text: $searchText, prompt: section.searchPrompt, isFocused: $searchFocused)
      if downloads.hasDownloads {
        DownloadsRingButton(overview: downloads) {
          MyraCommand.showDownloads.post()
        }
      }
    }
    .padding(.leading, 18)
    .padding(.trailing, 14)
    .frame(height: 52)
  }

  /// The action pill for the current page. Each button posts the same command as its menu item.
  @ViewBuilder private var pageActions: some View {
    switch section {
    case .home:
      ToolbarPill {
        commandButton("Pick", systemImage: "dice", .pickSomething)
        commandButton("Ask Myra", systemImage: "sparkles", .askMyra)
      }
    case .sources:
      ToolbarPill {
        commandButton("Refresh", systemImage: "arrow.clockwise", .refreshLibrary)
        commandButton("Add Source", systemImage: "plus", .addSource, primary: true)
      }
    case .downloads:
      ToolbarPill {
        commandButton("Pause All", systemImage: "pause.fill", .pauseAllDownloads)
        commandButton("Clear Completed", .clearCompletedDownloads)
      }
    case .transfers:
      ToolbarPill {
        commandButton("Open Link", systemImage: "link", .openTorrentLink, primary: true)
      }
    }
  }

  private func commandButton(
    _ title: String, systemImage: String? = nil, _ command: MyraCommand, primary: Bool = false
  ) -> some View {
    ToolbarButton(title: title, systemImage: systemImage, primary: primary) {
      command.post()
    }
    .disabled(!command.availability(in: commandContext).isEnabled)
  }

  @ToolbarContentBuilder private var playerToolbar: some ToolbarContent {
    if player.media != nil {
      ToolbarItem(placement: .navigation) {
        Button {
          player.close()
        } label: {
          Label("Back to Library", systemImage: "chevron.left")
        }
      }.continuousHeaderBackground()
      ToolbarItem(placement: .principal) {
        Text(player.media.map { MediaIdentity.parse(filename: $0.entry.name).title } ?? "Player")
          .font(.headline).lineLimit(1).help(player.media?.entry.name ?? "")
      }.continuousHeaderBackground()
      ToolbarItemGroup(placement: .primaryAction) {
        Text(player.status).font(.caption).foregroundStyle(.secondary)
        Button {
          player.toggleFullscreen()
        } label: {
          Image(systemName: "arrow.up.left.and.arrow.down.right")
        }
        .help("Enter fullscreen").accessibilityIdentifier("player.fullscreen")
      }.continuousHeaderBackground()
    }
  }

  /// Handles menu commands. Page-owned commands are disabled in the menu until a page handles them.
  private func handle(_ command: MyraCommand) {
    switch command {
    case .showHome: section = .home
    case .showSources: section = .sources
    case .showDownloads: section = .downloads
    case .showTransfers: section = .transfers
    case .openTorrentLink: section = .transfers
    case .importTorrentFile:
      section = .transfers
      coordinator.torrents.chooseTorrentFile()
    case .refreshLibrary:
      coordinator.refreshLibraryIndex()
    case .pauseAllDownloads:
      for batch in coordinator.batches where batch.status == .active {
        Task { await coordinator.pause(batch) }
      }
    case .resumeAllDownloads:
      for batch in coordinator.batches where batch.status == .paused {
        Task { await coordinator.resume(batch) }
      }
    case .clearCompletedDownloads:
      coordinator.clearCompleted()
    case .setAppearance(let mode):
      guard let settings = coordinator.settings else { return }
      coordinator.objectWillChange.send()
      settings.theme = mode
      try? modelContext.save()
    case .togglePlayback:
      guard player.media != nil else { return }
      player.togglePlayback()
    case .skipBack:
      guard player.media != nil else { return }
      player.jump(seconds: -10)
    case .skipForward:
      guard player.media != nil else { return }
      player.jump(seconds: 10)
    case .previousEpisode:
      guard player.media != nil else { return }
      player.navigate(offset: -1)
    case .nextEpisode:
      guard player.media != nil else { return }
      player.navigate(offset: 1)
    case .toggleFullScreen:
      NSApp.keyWindow?.toggleFullScreen(nil)
    case .find:
      searchFocused = true
    case .addSource, .pickSomething, .askMyra:
      // Handled by the visible page, which observes the notification. Menu gating keeps these
      // enabled only where such a page is showing.
      break
    }
  }

  private var themeMode: AppThemeMode { coordinator.settings?.theme ?? .system }

  private var preferredColorScheme: ColorScheme? {
    switch themeMode {
    case .system: nil
    case .light: .light
    case .dark: .dark
    }
  }
}

/// The sidebar: Home, the Library and Torrents groups with count badges, and the index footer.
private struct ShellSidebar: View {
  @Binding var section: AppSection
  @ObservedObject var coordinator: AppCoordinator
  @ObservedObject var library: LibraryController
  @ObservedObject var entertainment: EntertainmentStore
  @ObservedObject var torrents: TorrentController

  @Environment(\.myraAccent) private var accent

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      navItem(.home, badge: 0)
      groupLabel("Library")
      navItem(.sources, badge: coordinator.categories.count)
      navItem(.downloads, badge: ShellBadges.downloads(coordinator.batches))
      groupLabel("Torrents")
      navItem(.transfers, badge: ShellBadges.transfers(torrents.transferRows))
      Spacer(minLength: 12)
      footer
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 12)
    .frame(width: 212)
    .frame(maxHeight: .infinity)
    .background {
      ZStack {
        RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial)
        RoundedRectangle(cornerRadius: 12).fill(MyraColor.sidebar)
      }
    }
    .overlay(RoundedRectangle(cornerRadius: 12).stroke(MyraColor.line, lineWidth: 1))
    .padding(.leading, 8)
    .padding(.vertical, 8)
  }

  private func navItem(_ item: AppSection, badge: Int) -> some View {
    let selected = section == item
    return Button {
      section = item
    } label: {
      HStack(spacing: 9) {
        Image(systemName: item.icon)
          .font(.system(size: 15))
          .frame(width: 17, height: 17)
          .foregroundStyle(accent.color)
        Text(item.title)
        Spacer(minLength: 0)
        if badge > 0 {
          Text(badge.formatted())
            .font(.system(size: 11))
            .foregroundStyle(MyraColor.text2)
            .monospacedDigit()
        }
      }
      .font(.system(size: 13, weight: selected ? .semibold : .regular))
      .padding(.horizontal, 8)
      .padding(.vertical, 6)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(selected ? MyraColor.fill2 : .clear, in: RoundedRectangle(cornerRadius: 8))
      .contentShape(RoundedRectangle(cornerRadius: 8))
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }

  private func groupLabel(_ title: String) -> some View {
    Text(title)
      .font(.system(size: 11, weight: .semibold))
      .foregroundStyle(MyraColor.text3)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.leading, 8)
      .padding(.top, 12)
      .padding(.bottom, 4)
  }

  /// "Library up to date" with the title count and the time since the last index refresh.
  private var footer: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(library.isRefreshing ? "Indexing library" : "Library up to date")
        .font(.system(size: 12, weight: .bold))
      HStack(spacing: 8) {
        Text("\(entertainment.catalogue.count.formatted()) titles")
        Spacer(minLength: 4)
        Text(
          library.isRefreshing
            ? "\(library.progress.sourcesCompleted)/\(library.progress.sourcesTotal) sources"
            : ShellFooterText.scanned(library.lastRefresh)
        )
      }
      .font(.system(size: 12))
      .foregroundStyle(MyraColor.text2)
      .monospacedDigit()
      .lineLimit(1)
      if library.isRefreshing {
        Button("Cancel indexing") { library.cancel() }
          .controlSize(.small)
      } else {
        Menu("Manage index") {
          Button("Refresh due folders") { coordinator.refreshLibraryIndex() }
          Button("Choose folders…") { library.showIndexManagement = true }
          Button("Full rescan…") { library.showIndexManagement = true }
        }
        .font(.system(size: 11)).menuIndicator(.hidden).fixedSize()
      }
      if !library.isRefreshing, let error = library.errorMessage {
        Text(error).font(.system(size: 11)).foregroundStyle(.orange).lineLimit(2)
      }
      if !library.isRefreshing, library.errorMessage == nil, !library.failures.isEmpty {
        Menu("\(library.failures.count) unavailable") {
          ForEach(library.failures) { failure in
            Text("\(failure.categoryName): \(failure.summary)")
          }
        }
        .font(.system(size: 11)).foregroundStyle(.orange)
        .menuIndicator(.hidden).fixedSize()
      }
    }
    .padding(8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(MyraColor.fill, in: RoundedRectangle(cornerRadius: 10))
    .sheet(isPresented: $library.showIndexManagement) { IndexManagementView(library: library) }
    .alert(
      "Library Index Refresh",
      isPresented: Binding(
        get: { library.completionMessage != nil },
        set: { if !$0 { library.completionMessage = nil } })
    ) {
      Button("OK") { library.completionMessage = nil }
    } message: {
      Text(library.completionMessage ?? "")
    }
  }
}

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
    case .sources: "folder"
    case .downloads: "arrow.down.circle"
    case .transfers: "network"
    }
  }
}

struct RootView: View {
  @ObservedObject var coordinator: AppCoordinator
  @ObservedObject private var player: EmbeddedPlayerModel
  @Environment(\.modelContext) private var modelContext
  @AppStorage(MyraAccent.defaultsKey) private var accentRaw = MyraAccent.default.rawValue
  @State private var section: AppSection? = .home
  @ObservedObject private var torrents: TorrentController

  init(coordinator: AppCoordinator) {
    self.coordinator = coordinator
    _player = ObservedObject(wrappedValue: coordinator.player)
    _torrents = ObservedObject(wrappedValue: coordinator.torrents)
  }

  private var fullscreenPlayback: Bool { player.media != nil && player.isFullscreen }

  private var accent: MyraAccent { MyraAccent(rawValue: accentRaw) ?? .default }

  var body: some View {
    GeometryReader { _ in
      ZStack {
        CodexBackground()
        VStack(spacing: 0) {
          ZStack {
            NavigationSplitView {
              List(selection: $section) {
                row(.home)
                Section("Library") {
                  row(.sources)
                  row(.downloads)
                }
                Section("Torrents") {
                  row(.transfers)
                }
              }
              .scrollContentBackground(.hidden)
              .background(.thinMaterial)
              .navigationTitle("Myra")
              .navigationSplitViewColumnWidth(min: 170, ideal: 190)
            } detail: {
              Group {
                switch section ?? .home {
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
              .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
              .background(.ultraThinMaterial)
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(player.media == nil ? 1 : 0)
            .allowsHitTesting(player.media == nil)
            .accessibilityHidden(player.media != nil)
            if player.media != nil {
              EmbeddedPlayerView(coordinator: coordinator, player: player)
            }
          }
          if !fullscreenPlayback {
            LibraryIndexStatusView(
              library: coordinator.library, refresh: coordinator.refreshLibraryIndex)
          }
        }
      }
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
    }
    .ignoresSafeArea(edges: fullscreenPlayback ? .all : [])
    .background(PlayerWindowAttachment(player: player))
    .font(.system(size: 14, weight: .regular, design: .default))
    .environment(\.defaultMinListRowHeight, 42)
    .environment(\.myraAccent, accent)
    .tint(accent.color)
    .preferredColorScheme(preferredColorScheme)
    .onChange(of: section, initial: true) { _, value in
      coordinator.currentSection = value ?? .home
    }
    .onReceive(NotificationCenter.default.publisher(for: MyraCommand.notification)) { note in
      guard let command = MyraCommand(notification: note) else { return }
      handle(command)
    }
    .toolbar(fullscreenPlayback ? .hidden : .automatic, for: .windowToolbar)
    .toolbarBackground(.regularMaterial, for: .windowToolbar)
    .toolbarBackground(.visible, for: .windowToolbar)
    .toolbar {
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
      } else {
        ToolbarItem(placement: .principal) {
          if section == .home || section == nil {
            HomeToolbarTitle(store: coordinator.entertainment)
          } else {
            Text((section ?? .home).title).font(.headline)
          }
        }.continuousHeaderBackground()
      }
    }
  }

  private func row(_ item: AppSection) -> some View {
    Label(item.title, systemImage: item.icon).tag(item)
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
    case .addSource, .find:
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

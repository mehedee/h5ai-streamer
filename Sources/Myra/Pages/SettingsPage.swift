import AppKit
import SwiftUI

/// Toolbar tabs in the Settings window, in display order.
enum MyraSettingsTab: String, CaseIterable, Identifiable, Sendable {
  case general, library, downloads, playback, ai, torrents

  static let defaultTab: MyraSettingsTab = .general

  var id: String { rawValue }

  var title: String {
    switch self {
    case .general: "General"
    case .library: "Library"
    case .downloads: "Downloads"
    case .playback: "Playback"
    case .ai: "AI"
    case .torrents: "Torrents"
    }
  }

  var symbol: String {
    switch self {
    case .general: "gearshape"
    case .library: "books.vertical"
    case .downloads: "arrow.down.circle"
    case .playback: "play.rectangle"
    case .ai: "sparkles"
    case .torrents: "network"
    }
  }
}

/// Inline validation rules for values typed into Settings. Changes are applied as they are valid.
enum MyraSettingsValidation {
  /// aria2 speed limits: 0 for unlimited, or a whole number with an optional K or M suffix.
  static func isValidSpeedLimit(_ text: String) -> Bool {
    text.range(of: #"^(0|[1-9][0-9]*)[KkMm]?$"#, options: .regularExpression) != nil
  }

  static func speedLimitMessage(_ text: String) -> String? {
    isValidSpeedLimit(text) ? nil : "Use 0 for no limit, or a number with K or M, such as 500K or 10M."
  }

  /// A TMDB read access token is one unbroken string. Empty input is handled by the caller.
  static func tokenMessage(_ token: String) -> String? {
    let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return nil }
    return trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
      ? nil : "Paste the read access token without spaces or line breaks."
  }
}

/// The Settings window: toolbar tabs, with each change applied as it is made.
struct SettingsView: View {
  @ObservedObject var coordinator: AppCoordinator
  @ObservedObject private var store: EntertainmentStore
  @Bindable var settings: AppSettings
  @AppStorage(MyraAccent.defaultsKey) private var accentRaw = MyraAccent.default.rawValue
  @State private var selectedTab: MyraSettingsTab = .defaultTab
  @State private var speedDraft = ""
  @State private var token = ""
  @State private var tokenMessage: String?
  @State private var showingPlaybackPreferences = false

  init(coordinator: AppCoordinator, settings: AppSettings) {
    self.coordinator = coordinator
    self.settings = settings
    _store = ObservedObject(wrappedValue: coordinator.entertainment)
  }

  var body: some View {
    Group {
      switch selectedTab {
      case .general: generalTab
      case .library: libraryTab
      case .downloads: downloadsTab
      case .playback: playbackTab
      case .ai: Form { MyraAISettingsSection() }.formStyle(.grouped)
      case .torrents: Form { TorrentSettingsSection(controller: coordinator.torrents) }.formStyle(.grouped)
      }
    }
    // The tab bar sits in the window content, directly under the title bar, so it stays
    // reachable and testable in hosted views. It is styled as the toolbar tab bar.
    .safeAreaInset(edge: .top, spacing: 0) {
      VStack(spacing: 0) {
        HStack {
          Spacer()
          Picker("Settings section", selection: $selectedTab) {
            ForEach(MyraSettingsTab.allCases) { tab in
              Label(tab.title, systemImage: tab.symbol).tag(tab)
            }
          }
          .pickerStyle(.segmented)
          .labelsHidden()
          .frame(width: 580)
          .accessibilityLabel("Settings sections")
          Spacer()
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(.bar)
        Divider()
      }
    }
    .navigationTitle("Settings")
    .onAppear { speedDraft = settings.speedLimit }
    .onChange(of: settingsSnapshot) { _, _ in coordinator.saveSettings() }
    .sheet(isPresented: $showingPlaybackPreferences) {
      PlayerPreferencesView(player: coordinator.player)
    }
  }

  /// Every stored download and appearance value. A change to any of them is saved at once.
  private var settingsSnapshot: [String] {
    [
      settings.themeRaw, settings.downloadDirectory, settings.aria2PathOverride,
      String(settings.concurrentDownloads), String(settings.connectionsPerFile),
      String(settings.splitCount), String(settings.retryCount), settings.speedLimit,
    ]
  }

  private var accentBinding: Binding<MyraAccent> {
    Binding(
      get: { MyraAccent(rawValue: accentRaw) ?? .default },
      set: { accentRaw = $0.rawValue })
  }

  private var appVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "3.0.0"
  }

  private var generalTab: some View {
    Form {
      Section("Appearance") {
        Picker("Theme", selection: $settings.theme) {
          ForEach(AppThemeMode.allCases, id: \.self) { mode in
            Text(mode.displayName).tag(mode)
          }
        }
        LabeledContent("Mac accent") {
          MyraAccentPicker(selection: accentBinding)
        }
      }
      MyraAppearanceSettingsSection()
      UpdateSettingsSection(updater: coordinator.updater)
      Section("About Myra \(appVersion)") {
        TMDBAttributionView()
      }
    }
    .formStyle(.grouped)
  }

  private var libraryTab: some View {
    Form {
      MediaSettingsSection(library: coordinator.library, refresh: coordinator.refreshLibraryIndex)
      Section("Home Discovery") {
        SecureField("TMDB API Read Access Token", text: $token)
          .onSubmit { saveToken() }
        if let message = MyraSettingsValidation.tokenMessage(token) {
          Text(message).font(.caption).foregroundStyle(.orange)
        }
        HStack {
          Text("Press Return to save the token in Keychain.").font(.caption).foregroundStyle(.secondary)
          Spacer()
          Button("Remove Token", role: .destructive) { removeToken() }
            .help("Remove the TMDB token from Keychain")
        }
        if let tokenMessage { Text(tokenMessage).font(.caption) }
        Link("Get a TMDB token", destination: URL(string: "https://www.themoviedb.org/settings/api")!)
        Text(
          "Use the API Read Access Token, rather than the API key. Only title information and provider IDs are sent; source video URLs are excluded."
        )
        .font(.caption).foregroundStyle(.secondary)
        Toggle(
          "Notify me about new episodes of followed series",
          isOn: Binding(
            get: { store.personal.preferences.notifications },
            set: { store.setNotifications($0) }))
      }
    }
    .formStyle(.grouped)
  }

  private var downloadsTab: some View {
    Form {
      Section("Downloads") {
        LabeledContent("Directory") {
          HStack {
            Text(settings.downloadDirectory).lineLimit(1).truncationMode(.middle)
            Button("Choose…") { coordinator.chooseDownloadDirectory() }
          }
        }
        LabeledContent("aria2c") {
          TextField("Auto-detect", text: $settings.aria2PathOverride)
            .textFieldStyle(.roundedBorder).frame(minWidth: 280)
        }
        Text("Leave the aria2 path empty to search PATH and common Homebrew locations.")
          .font(.caption).foregroundStyle(.secondary)
      }
      Section("Advanced Performance") {
        Stepper(
          "Simultaneous files: \(settings.concurrentDownloads)",
          value: $settings.concurrentDownloads, in: 1...20)
        Stepper(
          "Connections per file: \(settings.connectionsPerFile)",
          value: $settings.connectionsPerFile, in: 1...16)
        Stepper("Split count: \(settings.splitCount)", value: $settings.splitCount, in: 1...16)
        Stepper("Retry count: \(settings.retryCount)", value: $settings.retryCount, in: 1...20)
        LabeledContent("Per-file speed limit") {
          VStack(alignment: .trailing, spacing: 4) {
            TextField("0", text: $speedDraft)
              .multilineTextAlignment(.trailing)
              .frame(width: 150)
              .onChange(of: speedDraft) { _, value in
                // Only valid values reach the settings; an invalid draft keeps the last good value.
                if MyraSettingsValidation.isValidSpeedLimit(value) {
                  settings.speedLimit = value
                }
              }
            if let message = MyraSettingsValidation.speedLimitMessage(speedDraft) {
              Text(message).font(.caption).foregroundStyle(.red)
            }
          }
        }
        Text("aria2 accepts values such as 0, 500K, or 10M.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }

  private var playbackTab: some View {
    Form {
      SubtitleSettingsSection()
      Section("Player") {
        Button("Playback Preferences…") { showingPlaybackPreferences = true }
      }
    }
    .formStyle(.grouped)
  }

  private func saveToken() {
    let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return }
    guard MyraSettingsValidation.tokenMessage(value) == nil else { return }
    do {
      try TMDBKeyStore.save(value)
      token = ""
      tokenMessage = "Token saved in Keychain."
      Task { await store.enrich() }
    } catch {
      tokenMessage = error.localizedDescription
    }
  }

  private func removeToken() {
    do {
      try TMDBKeyStore.save("")
      token = ""
      tokenMessage = "Token removed."
    } catch {
      tokenMessage = error.localizedDescription
    }
  }
}

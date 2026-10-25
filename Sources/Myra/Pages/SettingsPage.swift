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

/// The Settings window, laid out as the approved preview: an icon tab bar, grouped rows and a footer.
/// Owned controls save as they change. Embedded sections keep their own Save actions.
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

  private var accent: Color { (MyraAccent(rawValue: accentRaw) ?? .default).color }

  var body: some View {
    VStack(spacing: 0) {
      SettingsTabBar(selection: $selectedTab, accent: accent)
      Form {
        switch selectedTab {
        case .general: generalSections
        case .library: librarySections
        case .downloads: downloadsSections
        case .playback: playbackSections
        case .ai: MyraAISettingsSection()
        case .torrents: TorrentSettingsSection(controller: coordinator.torrents)
        }
      }
      .formStyle(.grouped)
      .scrollContentBackground(.hidden)
      SettingsFooter()
    }
    .frame(maxWidth: SettingsMetrics.windowWidth)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(MyraColor.window)
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

  @ViewBuilder private var generalSections: some View {
    SettingsGroup(title: "Appearance") {
      SettingsRow(title: "Theme") {
        SettingsSelect(
          title: "Theme", selection: $settings.theme,
          options: AppThemeMode.allCases.map { SettingsOption(value: $0, title: $0.displayName) })
      }
      SettingsRow(
        title: "Accent colour",
        detail: "Buttons, selection, sidebar and in-app icons follow this colour"
      ) {
        MyraAccentPicker(selection: accentBinding)
      }
    }
    MyraAppearanceSettingsSection()
    SettingsUpdatesGroup(updater: coordinator.updater)
    SettingsGroup(title: "Notifications") {
      SettingsToggleRow(
        title: "Notify me about new episodes of followed series",
        isOn: Binding(
          get: { store.personal.preferences.notifications },
          set: { store.setNotifications($0) }))
    }
    Section("About Myra \(appVersion)") {
      TMDBAttributionView()
    }
  }

  @ViewBuilder private var librarySections: some View {
    MediaSettingsSection(library: coordinator.library, refresh: coordinator.refreshLibraryIndex)
    SettingsGroup(
      title: "Home Discovery",
      note:
        "Use the API Read Access Token, rather than the API key. Only title information and provider IDs are sent; source video URLs are excluded."
    ) {
      SettingsRow(
        title: "TMDB API Read Access Token",
        detail: "Press Return to save the token in Keychain."
      ) {
        SecureField("Token", text: $token)
          .textFieldStyle(.roundedBorder)
          .frame(width: 220)
          .onSubmit { saveToken() }
      }
      if let message = MyraSettingsValidation.tokenMessage(token) {
        SettingsInlineMessage(text: message, color: .orange)
      }
      if let tokenMessage {
        SettingsInlineMessage(text: tokenMessage)
      }
      SettingsRow(title: "Saved token") {
        Button("Remove Token", role: .destructive) { removeToken() }
          .buttonStyle(MyraButtonStyle())
          .help("Remove the TMDB token from Keychain")
      }
      SettingsRow(title: "Get a TMDB token") {
        Link(
          "Open TMDB Settings",
          destination: URL(string: "https://www.themoviedb.org/settings/api")!
        )
        .buttonStyle(MyraButtonStyle())
      }
    }
  }

  @ViewBuilder private var downloadsSections: some View {
    SettingsGroup(
      title: "Location",
      note: "Leave the aria2 path empty to search PATH and common Homebrew locations."
    ) {
      SettingsRow(title: "Save downloads to", detail: settings.downloadDirectory) {
        Button("Choose…") { coordinator.chooseDownloadDirectory() }
          .buttonStyle(MyraButtonStyle())
      }
      SettingsRow(title: "aria2c") {
        TextField("Auto-detect", text: $settings.aria2PathOverride)
          .textFieldStyle(.roundedBorder)
          .frame(width: 260)
      }
    }
    SettingsGroup(
      title: "Performance",
      note: "Changes apply immediately. Invalid values are flagged inline instead of being saved."
    ) {
      SettingsRow(title: "Simultaneous files") {
        SettingsStepper(
          label: "Simultaneous files", value: $settings.concurrentDownloads, range: 1...20)
      }
      SettingsRow(title: "Connections per file") {
        SettingsStepper(
          label: "Connections per file", value: $settings.connectionsPerFile, range: 1...16)
      }
      SettingsRow(title: "Split count") {
        SettingsStepper(label: "Split count", value: $settings.splitCount, range: 1...16)
      }
      SettingsRow(title: "Retry count") {
        SettingsStepper(label: "Retry count", value: $settings.retryCount, range: 1...20)
      }
      SettingsRow(
        title: "Per-file speed limit",
        detail: "aria2 accepts values such as 0, 500K, or 10M."
      ) {
        TextField("0", text: $speedDraft)
          .multilineTextAlignment(.trailing)
          .textFieldStyle(.roundedBorder)
          .frame(width: 110)
          .onChange(of: speedDraft) { _, value in
            // Only valid values reach the settings; an invalid draft keeps the last good value.
            if MyraSettingsValidation.isValidSpeedLimit(value) {
              settings.speedLimit = value
            }
          }
      }
      if let message = MyraSettingsValidation.speedLimitMessage(speedDraft) {
        SettingsInlineMessage(text: message, color: .red)
      }
    }
  }

  @ViewBuilder private var playbackSections: some View {
    SettingsGroup(title: "Player") {
      SettingsRow(title: "Playback preferences") {
        Button("Playback Preferences…") { showingPlaybackPreferences = true }
          .buttonStyle(MyraButtonStyle())
      }
    }
    SubtitleSettingsSection()
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

/// The preview's `.tabs` bar: six icon-over-label tabs, centred, with the selected tab filled and in accent.
private struct SettingsTabBar: View {
  @Binding var selection: MyraSettingsTab
  let accent: Color

  var body: some View {
    HStack(spacing: 2) {
      Spacer(minLength: 0)
      ForEach(MyraSettingsTab.allCases) { tab in
        let isSelected = selection == tab
        Button {
          selection = tab
        } label: {
          VStack(spacing: 3) {
            Image(systemName: tab.symbol)
              .font(.system(size: SettingsMetrics.tabIconSize))
              .frame(width: SettingsMetrics.tabIconSize, height: SettingsMetrics.tabIconSize)
            Text(tab.title)
              .font(.system(size: SettingsMetrics.tabLabelSize))
          }
          .frame(minWidth: SettingsMetrics.tabMinWidth)
          .padding(.horizontal, 10)
          .padding(.vertical, 6)
          .background(
            isSelected ? MyraColor.fill2 : Color.clear,
            in: RoundedRectangle(cornerRadius: SettingsMetrics.tabRadius))
          .foregroundStyle(isSelected ? accent : MyraColor.text2)
          .contentShape(RoundedRectangle(cornerRadius: SettingsMetrics.tabRadius))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
      }
      Spacer(minLength: 0)
    }
    .padding(SettingsMetrics.tabBarPadding)
    .frame(maxWidth: .infinity)
    .background(MyraColor.fill)
    .overlay(alignment: .bottom) {
      Rectangle().fill(MyraColor.line).frame(height: 1)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Settings sections")
  }
}

/// The preview's `.foot`: the automatic-save note on the left and a Close button on the right.
private struct SettingsFooter: View {
  var body: some View {
    HStack(spacing: 8) {
      Text(SettingsMetrics.footerText)
        .font(.system(size: 12))
        .foregroundStyle(MyraColor.text2)
      Spacer(minLength: 8)
      Button("Close") {
        NSApp.keyWindow?.performClose(nil)
      }
      .buttonStyle(MyraButtonStyle())
      .keyboardShortcut(.cancelAction)
    }
    .padding(.horizontal, 22)
    .padding(.vertical, 12)
    .background(MyraColor.fill)
    .overlay(alignment: .top) {
      Rectangle().fill(MyraColor.line).frame(height: 1)
    }
  }
}

/// The Updates panel: the automatic-check switch, the installed version with Check Now, and the status note.
private struct SettingsUpdatesGroup: View {
  @ObservedObject var updater: AppUpdater

  private var installedVersion: String {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    return "Myra \(version ?? "Development") (\(build ?? "—"))"
  }

  private var statusNote: String {
    var lines = [
      "Checks quietly when Myra is open, at most once a day. Installation always requires your confirmation."
    ]
    if let date = updater.lastCheck {
      lines.append("Last checked \(date.formatted()).")
    }
    lines.append(updater.configurationProblem ?? updater.status)
    return lines.joined(separator: "\n")
  }

  var body: some View {
    SettingsGroup(title: "Updates", note: statusNote) {
      SettingsToggleRow(
        title: "Automatically check for updates",
        isOn: Binding(get: { updater.automaticallyChecks }, set: updater.setAutomaticChecks)
      )
      .disabled(updater.configurationProblem != nil)
      SettingsRow(title: "Current version", detail: installedVersion) {
        Button("Check Now") { updater.checkForUpdates() }
          .buttonStyle(MyraButtonStyle())
          .disabled(!updater.canCheckForUpdates)
      }
    }
  }
}

/// A stepper that shows its current value on the left of the arrows.
private struct SettingsStepper: View {
  let label: String
  @Binding var value: Int
  let range: ClosedRange<Int>

  var body: some View {
    HStack(spacing: 8) {
      Text("\(value)")
        .font(.system(size: 13))
        .monospacedDigit()
        .foregroundStyle(MyraColor.text)
      Stepper("\(label): \(value)", value: $value, in: range)
        .labelsHidden()
    }
  }
}

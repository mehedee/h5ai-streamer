import AppIntents

/// Shortcuts actions. Both open Myra and hand the request to `MyraSystemRouter`, which the
/// coordinator resolves against the library. Nothing is sent over the network.
struct PlayTitleIntent: AppIntent {
  static let title: LocalizedStringResource = "Play Title"
  static let description = IntentDescription("Plays a title from your Myra library.")
  static let openAppWhenRun = true

  @Parameter(title: "Title")
  var titleName: String

  @MainActor
  func perform() async throws -> some IntentResult {
    MyraSystemRouter.shared.post(.play(title: titleName))
    return .result()
  }
}

struct SearchLibraryIntent: AppIntent {
  static let title: LocalizedStringResource = "Search Library"
  static let description = IntentDescription("Searches your Myra library for a title.")
  static let openAppWhenRun = true

  @Parameter(title: "Search")
  var query: String

  @MainActor
  func perform() async throws -> some IntentResult {
    MyraSystemRouter.shared.post(.search(query: query))
    return .result()
  }
}

struct MyraShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: PlayTitleIntent(),
      phrases: ["Play a title in \(.applicationName)"],
      shortTitle: "Play Title",
      systemImageName: "play.rectangle")
    AppShortcut(
      intent: SearchLibraryIntent(),
      phrases: ["Search my library in \(.applicationName)"],
      shortTitle: "Search Library",
      systemImageName: "magnifyingglass")
  }
}

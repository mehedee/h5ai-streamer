import SwiftUI

/// The Add Search Indexer sheet: name, Torznab URL and API key (kept in the Keychain).
/// Test connection and Add are the only actions that contact the indexer.
struct AddIndexerSheet: View {
  @ObservedObject var store: TorrentIndexerStore
  var onAdded: (TorrentIndexer) -> Void = { _ in }
  @Environment(\.dismiss) private var dismiss
  @State private var draft = IndexerDraft()
  @State private var testing = false
  @State private var adding = false
  @State private var message: (text: String, isError: Bool)?

  private var engine: TorrentSearchEngine { TorrentSearchEngine(secrets: store.secrets) }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("Add Search Indexer").font(.title3.weight(.semibold))
      Text("Any Torznab-compatible indexer, including your own Jackett or Prowlarr.")
        .foregroundStyle(.secondary).padding(.top, 2)
      HStack(spacing: 8) {
        ForEach(IndexerDraft.Preset.allCases) { preset in
          Button(preset.title) {
            draft.apply(preset)
            message = nil
          }
          .buttonStyle(MyraButtonStyle())
        }
      }
      .padding(.top, 14)
      field("Name", prompt: "My indexer", text: $draft.name)
      field("Torznab URL", prompt: IndexerDraft.Preset.jackett.url, text: $draft.url)
      VStack(alignment: .leading, spacing: 4) {
        Text("API key")
        SecureField("Stored in your Keychain", text: $draft.key)
          .textFieldStyle(.roundedBorder)
          .accessibilityLabel("API key")
      }
      .padding(.top, 10)
      Group {
        if let message {
          Text(message.text).foregroundStyle(message.isError ? Color.red : Color.green)
        } else {
          Text(
            "Myra tests the connection by asking the indexer for its capabilities when you press Test. Nothing else is sent."
          )
          .foregroundStyle(.secondary)
        }
      }
      .font(.system(size: 12)).padding(.top, 12)
      .fixedSize(horizontal: false, vertical: true)
      HStack {
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        Spacer()
        if testing { ProgressView().controlSize(.small) }
        Button("Test connection") { Task { await test() } }
          .disabled(testing || adding)
        Button("Add Indexer") { Task { await add() } }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
          .disabled(testing || adding)
      }
      .padding(.top, 16)
    }
    .padding(22)
    .frame(width: 480)
  }

  private func field(_ title: String, prompt: String, text: Binding<String>) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title)
      TextField(prompt, text: text)
        .textFieldStyle(.roundedBorder)
        .accessibilityLabel(title)
    }
    .padding(.top, 10)
  }

  private func test() async {
    guard let endpoint = try? TorznabSource.validatedEndpoint(draft.url) else {
      message = (IndexerDraft.Problem.invalidURL.message, true)
      return
    }
    let key = draft.key.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty else {
      message = ("Enter the API key from your indexer.", true)
      return
    }
    testing = true
    message = ("Testing…", false)
    defer { testing = false }
    do {
      let outcome = try await engine.test(endpoint: endpoint, key: key)
      let caps = outcome.capabilities.isEmpty ? "" : " · capabilities: " + outcome.capabilities.joined(separator: ", ")
      message = ("Connected · responded in \(outcome.milliseconds) ms" + caps, false)
    } catch {
      message = (TorrentSearchEngine.failure(from: error).message, true)
    }
  }

  private func add() async {
    adding = true
    defer { adding = false }
    do {
      let indexer = try await store.add(draft)
      onAdded(indexer)
      dismiss()
    } catch let problem as IndexerDraft.Problem {
      message = (problem.message, true)
    } catch {
      message = ("Could not save the indexer or its API key. Try again.", true)
    }
  }
}

/// The "Search indexers" group for Settings > Torrents: every indexer with an on/off switch,
/// the last known health from the Search tab, Remove for custom ones, and Add….
struct TorrentIndexerSettingsGroup: View {
  @ObservedObject var store: TorrentIndexerStore
  @ObservedObject var search: TorrentSearchModel
  @State private var showAdd = false
  @State private var removing: TorrentIndexer?

  var body: some View {
    SettingsGroup(
      title: "Search indexers",
      note:
        "Nothing is sent until you press Search. API keys stay in this Mac's Keychain. Myra bundles no third-party sites: add your own Torznab endpoint."
    ) {
      ForEach(store.indexers) { indexer in
        SettingsRow(title: indexer.name, detail: indexer.isBuiltIn ? "Built in · " + indexer.note : indexer.note) {
          HStack(spacing: 10) {
            health(indexer)
            if !indexer.isBuiltIn {
              Button("Remove…", role: .destructive) { removing = indexer }
                .buttonStyle(MyraButtonStyle())
            }
            Toggle(indexer.name, isOn: binding(for: indexer))
              .labelsHidden().toggleStyle(.switch)
          }
        }
      }
      SettingsRow(
        title: "Add indexer",
        detail: "Any Torznab-compatible URL. The API key is kept in your Keychain."
      ) {
        Button("Add…") { showAdd = true }.buttonStyle(MyraButtonStyle())
      }
      if let error = store.error { SettingsInlineMessage(text: error, color: .red) }
    }
    .sheet(isPresented: $showAdd) { AddIndexerSheet(store: store) }
    .confirmationDialog(
      "Remove this indexer?",
      isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
      titleVisibility: .visible
    ) {
      Button("Remove Indexer and API Key", role: .destructive) {
        if let indexer = removing {
          Task {
            do { try await store.remove(indexer.id) } catch {
              store.error = "Could not remove the API key from the Keychain."
            }
          }
        }
        removing = nil
      }
      Button("Cancel", role: .cancel) { removing = nil }
    }
  }

  @ViewBuilder
  private func health(_ indexer: TorrentIndexer) -> some View {
    switch search.state(for: indexer.id) {
    case .finished: StatusPill(text: "Reachable", style: .ok)
    case .failed: StatusPill(text: "Offline", style: .err)
    default: EmptyView()
    }
  }

  private func binding(for indexer: TorrentIndexer) -> Binding<Bool> {
    Binding(
      get: { store.indexers.first { $0.id == indexer.id }?.enabled ?? false },
      set: { store.setEnabled($0, for: indexer.id) })
  }
}

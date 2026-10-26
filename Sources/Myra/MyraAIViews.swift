import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// An on-demand workspace. Playback and catalogue mutations remain explicit user actions.
struct MyraAIWorkspaceView: View {
  @ObservedObject var store: EntertainmentStore
  @ObservedObject private var ai: MyraAIStore
  let play: (EntertainmentTitle) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var feature: MyraAIFeature
  @State private var prompt = ""
  @State private var titleQuery = ""
  @State private var selectedIDs: Set<String>
  @State private var episodeID = ""
  @State private var subtitleText: String?
  @State private var subtitleName = ""
  @State private var importingSubtitle = false
  @State private var localMessage: String?
  @State private var appliedActions: Set<String> = []
  @State private var showingSettings = false
  @State private var availableMinutes = 120
  @State private var requestTask: Task<Void, Never>?
  @State private var result: MyraAIResponse?
  /// View-side timing for the grounding footer only. Nothing here changes the request.
  @State private var runStartedAt: Date?
  @State private var firstWordsAt: Date?
  @State private var runFinishedAt: Date?
  @State private var contentHeight: CGFloat = 0

  init(
    store: EntertainmentStore, initialFeature: MyraAIFeature = .smartPick,
    initialTitle: EntertainmentTitle? = nil, initialPrompt: String = "",
    ai: MyraAIStore = .shared, play: @escaping (EntertainmentTitle) -> Void
  ) {
    self.store = store
    _prompt = State(initialValue: initialPrompt)
    self.ai = ai
    self.play = play
    _feature = State(initialValue: initialFeature)
    _selectedIDs = State(initialValue: initialTitle.map { [$0.id] } ?? [])
  }

  private var selectedTitles: [EntertainmentTitle] {
    store.catalogue.filter { selectedIDs.contains($0.id) }
  }

  private var matchingTitles: [EntertainmentTitle] {
    var results: [EntertainmentTitle] = []
    for title in store.catalogue {
      if titleQuery.isEmpty || title.displayName.localizedCaseInsensitiveContains(titleQuery) {
        results.append(title)
        if results.count == 60 { break }
      }
    }
    return results
  }

  private var watchedEpisodes: [EntertainmentVersion] {
    guard let title = selectedTitles.first, title.kind == .series else { return [] }
    return title.versions.filter { version in
      guard version.episode != nil else { return false }
      if store.personal.watched.contains(title.id) { return true }
      guard let record = store.personal.history[version.id], record.duration > 0 else {
        return false
      }
      return record.seconds >= record.duration - 10
    }.sorted {
      if $0.season != $1.season { return ($0.season ?? 0) < ($1.season ?? 0) }
      return ($0.episode ?? 0) < ($1.episode ?? 0)
    }
  }

  private var requiresTitles: Bool {
    [.explain, .summary, .similar, .compare, .moodTags, .cleanup, .recap, .translate].contains(
      feature)
  }

  private var canRun: Bool {
    guard !ai.isBusy, ai.settings.provider != .disabled,
      ai.settings.enabledFeatures.contains(feature), !store.catalogue.isEmpty
    else { return false }
    if requiresTitles && selectedIDs.isEmpty { return false }
    if feature == .compare && selectedIDs.count < 2 { return false }
    if feature == .recap && (episodeID.isEmpty || subtitleText == nil) { return false }
    return true
  }

  /// The preview's Ask Myra sheet (`.sheet.ai`): one prompt row, the streamed answer, three
  /// recommendation cards and the grounding line, then Close and Ask Again in the footer.
  var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          MyraAIPromptField(
            text: $prompt, label: "Your request or preferences",
            placeholder: "Ask for something to watch, a summary or a comparison",
            submit: { if canRun { run() } })
          if needsContext {
            contextControls.padding(.top, 12)
          }
          answer.padding(.top, 14)
          if let response = result {
            recommendations(response).padding(.top, 12)
            if !response.tags.isEmpty {
              Text("Suggested tags: " + response.tags.joined(separator: " · "))
                .font(.system(size: 12)).foregroundStyle(MyraColor.text2)
                .padding(.top, 10)
            }
            if !response.actions.isEmpty {
              VStack(alignment: .leading, spacing: 8) {
                Text("Review proposed changes").font(.system(size: 13, weight: .semibold))
                Text("Nothing changes until you choose Apply. Review corrections before saving.")
                  .font(.system(size: 11)).foregroundStyle(MyraColor.text2)
                ForEach(response.actions) { action in actionPreview(action) }
              }
              .padding(.top, 14)
            }
          }
          grounding.padding(.top, 12)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
          GeometryReader { proxy in
            Color.clear.preference(key: MyraAISheetHeightKey.self, value: proxy.size.height)
          }
        }
      }
      // The sheet follows its content like the preview, growing as the answer arrives and
      // scrolling only past 560pt.
      .frame(height: min(max(contentHeight, 120), 560))
      .onPreferenceChange(MyraAISheetHeightKey.self) { contentHeight = $0 }
      footer
    }
    .frame(width: 600)
    .background(MyraColor.window)
    .onAppear {
      ai.refreshAvailability()
      ai.prewarm(feature: feature)
    }
    .onDisappear {
      requestTask?.cancel()
      ai.cancel()
      subtitleText = nil
    }
    .onChange(of: feature) { _, _ in
      localMessage = nil
      appliedActions.removeAll()
      result = nil
      ai.prewarm(feature: feature)
    }
    .onChange(of: episodeID) { _, _ in
      subtitleText = nil
      subtitleName = ""
    }
    .onChange(of: ai.partialSummary) { _, partial in
      if !partial.isEmpty, firstWordsAt == nil, runStartedAt != nil { firstWordsAt = Date() }
    }
    .sheet(isPresented: $showingSettings) { MyraAISettingsWindow(ai: ai) }
    .fileImporter(isPresented: $importingSubtitle, allowedContentTypes: [.plainText, .data]) {
      result in
      importSubtitle(result)
    }
  }

  /// Tools that need chosen titles, an episode or a time budget show those controls under the
  /// prompt; the default Smart Pick needs none, as in the preview.
  private var needsContext: Bool {
    requiresTitles || feature == .collection || feature == .action || feature == .plan
      || feature == .recap
  }

  @ViewBuilder private var contextControls: some View {
    VStack(alignment: .leading, spacing: 12) {
      if feature == .plan {
        Stepper(
          "Time available: \(availableMinutes) minutes", value: $availableMinutes,
          in: 15...600, step: 15)
      }
      if requiresTitles || feature == .collection || feature == .action { titleSelection }
      if feature == .recap { recapControls }
    }
    .font(.system(size: 13))
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(MyraColor.content, in: RoundedRectangle(cornerRadius: 10))
    .overlay(RoundedRectangle(cornerRadius: 10).stroke(MyraColor.line, lineWidth: 1))
  }

  /// The `.answer` block: streamed text with the cursor while Myra writes, then the result.
  /// Before a run it shows what the chosen tool does; problems show here in orange.
  @ViewBuilder private var answer: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let message = localMessage {
        Text(message).foregroundStyle(.orange)
      }
      if let message = ai.errorMessage {
        Text(message).foregroundStyle(.orange).textSelection(.enabled)
      }
      if let response = result {
        MyraAIAnswerText(text: response.summary)
      } else if ai.isBusy {
        MyraAIAnswerText(text: ai.partialSummary, streaming: true)
      } else if localMessage == nil, ai.errorMessage == nil {
        Text(feature.hint).foregroundStyle(MyraColor.text2)
        if !ai.settings.enabledFeatures.contains(feature) {
          Text("This tool is turned off. Turn it on in AI Settings.").foregroundStyle(.orange)
        }
      }
    }
    .font(.system(size: 13))
    .lineSpacing(4)
    .frame(maxWidth: .infinity, minHeight: 48, alignment: .topLeading)
  }

  /// Three cards across, as the preview's `.recs` grid.
  private func recommendations(_ response: MyraAIResponse) -> some View {
    LazyVGrid(
      columns: Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: 3),
      alignment: .leading, spacing: 10
    ) {
      ForEach(Array(response.recommendations.enumerated()), id: \.offset) {
        offset, recommendation in
        if let title = store.catalogue.first(where: { $0.id == recommendation.titleID }) {
          recommendationCard(
            title, reason: recommendation.reason, versionID: recommendation.versionID,
            index: offset)
        }
      }
    }
  }

  /// The `.grounding` line. Before a run it states where requests go; after, how the answer
  /// was made. The fixed-rule fallback and undo stay with it.
  @ViewBuilder private var grounding: some View {
    VStack(alignment: .leading, spacing: 6) {
      if let response = result {
        MyraAIGroundingFooter(
          items: MyraAIGroundingLine.footerItems(
            providerName: response.path == .deterministicFallback
              ? "Fixed-rule picks" : response.provider,
            pickCount: response.recommendations.count,
            timing: timingLabel, provider: ai.settings.provider))
        if response.path == .deterministicFallback {
          Text(
            "Answered by Myra's fixed-rule recommender because the on-device model did not answer."
              + (response.pathReason.map { " Reason: \($0)" } ?? ""))
        }
        Text(response.sourceNote)
        if ai.canUndo {
          Button("Undo Last Library Change") {
            do {
              try ai.undo(in: store)
              appliedActions.removeAll()
              localMessage = "Change undone."
            } catch { localMessage = error.localizedDescription }
          }
          .buttonStyle(MyraButtonStyle())
        }
      } else {
        // The provider status already says where requests go.
        MyraAIGroundingFooter(
          items: [ai.status, timingLabel].compactMap { $0 }.filter { !$0.isEmpty }
            + (ai.settings.provider.isCloud ? ["May incur charges"] : []))
      }
    }
    .font(.system(size: 11))
    .foregroundStyle(MyraColor.text2)
  }

  /// The `.foot`: the tool and AI Settings on the left, Close and Ask on the right.
  private var footer: some View {
    HStack(spacing: 8) {
      Menu {
        Picker("Tool", selection: $feature) {
          ForEach(MyraAIFeature.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .pickerStyle(.inline)
      } label: {
        Text(feature.title)
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .disabled(ai.isBusy)
      .help("Choose what Myra should do")
      .accessibilityLabel("Myra AI tool")
      Button("AI Settings…") { showingSettings = true }
        .buttonStyle(.plain)
        .foregroundStyle(MyraColor.text2)
      Spacer(minLength: 12)
      Button("Close") {
        ai.cancel()
        dismiss()
      }
      .buttonStyle(MyraButtonStyle())
      .keyboardShortcut(.cancelAction)
      if ai.isBusy {
        Button("Stop") {
          ai.cancel()
          requestTask?.cancel()
        }
        .buttonStyle(MyraButtonStyle(prominent: true))
      } else {
        Button(result == nil ? "Ask Myra" : "Ask Again") { run() }
          .buttonStyle(MyraButtonStyle(prominent: true))
          .disabled(!canRun)
          .keyboardShortcut(.return, modifiers: [.command])
      }
    }
    .font(.system(size: 13))
    .padding(.horizontal, 22)
    .padding(.vertical, 12)
    .background(MyraColor.fill)
    .overlay(alignment: .top) { Rectangle().fill(MyraColor.line).frame(height: 1) }
  }

  private var titleSelection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(feature == .compare ? "Choose two or more titles" : "Choose titles").font(.headline)
      ForEach(selectedTitles) { title in
        HStack {
          Text(title.displayName).lineLimit(1)
          Spacer()
          Button {
            selectedIDs.remove(title.id)
            episodeID = ""
          } label: {
            Image(systemName: "xmark.circle")
          }
          .buttonStyle(.plain).accessibilityLabel("Remove \(title.displayName)")
        }
      }
      TextField("Find a title in your library", text: $titleQuery).textFieldStyle(.roundedBorder)
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 6) {
          ForEach(matchingTitles) { title in
            Button {
              if feature == .recap {
                selectedIDs = [title.id]
                episodeID = ""
              } else if selectedIDs.count < 10 {
                selectedIDs.insert(title.id)
              }
            } label: {
              HStack {
                Text(title.displayName).lineLimit(1)
                if let year = title.year { Text(year).foregroundStyle(.secondary) }
                Spacer()
                if selectedIDs.contains(title.id) { Image(systemName: "checkmark") }
              }
            }.buttonStyle(.plain)
              .disabled(
                (feature == .recap && title.kind != .series) || selectedIDs.contains(title.id))
          }
        }
      }.frame(height: 130)
      Text("Showing up to 60 matches. Select up to 10 titles.").font(.caption).foregroundStyle(
        .secondary)
    }
  }

  private var recapControls: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Recap a watched episode").font(.headline)
      Picker("Episode", selection: $episodeID) {
        Text("Select an episode").tag("")
        ForEach(watchedEpisodes) { version in
          Text(
            String(format: "Season %d · Episode %02d", version.season ?? 0, version.episode ?? 0)
          ).tag(version.id)
        }
      }
      if watchedEpisodes.isEmpty {
        Text("Only completed episodes or episodes of a series you marked watched are eligible.")
          .font(.caption).foregroundStyle(.secondary)
      }
      Button("Import This Episode’s Subtitles…") { importingSubtitle = true }.disabled(
        episodeID.isEmpty)
      if !subtitleName.isEmpty { Text(subtitleName).font(.caption).lineLimit(2) }
      Text(
        "Select subtitles for this episode only. Subtitles can contain spoilers; a recap cannot guarantee spoiler-free output. Cloud transmission requires separate permission in AI Settings."
      )
      .font(.caption).foregroundStyle(.secondary)
    }
  }

  private func recommendationCard(
    _ title: EntertainmentTitle, reason: String, versionID: String?, index: Int
  ) -> some View {
    let playbackTitle = Self.playbackTitle(title, versionID: versionID)
    let episodeLabel: String? = {
      guard let versionID, let version = title.versions.first(where: { $0.id == versionID }),
        let episode = version.episode
      else { return nil }
      return String(format: "S%d E%02d", version.season ?? 0, episode)
    }()
    let inWatchlist = store.personal.watchlist.contains(title.id)
    return MyraAIRecommendationCard(
      title: title,
      statusLine: MyraAIGroundingLine.recommendationStatus(
        runtimeMinutes: MyraAIContext.runtime(playbackTitle),
        kind: title.kind.rawValue.capitalized, episodeLabel: episodeLabel,
        inWatchlist: inWatchlist, watched: store.personal.watched.contains(title.id)),
      reason: reason,
      playLabel: playbackTitle.resumeVersion == nil ? "Play" : "Resume",
      inWatchlist: inWatchlist, index: index,
      play: { play(playbackTitle) },
      toggleWatchlist: { store.toggleWatchlist(title.id) })
  }

  /// The footer timing: "Thinking…", "First words in … s", then "Done in … s".
  private var timingLabel: String? {
    guard let started = runStartedAt else { return nil }
    return MyraAIGroundingLine.timingLabel(
      running: ai.isBusy,
      secondsToFirstWords: firstWordsAt.map { $0.timeIntervalSince(started) },
      totalSeconds: runFinishedAt.map { $0.timeIntervalSince(started) })
  }

  /// Keeps a timed episode recommendation attached to its validated media selection.
  static func playbackTitle(_ title: EntertainmentTitle, versionID: String?) -> EntertainmentTitle {
    guard let versionID, let version = title.versions.first(where: { $0.id == versionID }) else {
      return title
    }
    var selected = title
    selected.versions = [version]
    return selected
  }

  private func actionPreview(_ action: MyraAIAction) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(action.label).font(.headline)
      if !action.value.isEmpty { Text(action.value).textSelection(.enabled) }
      ForEach(action.titleIDs, id: \.self) { id in
        if let title = store.catalogue.first(where: { $0.id == id }) {
          Text(title.displayName).font(.caption).foregroundStyle(.secondary)
        }
      }
      if let year = action.year { Text("Year: \(year)").font(.caption) }
      if let kind = action.mediaKind { Text("Type: \(kind.rawValue)").font(.caption) }
      Button(appliedActions.contains(action.id) ? "Applied" : "Apply") {
        do {
          if action.kind == .play {
            guard let id = action.titleIDs.first,
              let title = store.catalogue.first(where: { $0.id == id })
            else { return }
            play(title)
          } else if action.kind == .showResults {
            selectedIDs = Set(action.titleIDs)
            localMessage = "Selected matching titles. Use their playback buttons above."
          } else {
            try ai.apply(action, to: store)
            appliedActions.insert(action.id)
            localMessage = "Change saved."
          }
        } catch { localMessage = error.localizedDescription }
      }.disabled(appliedActions.contains(action.id) || ai.isBusy)
    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
      .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
  }

  private func run() {
    localMessage = nil
    appliedActions.removeAll()
    var request = prompt
    if feature == .plan { request += "\nAvailable time: \(availableMinutes) minutes." }
    if feature == .recap, let version = watchedEpisodes.first(where: { $0.id == episodeID }) {
      request +=
        "\nRecap only Season \(version.season ?? 0), Episode \(version.episode ?? 0). Source: \(subtitleName)."
    }
    result = nil
    runStartedAt = Date()
    firstWordsAt = nil
    runFinishedAt = nil
    requestTask = Task {
      await ai.execute(
        feature: feature, prompt: request, titles: store.catalogue,
        personal: store.personal, revision: store.projectionRevision,
        selectedIDs: selectedIDs.sorted(), subtitleText: feature == .recap ? subtitleText : nil,
        recapVersionID: feature == .recap ? episodeID : nil)
      if !Task.isCancelled {
        result = ai.response
        if result != nil { runFinishedAt = Date() }
      }
    }
  }

  private func importSubtitle(_ result: Result<URL, Error>) {
    do {
      let url = try result.get()
      guard ["srt", "ass", "ssa", "vtt", "txt"].contains(url.pathExtension.lowercased()) else {
        localMessage = "Choose an SRT, ASS, SSA, VTT, or text subtitle file."
        return
      }
      let access = url.startAccessingSecurityScopedResource()
      defer { if access { url.stopAccessingSecurityScopedResource() } }
      let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
      guard ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 2_000_000 else {
        localMessage = "Choose a subtitle file smaller than 2 MB."
        return
      }
      let data = try Data(contentsOf: url)
      guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16),
        !text.isEmpty
      else {
        localMessage = "The subtitle file must contain readable UTF-8 or UTF-16 text."
        return
      }
      subtitleText = text
      subtitleName = url.lastPathComponent
      localMessage = "Imported for this request only."
    } catch { localMessage = error.localizedDescription }
  }
}

/// The measured height of the Ask Myra sheet's content.
private struct MyraAISheetHeightKey: PreferenceKey {
  static let defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = max(value, nextValue())
  }
}

struct MyraAISettingsWindow: View {
  var ai: MyraAIStore = .shared
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    VStack {
      HStack {
        Text("AI Settings").font(.title2.bold())
        Spacer()
        Button("Done") { dismiss() }
      }
      Form { MyraAISettingsSection(ai: ai) }.formStyle(.grouped)
    }.padding(20).frame(minWidth: 620, minHeight: 600)
  }
}

struct MyraAISettingsSection: View {
  @ObservedObject private var ai: MyraAIStore
  @State private var key = ""
  @State private var message: String?
  @State private var feedback = ""

  init(ai: MyraAIStore = .shared) { self.ai = ai }

  var body: some View {
    SettingsGroup(title: "Provider") {
      SettingsRow(title: "Model") {
        SettingsSelect(
          title: "Provider", selection: $ai.settings.provider,
          options: MyraAIProvider.allCases.map { SettingsOption(value: $0, title: $0.title) })
      }
      SettingsRow(title: "Status", detail: ai.status) {
        StatusPill(
          text: ai.settings.provider == .disabled
            ? "Off" : (ai.errorMessage == nil ? "Available" : "Check settings"),
          style: ai.settings.provider == .disabled
            ? .neutral : (ai.errorMessage == nil ? .ok : .warn))
      }
      if let error = ai.errorMessage { SettingsInlineMessage(text: error, color: .orange) }
    }
    .onChange(of: ai.settings.provider) { _, _ in
      key = ""
      ai.settings.model = ""
      ai.refreshAvailability()
    }
    if ai.settings.provider.isCloud {
      SettingsGroup(
        title: "Cloud Provider",
        note:
          "Cloud requests may incur charges. Compact catalogue metadata and your request are sent to the selected provider. Media URLs, private paths and network credentials are excluded. Subtitle text is sent only when you import it and allow it here."
      ) {
        SettingsRow(title: "API key", detail: "Saved in Keychain") {
          HStack(spacing: 6) {
            SecureField("API key", text: $key)
              .textFieldStyle(.roundedBorder).labelsHidden().frame(width: 180)
            Button("Save") {
              do {
                try ai.saveKey(key)
                key = ""
                message = "Saved in macOS Keychain."
              } catch { message = error.localizedDescription }
            }
            .buttonStyle(MyraButtonStyle())
            .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Remove") {
              do {
                try ai.removeKey()
                message = "Key removed."
              } catch { message = error.localizedDescription }
            }
            .buttonStyle(MyraButtonStyle())
          }
        }
        SettingsRow(title: "Model identifier") {
          HStack(spacing: 6) {
            TextField("Model", text: $ai.settings.model)
              .textFieldStyle(.roundedBorder).labelsHidden().frame(width: 180)
            if !ai.models.isEmpty {
              Menu("Models") {
                ForEach(ai.models, id: \.self) { model in
                  Button(model) { ai.settings.model = model }
                }
              }
              .menuStyle(.borderlessButton).fixedSize()
            }
          }
        }
        SettingsRow(title: "Connection") {
          HStack(spacing: 6) {
            Button("Refresh Models") { Task { await ai.refreshModels() } }
              .buttonStyle(MyraButtonStyle()).disabled(ai.isBusy)
            Button("Test Connection") { Task { await ai.testConnection() } }
              .buttonStyle(MyraButtonStyle()).disabled(ai.isBusy)
          }
        }
        SettingsToggleRow(
          title: "Allow requests to this provider", isOn: $ai.settings.cloudConsent)
        SettingsToggleRow(
          title: "Include watch history", isOn: $ai.settings.shareHistory)
        SettingsToggleRow(
          title: "Allow subtitle text in recaps", isOn: $ai.settings.shareSubtitles)
      }
    }
    SettingsGroup(title: "Features") {
      SettingsToggleRow(
        title: "Personalise from my history",
        detail: ai.settings.provider.isCloud
          ? "Uses your saved preferences" : "Stays on this Mac with the Apple model",
        isOn: $ai.settings.personalize)
      ForEach(MyraAIFeature.allCases, id: \.self) { feature in
        SettingsToggleRow(
          title: feature.title,
          isOn: Binding(
            get: { ai.settings.enabledFeatures.contains(feature) },
            set: { enabled in
              if enabled {
                ai.settings.enabledFeatures.insert(feature)
              } else {
                ai.settings.enabledFeatures.remove(feature)
              }
            }))
      }
    }
    SettingsGroup(
      title: "Limits",
      note:
        "Limits are local safeguards, not provider billing limits. Token totals are approximate character-based estimates."
    ) {
      SettingsRow(title: "Response language", detail: "For example en or bn") {
        TextField("en", text: $ai.settings.language)
          .textFieldStyle(.roundedBorder).labelsHidden().frame(width: 80)
      }
      SettingsRow(title: "Daily request limit") {
        SettingsSelect(
          title: "Daily request limit", selection: $ai.settings.dailyRequestLimit,
          options: SettingsChoices.numbers(
            [5, 10, 20, 50, 100, 200, 500], current: ai.settings.dailyRequestLimit))
      }
      SettingsRow(title: "Maximum response tokens") {
        SettingsSelect(
          title: "Maximum response tokens", selection: $ai.settings.maximumOutputTokens,
          options: SettingsChoices.numbers(
            Array(stride(from: 256, through: 2000, by: 128)),
            current: ai.settings.maximumOutputTokens))
      }
      SettingsRow(
        title: "Usage today",
        detail:
          "\(ai.requestsToday) requests · about \(ai.inputTokens) input and \(ai.outputTokens) output tokens"
      ) {
        Button("Clear AI Cache") {
          ai.clearCache()
          message = "AI cache cleared."
        }
        .buttonStyle(MyraButtonStyle())
      }
      if let message { SettingsInlineMessage(text: message) }
    }
    SettingsGroup(
      title: "Personal Preferences",
      note:
        "For example: less horror, more mysteries, shorter movies. You control this text; Myra does not silently infer permanent preferences."
    ) {
      TextEditor(text: $feedback)
        .font(.system(size: 13))
        .scrollContentBackground(.hidden)
        .frame(height: 64)
        .padding(.horizontal, 8).padding(.vertical, 6)
        .accessibilityLabel("Explicit viewing preferences")
      SettingsRow(title: "Preferences") {
        HStack(spacing: 6) {
          Button("Reset") {
            feedback = ""
            ai.saveFeedback("")
            message = "Preferences reset."
          }
          .buttonStyle(MyraButtonStyle())
          Button("Save") {
            ai.saveFeedback(feedback)
            message = "Preferences saved."
          }
          .buttonStyle(MyraButtonStyle(prominent: true))
        }
      }
    }
    .onAppear {
      feedback = ai.settings.feedback
      ai.refreshAvailability()
    }
  }
}

import SwiftUI
import VLCKit

private func byteText(_ value: Int64) -> String {
  ByteCountFormatter.string(fromByteCount: max(0, value), countStyle: .file)
}

/// Transfers page: add-link bar, Now Streaming card, Active list, and open-video Discover tab.
struct TorrentsView: View {
  @ObservedObject var controller: TorrentController
  /// The shell's toolbar search; it narrows the Active list.
  var searchText = ""
  @State private var tab = 0
  @State private var link = ""
  @State private var removing: TorrentIdentity?

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        SegmentedControl(
          options: [
            SegmentOption(value: 0, title: "Transfers"),
            SegmentOption(value: 1, title: "Discover"),
          ],
          selection: $tab)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 26)
      .padding(.top, 8)
      .padding(.bottom, 14)
      if tab == 0 {
        transfersPage
      } else {
        TorrentDiscoveryView(controller: controller, model: controller.discovery)
      }
      if let notice = controller.notice {
        HStack {
          Image(systemName: "checkmark.circle").foregroundStyle(.green)
          Text(notice).font(.callout)
          Spacer()
          Button {
            controller.notice = nil
          } label: {
            Image(systemName: "xmark")
          }.buttonStyle(.plain).accessibilityLabel("Dismiss notice")
        }.padding(12).background(.thinMaterial)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .dropDestination(for: URL.self) { urls, _ in
      let links = urls.filter { TorrentLinkRouter.route($0) != .ignored }
      links.forEach { controller.handleOpenURL($0) }
      return !links.isEmpty
    }
    .task { await controller.load() }
    .alert(
      "Torrent operation failed",
      isPresented: Binding(
        get: { controller.error != nil }, set: { if !$0 { controller.error = nil } })
    ) {
      Button("OK") { controller.error = nil }
    } message: {
      Text(controller.error ?? "")
    }
    .confirmationDialog(
      "Remove torrent and cached files?",
      isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
      titleVisibility: .visible
    ) {
      Button("Remove Cached Files", role: .destructive) {
        if let id = removing { Task { await controller.remove(id) } }
        removing = nil
      }
      Button("Cancel", role: .cancel) { removing = nil }
    } message: {
      Text(
        "Cancel the transfer and turn off Keep Download first. User library files are never removed."
      )
    }
  }

  /// The dashed add bar (`.addbar`): a link field with the import action, a Continue button, then the privacy hint.
  private var addLinkBar: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 10) {
        HStack(spacing: 8) {
          Image(systemName: "link")
            .font(.system(size: 14))
            .foregroundStyle(MyraColor.text3)
            .accessibilityHidden(true)
          TextField("Paste a magnet link or drop a .torrent file", text: $link)
            .textFieldStyle(.plain)
            .onSubmit(addLink)
          Button {
            controller.chooseTorrentFile()
          } label: {
            Image(systemName: "doc.badge.plus")
              .font(.system(size: 14))
              .foregroundStyle(MyraColor.text2)
          }
          .buttonStyle(.plain)
          .disabled(!controller.ready)
          .help("Import a .torrent file")
          .accessibilityLabel("Import .torrent…")
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(MyraColor.content, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(MyraColor.line, lineWidth: 1))
        Button("Continue", action: addLink)
          .buttonStyle(MyraButtonStyle(prominent: true))
          .disabled(!controller.ready || link.trimmingCharacters(in: .whitespaces).isEmpty)
          .accessibilityLabel("Add")
      }
      .padding(14)
      .background(MyraColor.fill, in: RoundedRectangle(cornerRadius: 14))
      .overlay(
        RoundedRectangle(cornerRadius: 14)
          .strokeBorder(MyraColor.lineStrong, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
      Text(
        "Torrent peers and trackers can see your IP address. This is not anonymous. Only play content you have permission to use. Networking starts only when you add a link."
      )
      .font(.system(size: 12))
      .foregroundStyle(MyraColor.text3)
      .padding(.top, 6)
      .padding(.horizontal, 2)
    }
  }

  private func addLink() {
    let value = link.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return }
    Task {
      await controller.addMagnet(value)
      if controller.error == nil { link = "" }
    }
  }

  private var transfersPage: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        addLinkBar
        if let streaming = controller.streamingRow {
          SectionHeader(title: "Now Streaming")
          NowStreamingCard(controller: controller, row: streaming)
        }
        if controller.transferRows.isEmpty {
          ContentUnavailableView(
            "No torrents yet", systemImage: "network",
            description: Text("Paste a magnet link, drop a .torrent file, or discover an open video."))
            .frame(maxWidth: .infinity, minHeight: 220)
        } else {
          let query = searchText.trimmingCharacters(in: .whitespaces)
          let active = controller.transferRows.filter {
            !$0.isStreaming && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query))
          }
          if !active.isEmpty {
            SectionHeader(title: "Active", count: active.count)
            RowCard(rows: active.map(activeRow))
          }
        }
      }
      .padding(.horizontal, 26)
      .padding(.top, 4)
      .padding(.bottom, 30)
    }
  }

  /// One Active row: the transfer's state, byte progress, speed and peers, with its controls.
  private func activeRow(_ row: TorrentTransferRow) -> RowCardItem {
    let job = controller.jobs.first { $0.id == row.id }
    let identity = try? TorrentIdentity(rawValue: row.id)
    let kept = job?.keepDownload == true
    let fraction = row.bytesTotal > 0 ? min(1, Double(row.bytesDone) / Double(row.bytesTotal)) : 0

    var actions: [RowCardAction] = []
    if job?.selectedFileIndex == nil {
      actions.append(
        RowCardAction(id: "choose", title: "Choose Video…", style: .button) {
          controller.selectingJob = identity
        })
    }
    actions.append(
      RowCardAction(
        id: "pause", title: row.isPaused ? "Resume" : "Pause",
        systemImage: row.isPaused ? "play.fill" : "pause.fill"
      ) {
        guard let identity else { return }
        if row.isPaused {
          Task { await controller.resume(identity) }
        } else {
          controller.pause(identity)
        }
      })
    actions.append(
      RowCardAction(id: "cancel", title: "Cancel", systemImage: "xmark") {
        if let identity { controller.cancel(identity) }
      })
    // A kept torrent cannot be removed until Keep Download is turned off, so its remove control is withheld.
    if !kept {
      actions.append(
        RowCardAction(id: "remove", title: "Remove…", systemImage: "trash") {
          removing = identity
        })
    }

    let status: StatusPill
    if row.isComplete {
      status = StatusPill(text: "Complete", style: .ok)
    } else if row.isPaused {
      status = StatusPill(text: "Paused", style: .warn)
    } else {
      status = StatusPill(text: row.state.isEmpty ? "Finding peers" : row.state, style: .live)
    }

    return RowCardItem(
      id: row.id, title: row.name,
      thumbnailSymbol: row.isComplete ? "checkmark" : "arrow.down",
      thumbnailColors: LibraryPalette.gradient(for: row.name),
      tags: kept ? ["Kept"] : [],
      meta: [
        "\(byteText(row.bytesDone)) of \(byteText(row.bytesTotal))",
        "↓ \(byteText(row.downloadSpeed))/s",
        "\(row.peers) peers",
      ],
      status: status, progress: fraction, actions: actions)
  }
}

/// The Now Streaming panel (`.streaming`): a 16:9 still, the title with a live pill, the buffer bar and the stream stats.
private struct NowStreamingCard: View {
  @ObservedObject var controller: TorrentController
  let row: TorrentTransferRow
  @Environment(\.myraAccent) private var accent
  private var transfer: TorrentTransfer { controller.transfers[row.id] ?? TorrentTransfer() }
  private var identity: TorrentIdentity? { try? TorrentIdentity(rawValue: row.id) }
  private var kept: Bool { controller.jobs.first { $0.id == row.id }?.keepDownload == true }
  private var verified: Double { min(1, max(0, transfer.streamPercent / 100)) }

  var body: some View {
    HStack(alignment: .center, spacing: 18) {
      still
        .frame(width: 220)
      VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: 8) {
          Text(row.name)
            .font(.system(size: 15, weight: .bold))
            .lineLimit(2)
            .help(row.name)
          StatusPill(
            text: row.bufferedSeconds < 5 ? "Buffering" : "Playing",
            style: .live)
        }
        HStack(spacing: 18) {
          kv("State", row.state.isEmpty ? "Starting" : row.state)
          kv("Verified", "\(Int(transfer.streamPercent.rounded()))%")
        }
        .padding(.top, 4)
        .padding(.bottom, 10)
        bufferBar
        HStack(spacing: 18) {
          kv("Buffered ahead", clock(row.bufferedSeconds))
          kv("↓", "\(byteText(row.downloadSpeed))/s")
          kv("Peers", "\(row.peers)")
          kv("Cache", byteText(transfer.downloaded))
        }
        .padding(.top, 8)
        HStack(spacing: 8) {
          Button {
            TorrentPlayerWindow.bringToFront()
          } label: {
            Label("Return to Player", systemImage: "play.fill")
          }
          .buttonStyle(MyraButtonStyle(prominent: true))
          Button {
            guard let identity else { return }
            Task { await controller.setKeep(identity, keep: true) }
          } label: {
            Label(kept ? "Kept" : "Keep a Copy", systemImage: "arrow.down.to.line")
          }
          .buttonStyle(MyraButtonStyle())
          .disabled(kept || identity == nil)
          Text(
            kept
              ? "Kept after watching."
              : "Removed from the cache after watching unless you keep a copy."
          )
          .font(.system(size: 12))
          .foregroundStyle(MyraColor.text2)
          .lineLimit(2)
        }
        .padding(.top, 12)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(14)
    .background(MyraColor.content, in: RoundedRectangle(cornerRadius: MyraRadius.panel))
    .overlay(
      RoundedRectangle(cornerRadius: MyraRadius.panel).stroke(MyraColor.line, lineWidth: 1))
  }

  private var still: some View {
    ZStack(alignment: .bottomLeading) {
      RoundedRectangle(cornerRadius: 10)
        .fill(
          LinearGradient(
            colors: LibraryPalette.gradient(for: row.name), startPoint: .topLeading,
            endPoint: .bottomTrailing))
      Text(row.name)
        .font(.system(size: 13, weight: .bold))
        .foregroundStyle(.white)
        .lineLimit(1)
        .padding(10)
    }
    .aspectRatio(16.0 / 9.0, contentMode: .fit)
    .accessibilityHidden(true)
  }

  /// The buffer bar (`.buffer`). The verified part is drawn as the buffered-ahead segment.
  private var bufferBar: some View {
    GeometryReader { geometry in
      ZStack(alignment: .leading) {
        Capsule().fill(MyraColor.fill2)
        Capsule()
          .fill(accent.color.opacity(0.4))
          .frame(width: geometry.size.width * verified)
      }
    }
    .frame(height: 6)
    .clipShape(Capsule())
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Stream verified")
    .accessibilityValue("\(Int((verified * 100).rounded())) percent")
  }

  private func kv(_ label: String, _ value: String) -> some View {
    (Text(label + " ").foregroundStyle(MyraColor.text2)
      + Text(value).fontWeight(.semibold).foregroundStyle(MyraColor.text))
      .font(.system(size: 12))
      .monospacedDigit()
      .lineLimit(1)
  }

  private func clock(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.rounded()))
    return String(format: "%d:%02d", total / 60, total % 60)
  }
}

/// Opens as soon as a link is added. Metadata keeps resolving while it is open.
struct TorrentAddSheet: View {
  @ObservedObject var controller: TorrentController
  let identity: TorrentIdentity
  @Environment(\.dismiss) private var dismiss
  @State private var chosen: Int?
  @State private var keepAfterWatching = false

  private var job: TorrentJob? { controller.jobs.first { $0.identity == identity } }
  private var files: [TorrentFile] { TorrentFile.playbackOrder(job?.files ?? []) }
  private var selected: TorrentFile? { files.first { $0.index == chosen } }
  private var state: String { controller.transfers[identity.rawValue]?.state ?? "" }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(job?.name ?? "Magnet link").font(.title2.weight(.semibold)).lineLimit(2)
        .help(job?.name ?? "")
      Text(state.isEmpty ? "Resolving metadata…" : state)
        .font(.caption).foregroundStyle(.secondary)
      if files.isEmpty {
        ProgressView("Resolving metadata…")
        Text(
          "Metadata needs reachable peers or trackers. Close this sheet and cancel the transfer if it does not resolve."
        )
        .font(.caption).foregroundStyle(.secondary)
      } else {
        List(files, id: \.index) { file in
          Button {
            chosen = file.index
          } label: {
            HStack {
              VStack(alignment: .leading) {
                Text(file.episode.map { "Season \($0.season) · Episode \($0.number)" } ?? file.name)
                  .lineLimit(1)
                Text(file.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
              }
              Spacer()
              Text(byteText(file.size)).font(.caption)
              if chosen == file.index {
                Image(systemName: "checkmark").foregroundStyle(.tint)
              }
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityAddTraits(chosen == file.index ? .isSelected : [])
        }
      }
      Toggle("Keep after watching", isOn: $keepAfterWatching)
      Text(
        "Off: the cache for this torrent is deleted when playback closes. Download always keeps the file in the cache until it is saved."
      )
      .font(.caption).foregroundStyle(.secondary)
      if let error = controller.error {
        Text(error).foregroundStyle(.red).font(.caption)
      }
      HStack {
        Button("Close") { dismiss() }
        Spacer()
        Button("Download") { download() }
          .disabled(selected == nil || !controller.hasConsent)
        Button("Play Now") { play() }
          .keyboardShortcut(.defaultAction)
          .disabled(selected == nil || !controller.hasConsent)
      }
    }
    .padding(24)
    .frame(minWidth: 620, minHeight: 420, maxHeight: 600)
    .onAppear {
      keepAfterWatching = job?.keepDownload ?? false
      chosen = TorrentFile.defaultSelection(in: job?.files ?? [])?.index
    }
    .onChange(of: files.map(\.index)) { _, _ in
      if !files.contains(where: { $0.index == chosen }) {
        chosen = TorrentFile.defaultSelection(in: files)?.index
      }
    }
  }

  private func play() {
    guard let file = selected else { return }
    Task {
      await controller.setKeep(identity, keep: keepAfterWatching)
      if await controller.select(identity, file: file, play: true) { dismiss() }
    }
  }

  private func download() {
    guard let file = selected else { return }
    Task {
      if await controller.select(identity, file: file, play: false, download: true) {
        dismiss()
      }
    }
  }
}

/// One-time privacy consent. Shown when a link is added without consent, or from Settings > Review.
struct TorrentConsentSheet: View {
  @ObservedObject var controller: TorrentController
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Label("Torrent networking", systemImage: "network")
        .font(.title2.weight(.semibold))
      Text(
        "Torrent peers and trackers can see your IP address. This is not anonymous. Myra connects to torrent peers only for links you add, never on launch. Only play or download content you have permission to use."
      )
      .fixedSize(horizontal: false, vertical: true)
      if let date = controller.consentGrantedAt {
        Text("Accepted \(date.formatted(date: .abbreviated, time: .shortened)).")
          .font(.caption).foregroundStyle(.secondary)
      } else {
        Text("Not accepted. Networking starts only after you add a link.")
          .font(.caption).foregroundStyle(.secondary)
      }
      HStack {
        if controller.hasConsent {
          Button("Withdraw Consent", role: .destructive) {
            controller.withdrawConsent()
            dismiss()
          }
          Spacer()
          Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        } else {
          Button("Not Now") {
            controller.declineConsent()
            dismiss()
          }
          Spacer()
          Button("Allow and Continue") {
            controller.grantConsent()
            dismiss()
          }
          .keyboardShortcut(.defaultAction)
        }
      }
    }
    .padding(24)
    .frame(width: 480)
  }
}

/// The Discover segment: a search field with provider chips above the result rows.
private struct TorrentDiscoveryView: View {
  @ObservedObject var controller: TorrentController
  @ObservedObject var model: TorrentDiscoveryModel
  @FocusState private var searchFocused: Bool

  private var providerItems: [ChipItem<String>] {
    var items = [
      ChipItem(id: "open", title: "Open Movies"),
      ChipItem(id: "archive", title: "Internet Archive"),
    ]
    if !model.sources.isEmpty { items.append(ChipItem(id: "all", title: "All Sources")) }
    items += model.sources.map { ChipItem(id: $0.id.uuidString, title: $0.name) }
    return items
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 8) {
          SearchField(text: $model.query, prompt: "Search titles", isFocused: $searchFocused)
            .onSubmit { model.search() }
          Button("Search") { model.search() }
            .buttonStyle(MyraButtonStyle())
          if model.searching {
            ProgressView().controlSize(.small)
            Button("Cancel") { model.cancel() }
              .buttonStyle(MyraButtonStyle())
          }
        }
        ChipBar(items: providerItems, isOn: { $0 == model.selectedProvider }) { id in
          guard id != model.selectedProvider else { return }
          model.selectedProvider = id
          model.cancel()
          model.search()
        }
      }
      .padding(.horizontal, 26)
      .padding(.top, 4)
      .padding(.bottom, 14)
      if !model.failures.isEmpty {
        VStack(alignment: .leading) {
          ForEach(model.failures, id: \.self) {
            Text($0).font(.system(size: 12)).foregroundStyle(.orange)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 26)
      }
      if controller.importing {
        HStack {
          ProgressView().controlSize(.small)
          Text("Importing torrent metadata…")
          Button("Cancel") { controller.cancelImport() }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 26)
      }
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          if !model.results.isEmpty {
            RowCard(rows: model.results.map(resultRow))
          }
          if model.results.isEmpty && !model.searching {
            Text("No matching torrents. Try another title or source.")
              .font(.system(size: 13))
              .foregroundStyle(MyraColor.text2)
              .frame(maxWidth: .infinity)
              .padding(.vertical, 40)
          }
          if model.hasMore {
            Button("Load More") { model.search(more: true) }
              .buttonStyle(MyraButtonStyle())
              .disabled(model.searching)
              .padding(.top, 12)
              .frame(maxWidth: .infinity)
          }
          Text(
            "Archive license declarations are supplied by uploaders. Verify permission at the source. Sources are searched only when requested."
          )
          .font(.system(size: 12))
          .foregroundStyle(MyraColor.text3)
          .padding(.top, 12)
        }
        .padding(.horizontal, 26)
        .padding(.top, 4)
        .padding(.bottom, 30)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .alert(
      "Discovery",
      isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })
    ) {
      Button("OK") { model.error = nil }
    } message: {
      Text(model.error ?? "")
    }
  }

  /// One discovery result: its provider, size and seeders, with Play and Download both opening the add sheet.
  private func resultRow(_ item: TorrentDiscoveryItem) -> RowCardItem {
    var meta = [item.provider]
    if let size = item.size { meta.append(byteText(size)) }
    if let seeders = item.seeders { meta.append("\(seeders) seeders") }
    let busy = controller.importing || !controller.ready
    return RowCardItem(
      id: item.id, title: item.title,
      thumbnailSymbol: item.archiveID == nil ? "film.stack" : "building.columns",
      thumbnailColors: LibraryPalette.gradient(for: item.title),
      meta: meta,
      actions: [
        RowCardAction(id: "play", title: "Play", systemImage: "play.fill", style: .button) {
          guard !busy else { return }
          controller.importDiscovery(item)
        },
        RowCardAction(
          id: "download", title: "Download", systemImage: "arrow.down.to.line", style: .button
        ) {
          guard !busy else { return }
          controller.importDiscovery(item)
        },
        RowCardAction(id: "source", title: "View source", systemImage: "arrow.up.right.square") {
          NSWorkspace.shared.open(item.sourceURL)
        },
      ])
  }
}

/// Brings the playback window forward. The player owns its window; this only locates it.
@MainActor
enum TorrentPlayerWindow {
  static func bringToFront() {
    NSApp.activate(ignoringOtherApps: true)
    NSApp.windows.first { containsVideo($0.contentView) }?.makeKeyAndOrderFront(nil)
  }

  private static func containsVideo(_ view: NSView?) -> Bool {
    guard let view else { return false }
    return view is VLCVideoView || view.subviews.contains { containsVideo($0) }
  }
}

struct TorrentSettingsSection: View {
  @ObservedObject var controller: TorrentController
  @State private var showReview = false
  var body: some View {
    SettingsGroup(title: "Privacy") {
      SettingsRow(
        title: "Torrent networking",
        detail: controller.consentGrantedAt.map {
          "Agreed \($0.formatted(date: .abbreviated, time: .omitted)). Peers connect only after you add a link."
        } ?? "Not agreed yet. You are asked once, when you add a link."
      ) {
        Button("Review…") { showReview = true }
          .buttonStyle(MyraButtonStyle())
      }
    }
    SettingsGroup(
      title: "Streaming",
      note:
        "The cache is separate from your library and HTTP downloads. Active and kept files are protected. BitTorrent may upload verified pieces while downloading even when seeding is off."
    ) {
      SettingsRow(title: "Stream cache limit") {
        SettingsSelect(
          title: "Stream cache limit", selection: $controller.preferences.cacheLimitGB,
          options: SettingsChoices.numbers(
            [5, 10, 20, 50, 100, 200, 500], current: controller.preferences.cacheLimitGB,
            title: { "\($0) GB" }))
      }
      SettingsToggleRow(
        title: "Seed after download", detail: "Off by default",
        isOn: $controller.preferences.seedAfterCompletion)
      SettingsRow(title: "Upload limit") {
        SettingsSelect(
          title: "Upload limit", selection: $controller.preferences.uploadLimitKB,
          options: SettingsChoices.numbers(
            [0, 100, 250, 500, 1000, 2000, 5000], current: controller.preferences.uploadLimitKB,
            title: { $0 == 0 ? "Unlimited" : "\($0) KB/s" }))
      }
    }
    .onChange(of: controller.preferences) { _, _ in
      guard controller.ready else { return }
      Task { await controller.savePreferences() }
    }
    .sheet(isPresented: $showReview) {
      TorrentConsentSheet(controller: controller)
    }
    TorznabSettingsSection(model: controller.discovery, ready: controller.ready)
  }
}

private struct TorznabSettingsSection: View {
  @ObservedObject var model: TorrentDiscoveryModel
  var ready: Bool
  @State private var name = ""
  @State private var endpoint = ""
  @State private var key = ""
  @State private var error: String?
  @State private var removing: TorznabSource?
  var body: some View {
    SettingsGroup(
      title: "Discovery Sources",
      note: "Add your own Torznab API endpoint. API keys stay in this Mac's Keychain."
    ) {
      SettingsRow(title: "Open Movies", detail: "Built in") {
        StatusPill(text: "On", style: .ok)
      }
      SettingsRow(title: "Internet Archive", detail: "Built in") {
        StatusPill(text: "On", style: .ok)
      }
      ForEach(model.sources) { source in
        SettingsRow(title: source.name, detail: source.endpoint.absoluteString) {
          Button("Remove…", role: .destructive) { removing = source }
            .buttonStyle(MyraButtonStyle())
        }
      }
      SettingsRow(title: "Source name") {
        TextField("Name", text: $name).textFieldStyle(.roundedBorder).labelsHidden().frame(width: 220)
      }
      SettingsRow(title: "Torznab endpoint", detail: "HTTPS or localhost") {
        TextField("https://…", text: $endpoint).textFieldStyle(.roundedBorder).labelsHidden().frame(width: 220)
      }
      SettingsRow(title: "API key", detail: "Optional") {
        SecureField("API key", text: $key).textFieldStyle(.roundedBorder).labelsHidden().frame(width: 220)
      }
      SettingsRow(title: "Add a Torznab source") {
        Button("Add…") {
          do {
            try model.addSource(name: name, endpoint: endpoint, key: key)
            name = ""
            endpoint = ""
            key = ""
            error = nil
          } catch {
            self.error =
              "Could not save source. Use HTTPS or local loopback HTTP, and enter the API key separately."
          }
        }
        .buttonStyle(MyraButtonStyle())
        .disabled(!ready || name.isEmpty || endpoint.isEmpty)
      }
      if let error { SettingsInlineMessage(text: error, color: .red) }
    }
    .confirmationDialog(
      "Remove discovery source?",
      isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
      titleVisibility: .visible
    ) {
      Button("Remove Source and API Key", role: .destructive) {
        if let source = removing {
          do { try model.removeSource(source) } catch { self.error = error.localizedDescription }
        }
        removing = nil
      }
      Button("Cancel", role: .cancel) { removing = nil }
    }
  }
}

import SwiftUI
import VLCKit

private func byteText(_ value: Int64) -> String {
  ByteCountFormatter.string(fromByteCount: max(0, value), countStyle: .file)
}

/// Transfers page: add-link bar, Now Streaming card, Active list, and open-video Discover tab.
struct TorrentsView: View {
  @ObservedObject var controller: TorrentController
  @State private var tab = 0
  @State private var link = ""
  @State private var removing: TorrentIdentity?

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("Torrents").font(.title2.weight(.semibold))
        Spacer()
        Picker("View", selection: $tab) {
          Text("Transfers").tag(0)
          Text("Discover").tag(1)
        }
        .pickerStyle(.segmented).frame(width: 240)
      }.padding(.horizontal, 24).padding(.vertical, 16)
      addLinkBar
      Divider()
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

  private var addLinkBar: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        TextField("Paste a magnet link or drop a .torrent file", text: $link)
          .textFieldStyle(.roundedBorder)
          .onSubmit(addLink)
        Button("Add", action: addLink).disabled(
          !controller.ready || link.trimmingCharacters(in: .whitespaces).isEmpty)
        Button("Import .torrent…") { controller.chooseTorrentFile() }.disabled(!controller.ready)
      }
      Text(
        "Torrent peers and trackers can see your IP address. This is not anonymous. Only play content you have permission to use. Networking starts only when you add a link."
      )
      .font(.caption).foregroundStyle(.secondary)
    }.padding(.horizontal, 24).padding(.vertical, 12)
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
      VStack(alignment: .leading, spacing: 16) {
        if let streaming = controller.streamingRow {
          NowStreamingCard(controller: controller, row: streaming)
        }
        if controller.transferRows.isEmpty {
          ContentUnavailableView(
            "No torrents yet", systemImage: "network",
            description: Text("Paste a magnet link, drop a .torrent file, or discover an open video."))
        } else {
          let active = controller.transferRows.filter { !$0.isStreaming }
          if !active.isEmpty {
            Text("Active").font(.headline)
            ForEach(active) { row in
              TransferRowCard(
                controller: controller, row: row,
                remove: { removing = try? TorrentIdentity(rawValue: row.id) })
            }
          }
        }
      }.padding(24)
    }
  }
}

private struct NowStreamingCard: View {
  @ObservedObject var controller: TorrentController
  let row: TorrentTransferRow
  private var transfer: TorrentTransfer { controller.transfers[row.id] ?? TorrentTransfer() }
  private var identity: TorrentIdentity? { try? TorrentIdentity(rawValue: row.id) }
  private var kept: Bool { controller.jobs.first { $0.id == row.id }?.keepDownload == true }

  var body: some View {
    HStack(alignment: .top, spacing: 16) {
      ZStack {
        RoundedRectangle(cornerRadius: 10).fill(.quaternary)
        Image(systemName: "play.rectangle.fill").font(.largeTitle).foregroundStyle(.secondary)
      }
      .frame(width: 128, height: 72)
      .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 8) {
        Text("Now Streaming").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        Text(row.name).font(.headline).lineLimit(2).help(row.name)
        ProgressView(value: min(1, max(0, transfer.streamPercent / 100)))
        Text("\(Int(transfer.streamPercent.rounded()))% verified")
          .font(.caption).foregroundStyle(.secondary)
        HStack(spacing: 14) {
          Text(row.bufferedSeconds < 5
            ? "Buffering · \(Int(row.bufferedSeconds.rounded())) s ahead"
            : "\(Int(row.bufferedSeconds.rounded())) s buffered ahead")
          Text("↓ \(byteText(row.downloadSpeed))/s")
          Text("\(row.peers) peers")
        }.font(.caption).foregroundStyle(.secondary)
        HStack {
          Button("Return to Player") { TorrentPlayerWindow.bringToFront() }
          Button(kept ? "Kept" : "Keep a Copy") {
            guard let identity else { return }
            Task { await controller.setKeep(identity, keep: true) }
          }.disabled(kept || identity == nil)
          Spacer()
        }
      }
    }
    .padding(16)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
  }
}

private struct TransferRowCard: View {
  @ObservedObject var controller: TorrentController
  let row: TorrentTransferRow
  var remove: () -> Void
  private var identity: TorrentIdentity? { try? TorrentIdentity(rawValue: row.id) }
  private var job: TorrentJob? { controller.jobs.first { $0.id == row.id } }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Image(systemName: row.isComplete ? "checkmark.circle.fill" : "arrow.down.circle")
          .font(.title2).foregroundStyle(.secondary).accessibilityHidden(true)
        VStack(alignment: .leading) {
          Text(row.name).font(.headline).lineLimit(1).help(row.name)
          Text(row.state).font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        if job?.keepDownload == true {
          Label("Kept", systemImage: "pin.fill").font(.caption).foregroundStyle(.secondary)
        }
      }
      ProgressView(
        value: row.bytesTotal > 0
          ? min(1, Double(row.bytesDone) / Double(row.bytesTotal)) : 0)
      HStack {
        Text(byteText(row.bytesDone) + " / " + byteText(row.bytesTotal))
        Text("↓ \(byteText(row.downloadSpeed))/s")
        Text("\(row.peers) peers")
        Spacer()
      }.font(.caption).foregroundStyle(.secondary)
      HStack {
        if job?.selectedFileIndex == nil {
          Button("Choose Video…") { controller.selectingJob = identity }
        }
        Button(row.isPaused ? "Resume" : "Pause") {
          guard let identity else { return }
          if row.isPaused {
            Task { await controller.resume(identity) }
          } else {
            controller.pause(identity)
          }
        }
        Button("Cancel") {
          if let identity { controller.cancel(identity) }
        }
        Spacer()
        Button("Remove…", role: .destructive, action: remove)
          .disabled(job?.keepDownload == true)
      }
    }
    .padding(14)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
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

private struct TorrentDiscoveryView: View {
  @ObservedObject var controller: TorrentController
  @ObservedObject var model: TorrentDiscoveryModel
  var body: some View {
    VStack(spacing: 12) {
      HStack {
        Picker("Source", selection: $model.selectedProvider) {
          Text("Open Movies").tag("open")
          Text("Internet Archive").tag("archive")
          if !model.sources.isEmpty { Text("All Online Sources").tag("all") }
          ForEach(model.sources) { Text($0.name).tag($0.id.uuidString) }
        }.frame(width: 230).onChange(of: model.selectedProvider) { _, _ in
          model.cancel()
          model.search()
        }
        TextField("Search titles — Return to search online", text: $model.query).textFieldStyle(
          .roundedBorder
        )
        .onSubmit { model.search() }
        Button("Search") { model.search() }
        if model.searching {
          ProgressView().controlSize(.small)
          Button("Cancel") { model.cancel() }
        }
      }.padding(.horizontal, 24).padding(.top, 16)
      if !model.failures.isEmpty {
        VStack(alignment: .leading) {
          ForEach(model.failures, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24)
      }
      if controller.importing {
        HStack {
          ProgressView().controlSize(.small)
          Text("Importing torrent metadata…")
          Button("Cancel") { controller.cancelImport() }
        }
      }
      ScrollView {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 16)], spacing: 16) {
          ForEach(model.results) { item in
            VStack(alignment: .leading, spacing: 10) {
              ZStack {
                Rectangle().fill(.quaternary)
                Image(
                  systemName: item.archiveID == nil ? "film.stack.fill" : "building.columns.fill"
                )
                .font(.system(size: 38)).foregroundStyle(.secondary)
              }.frame(height: 115).clipShape(RoundedRectangle(cornerRadius: 8))
              Text(item.title).font(.headline).lineLimit(2).frame(height: 40, alignment: .top).help(
                item.title)
              Text(item.provider).font(.caption).foregroundStyle(.secondary)
              Text(item.license).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
              if let seeders = item.seeders { Text("\(seeders) seeders").font(.caption) }
              HStack {
                Button("Play or Download…") { controller.importDiscovery(item) }.disabled(
                  controller.importing || !controller.ready)
                Spacer()
                Link(destination: item.sourceURL) { Image(systemName: "arrow.up.right.square") }
                  .help("View source")
              }
            }.padding(14).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
          }
        }.padding(24)
        if model.results.isEmpty && !model.searching {
          Text("No matching torrents. Try another title or source.").foregroundStyle(.secondary)
            .padding()
        }
        if model.hasMore {
          Button("Load More") { model.search(more: true) }.disabled(model.searching).padding(
            .bottom, 24)
        }
      }
      Text(
        "Archive license declarations are supplied by uploaders. Verify permission at the source. Sources are searched only when requested."
      )
      .font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.bottom, 10)
    }
    .alert(
      "Discovery",
      isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })
    ) {
      Button("OK") { model.error = nil }
    } message: {
      Text(model.error ?? "")
    }
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
    Section("Torrents") {
      LabeledContent("Network consent") {
        Text(
          controller.consentGrantedAt.map {
            "Accepted \($0.formatted(date: .abbreviated, time: .omitted))"
          } ?? "Not accepted")
      }
      Text("Networking starts only after you add a link. You are asked once.")
        .font(.caption).foregroundStyle(.secondary)
      Button("Review…") { showReview = true }
      Stepper(
        "Cache limit: \(controller.preferences.cacheLimitGB) GB",
        value: $controller.preferences.cacheLimitGB, in: 1...10240)
      Toggle(
        "Seed after the selected video finishes downloading",
        isOn: $controller.preferences.seedAfterCompletion)
      Text(
        "No by default. BitTorrent may upload verified pieces while downloading even when post-download seeding is disabled."
      )
      .font(.caption).foregroundStyle(.secondary)
      LabeledContent("Upload limit (KB/s; 0 = unlimited)") {
        TextField("0", value: $controller.preferences.uploadLimitKB, format: .number).frame(
          width: 100)
      }
      Text(
        "Cache is separate from your library and HTTP downloads. Active and kept files are protected. Cancel a job before removing its cache."
      )
      .font(.caption).foregroundStyle(.secondary)
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
    Section("Torrent Discovery Sources") {
      Text(
        "Built in: Open Movies and Internet Archive. Add your own Torznab API endpoint below. API keys stay in this Mac's Keychain."
      )
      .font(.caption).foregroundStyle(.secondary)
      ForEach(model.sources) { source in
        HStack {
          VStack(alignment: .leading) {
            Text(source.name)
            Text(source.endpoint.absoluteString).font(.caption).foregroundStyle(.secondary)
          }
          Spacer()
          Button("Remove…", role: .destructive) { removing = source }
        }
      }
      TextField("Source name", text: $name)
      TextField("Torznab API endpoint (HTTPS or localhost)", text: $endpoint)
      SecureField("API key (optional)", text: $key)
      Button("Add Source") {
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
      }.disabled(!ready || name.isEmpty || endpoint.isEmpty)
      if let error { Text(error).foregroundStyle(.red).font(.caption) }
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

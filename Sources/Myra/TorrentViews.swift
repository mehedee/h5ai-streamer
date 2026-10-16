import SwiftUI

struct TorrentsView: View {
  @ObservedObject var controller: TorrentController
  @State private var tab = 0
  @State private var magnet = ""
  @State private var removing: TorrentIdentity?
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("Torrents").font(.title2.weight(.semibold))
        Spacer()
        Picker("View", selection: $tab) {
          Text("Discovery").tag(0)
          Text("Transfers").tag(1)
        }
        .pickerStyle(.segmented).frame(width: 240)
      }.padding(.horizontal, 24).padding(.vertical, 16)
      HStack {
        TextField("Paste a magnet link", text: $magnet).textFieldStyle(.roundedBorder)
          .onSubmit { addMagnet() }
        Button("Add Magnet", action: addMagnet).disabled(
          !controller.ready || !controller.networkAllowed || magnet.isEmpty)
        Button("Import .torrent…") { controller.chooseTorrentFile() }.disabled(!controller.ready)
      }.padding(.horizontal, 24).padding(.bottom, 12)
      VStack(alignment: .leading, spacing: 5) {
        Text(
          "Torrent peers and trackers can see your IP address. This is not anonymous. Only play content you have permission to use."
        )
        .font(.caption).foregroundStyle(.secondary)
        Toggle("Allow torrent networking for this session", isOn: $controller.networkAllowed)
          .onChange(of: controller.networkAllowed) { _, allowed in
            if !allowed { for job in controller.jobs { controller.cancel(job.identity) } }
          }
      }.padding(.horizontal, 24).padding(.bottom, 12)
      Divider()
      if tab == 0 {
        TorrentDiscoveryView(controller: controller, model: controller.discovery)
      } else {
        transferList
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
    .task { await controller.load() }
    .sheet(item: $controller.selectingJob) { id in
      TorrentFileChooser(controller: controller, identity: id)
    }
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
  private func addMagnet() {
    guard controller.networkAllowed else { return }
    let value = magnet
    Task {
      await controller.addMagnet(value)
      if controller.error == nil {
        magnet = ""
        tab = 1
      }
    }
  }
  private var transferList: some View {
    ScrollView {
      LazyVStack(spacing: 12) {
        if controller.jobs.isEmpty {
          ContentUnavailableView(
            "No torrents yet", systemImage: "network",
            description: Text("Discover an open movie, import a torrent, or paste a magnet link."))
        }
        ForEach(controller.jobs) { job in
          TorrentTransferCard(controller: controller, job: job, remove: { removing = job.identity })
        }
      }.padding(24)
    }
  }
}

private struct TorrentTransferCard: View {
  @ObservedObject var controller: TorrentController
  var job: TorrentJob
  var remove: () -> Void
  private var transfer: TorrentTransfer { controller.transfers[job.id] ?? TorrentTransfer() }
  private func bytes(_ value: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: max(0, value), countStyle: .file)
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Image(systemName: "film.stack").font(.title2)
        VStack(alignment: .leading) {
          Text(job.name).font(.headline).lineLimit(2).help(job.name)
          Text(transfer.state).foregroundStyle(.secondary).font(.caption)
        }
        Spacer()
        Toggle(
          "Keep Download",
          isOn: Binding(
            get: { job.keepDownload },
            set: { value in Task { await controller.setKeep(job.identity, keep: value) } })
        )
        .toggleStyle(.checkbox)
      }
      ProgressView(
        value: transfer.total > 0 ? min(1, Double(transfer.downloaded) / Double(transfer.total)) : 0
      )
      HStack {
        Text(bytes(transfer.downloaded) + " / " + bytes(transfer.total))
        Text("↓ " + bytes(transfer.downloadSpeed) + "/s  ↑ " + bytes(transfer.uploadSpeed) + "/s")
        Text("\(transfer.peers) peers")
        Spacer()
      }.font(.caption).foregroundStyle(.secondary)
      HStack {
        Button("Choose Video…") { controller.selectingJob = job.identity }
        Button(transfer.paused ? "Resume" : "Pause") {
          if transfer.paused {
            Task { await controller.resume(job.identity) }
          } else {
            controller.pause(job.identity)
          }
        }.disabled(!controller.networkAllowed)
        Button("Cancel") { controller.cancel(job.identity) }
        Spacer()
        Button("Remove…", role: .destructive, action: remove).disabled(job.keepDownload)
      }
    }.padding(16).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
  }
}

private struct TorrentFileChooser: View {
  @ObservedObject var controller: TorrentController
  let identity: TorrentIdentity
  @Environment(\.dismiss) private var dismiss
  private var job: TorrentJob? { controller.jobs.first { $0.identity == identity } }
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text(job?.name ?? "Choose a video").font(.title2).lineLimit(2)
        Spacer()
        Button("Done") { dismiss() }
      }
      Text(
        "Video files only · select an episode to stream. Autoplay follows natural filename order."
      )
      .font(.caption).foregroundStyle(.secondary)
      if job?.files.isEmpty != false {
        ProgressView("Resolving torrent metadata…")
        Text(
          "A magnet needs reachable peers or trackers. Cancel the transfer if it does not resolve."
        )
        .font(.caption).foregroundStyle(.secondary)
      } else {
        List(TorrentFile.playbackOrder(job?.files ?? []), id: \.index) { file in
          HStack {
            VStack(alignment: .leading) {
              Text(file.name).lineLimit(1).help(file.path)
              Text(file.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)).font(
              .caption)
            Button {
              Task { if await controller.select(identity, file: file, play: true) { dismiss() } }
            } label: {
              Label("Play", systemImage: "play.fill")
            }
            Button {
              Task { if await controller.select(identity, file: file, play: false) { dismiss() } }
            } label: {
              Label("Download", systemImage: "arrow.down.circle")
            }
          }.disabled(!controller.networkAllowed)
        }
      }
      if let error = controller.error { Text(error).foregroundStyle(.red).font(.caption) }
    }.padding(24).frame(minWidth: 700, minHeight: 350, maxHeight: 550)
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
                Rectangle().fill(.black.opacity(0.15))
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
                Button("Choose Video…") { controller.importDiscovery(item) }.disabled(
                  controller.importing || !controller.ready || !controller.networkAllowed)
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

struct TorrentSettingsSection: View {
  @ObservedObject var controller: TorrentController
  @State private var sourceName = ""
  @State private var endpoint = ""
  @State private var key = ""
  var body: some View {
    Section("Torrents") {
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
      Button("Save Torrent Settings") { Task { await controller.savePreferences() } }.disabled(
        !controller.ready)
      Text(
        "Cache is separate from your library and HTTP downloads. Active and kept files are protected. Cancel a job before removing its cache."
      )
      .font(.caption).foregroundStyle(.secondary)
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

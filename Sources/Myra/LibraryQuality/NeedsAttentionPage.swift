import SwiftUI

/// Actions the shell's header pill can request from the page that is showing.
enum ShellPageAction: Equatable {
  case newCollection, acceptConfident
}

/// Needs Attention: unmatched files, wrong matches, missing posters and duplicates, each with the
/// action that resolves it. Accepting saves a correction; no file is renamed, moved or deleted.
struct NeedsAttentionPage: View {
  @ObservedObject var store: EntertainmentStore
  @Binding var pageAction: ShellPageAction?

  @State private var items: [AttentionItem] = []
  @State private var tab: AttentionKind = .unmatched
  @State private var fixing: AttentionItem?
  @State private var analysed = false
  @State private var notice: String?

  private var visible: [AttentionItem] { items.filter { $0.kind == tab } }
  private var confident: [AttentionItem] { AttentionAnalysis.confidentItems(items) }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          Picker("Kind", selection: $tab) {
            ForEach(AttentionKind.allCases) { kind in
              Text("\(kind.title) · \(items.filter { $0.kind == kind }.count)").tag(kind)
            }
          }
          .pickerStyle(.segmented)
          .labelsHidden()
          .frame(maxWidth: 560)
          Spacer()
          Text("\(items.count) items across all tabs")
            .font(.system(size: 12)).foregroundStyle(MyraColor.text2)
        }
        .padding(.top, 14)

        if !analysed {
          ProgressView().frame(maxWidth: .infinity, minHeight: 220)
        } else if visible.isEmpty {
          ContentUnavailableView(
            "All clear", systemImage: "checkmark.circle",
            description: Text("Nothing to fix in this tab."))
            .frame(minHeight: 260)
        } else {
          VStack(spacing: 0) {
            ForEach(visible) { item in
              AttentionRow(
                item: item,
                accept: { accept(item) },
                fix: { fixing = item },
                fetchPoster: { Task { await store.enrich() } },
                keepQuality: { quality in
                  store.setTitleQuality(titleID: item.titleID, quality: quality)
                })
              if item.id != visible.last?.id { Divider() }
            }
          }
          .background(MyraColor.content, in: RoundedRectangle(cornerRadius: 10))
          .overlay(RoundedRectangle(cornerRadius: 10).stroke(MyraColor.line, lineWidth: 1))
        }

        if let notice {
          Text(notice).font(.system(size: 12)).foregroundStyle(MyraColor.text2)
        }
        Text(
          "Accepting a match saves a correction for that title. Original files are never renamed or moved."
        )
        .font(.system(size: 12)).foregroundStyle(MyraColor.text2)
        .padding(.bottom, 24)
      }
      .padding(.horizontal, HomeLayout.pageInset)
    }
    .task(id: store.projectionRevision) { await reanalyse() }
    .onChange(of: pageAction) { _, action in
      guard let action else { return }
      pageAction = nil
      if action == .acceptConfident { acceptAllConfident() }
    }
    .sheet(item: $fixing) { item in
      FixMatchSheet(item: item, store: store) { fixing = nil }
    }
  }

  private func reanalyse() async {
    let snapshot = store.catalogue
    let result = await Task.detached(priority: .utility) {
      AttentionAnalysis.items(for: snapshot)
    }.value
    items = result
    analysed = true
  }

  /// The corrections for one title: every file of it takes the guessed title, year and type.
  private func corrections(for item: AttentionItem) -> [(versionID: String, title: String, year: String?, kind: EntertainmentKind)] {
    guard let guess = item.guess,
      let title = store.catalogue.first(where: { $0.id == item.titleID })
    else { return [] }
    return title.versions.map { (versionID: $0.id, title: guess.title, year: guess.year, kind: guess.kind) }
  }

  private func accept(_ item: AttentionItem) {
    let applied = store.correctMatches(corrections(for: item))
    if applied > 0 { Task { await store.enrich() } }
    notice = applied > 0 ? "Accepted \(item.displayName)." : nil
  }

  private func acceptAllConfident() {
    let batch = confident.flatMap { corrections(for: $0) }
    let applied = store.correctMatches(batch)
    notice =
      applied > 0
      ? "Accepted \(confident.count) confident match\(confident.count == 1 ? "" : "es")."
      : "No confident matches to accept."
    if applied > 0 { Task { await store.enrich() } }
  }
}

private struct AttentionRow: View {
  let item: AttentionItem
  let accept: () -> Void
  let fix: () -> Void
  let fetchPoster: () -> Void
  let keepQuality: (String) -> Void

  private var symbol: String {
    item.kind == .duplicate ? "square.on.square" : "film"
  }

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: symbol)
        .font(.system(size: 16))
        .foregroundStyle(MyraColor.text2)
        .frame(width: 36, height: 36)
        .background(MyraColor.fill2, in: RoundedRectangle(cornerRadius: 6))
      VStack(alignment: .leading, spacing: 4) {
        Text(item.displayName).font(.system(size: 13, weight: .semibold))
        Text(item.fileNames.joined(separator: " · "))
          .font(.system(size: 11)).foregroundStyle(MyraColor.text2)
          .lineLimit(2).truncationMode(.middle)
        HStack(spacing: 8) {
          Text(item.sourceNames.joined(separator: ", "))
          if let guess = item.guess {
            Text("Best guess: \(guess.title)\(guess.year.map { " (\($0))" } ?? "")")
            Text("\(guess.confidence)% sure").foregroundStyle(item.isConfident ? MyraColor.text : .orange)
          }
        }
        .font(.system(size: 11)).foregroundStyle(MyraColor.text2)
        Text(item.note).font(.system(size: 11)).foregroundStyle(MyraColor.text2)
      }
      Spacer(minLength: 8)
      actions
    }
    .padding(12)
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder private var actions: some View {
    switch item.kind {
    case .unmatched:
      HStack(spacing: 6) {
        if item.guess?.year != nil {
          Button("Accept", action: accept).buttonStyle(MyraButtonStyle(prominent: true))
        }
        Button("Choose…", action: fix).buttonStyle(MyraButtonStyle())
      }
    case .wrongMatch:
      Button("Choose…", action: fix).buttonStyle(MyraButtonStyle())
    case .missingPoster:
      Button("Fetch Poster", action: fetchPoster).buttonStyle(MyraButtonStyle())
    case .duplicate:
      Menu("Keep Best…") {
        ForEach(qualities, id: \.self) { quality in
          Button("Always use \(quality)") { keepQuality(quality) }
        }
      }
      .fixedSize()
    }
  }

  private var qualities: [String] {
    Array(Set(item.fileNames.compactMap { name -> String? in
      let tokens = EntertainmentVersion.qualityTokens(in: name)
        .compactMap { SmartCollectionRules.resolution(of: $0) }
      return tokens.max { (Int($0.dropLast()) ?? 0) < (Int($1.dropLast()) ?? 0) }
    })).sorted { (Int($0.dropLast()) ?? 0) > (Int($1.dropLast()) ?? 0) }
  }
}

/// Sets the title, year and type for every file of one title.
private struct FixMatchSheet: View {
  let item: AttentionItem
  @ObservedObject var store: EntertainmentStore
  let done: () -> Void

  @State private var title: String
  @State private var year: String
  @State private var kind: EntertainmentKind
  @State private var message: String?

  init(item: AttentionItem, store: EntertainmentStore, done: @escaping () -> Void) {
    self.item = item
    self.store = store
    self.done = done
    let guess = item.guess
    _title = State(initialValue: guess?.title ?? item.displayName)
    _year = State(initialValue: guess?.year ?? "")
    _kind = State(initialValue: guess?.kind ?? .movie)
  }

  private var versionIDs: [String] {
    store.catalogue.first { $0.id == item.titleID }?.versions.map(\.id) ?? []
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Fix the match").font(.title2.bold())
      Text(item.fileNames.joined(separator: "\n"))
        .font(.caption).foregroundStyle(.secondary).lineLimit(4)
      Form {
        TextField("Title", text: $title)
        TextField("Year (optional)", text: $year)
        Picker("Type", selection: $kind) {
          Text("Movie").tag(EntertainmentKind.movie)
          Text("Series").tag(EntertainmentKind.series)
        }
      }
      if let message {
        Text(message).font(.caption).foregroundStyle(.orange)
      }
      HStack {
        Spacer()
        Button("Cancel", action: done).keyboardShortcut(.cancelAction)
        Button("Save") {
          let trimmedYear = year.trimmingCharacters(in: .whitespaces)
          let entries = versionIDs.map {
            (versionID: $0, title: title, year: trimmedYear.isEmpty ? nil : trimmedYear, kind: kind)
          }
          let applied = store.correctMatches(entries)
          if applied == 0 {
            message = "Enter a title, and a four-digit year if you give one."
          } else {
            Task { await store.enrich() }
            done()
          }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
      }
    }
    .padding(24)
    .frame(width: 480)
  }
}

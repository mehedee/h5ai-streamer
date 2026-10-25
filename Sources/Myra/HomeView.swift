import AppKit
import SwiftUI

/// Discovery is read from the local catalogue; remote enrichment is a separate, bounded operation.
struct HomeView: View {
  @ObservedObject var coordinator: AppCoordinator
  @ObservedObject var store: EntertainmentStore
  @State private var query = ""
  @State private var genre = ""
  @State private var language = ""
  @State private var year = ""
  @State private var source = ""
  @State private var minimumRating = 0.0
  @State private var hideWatched = false
  @State private var details: EntertainmentTitle?
  @State private var choosing: EntertainmentTitle?
  @State private var pendingChoice: EntertainmentTitle?
  @State private var showingCollections = false
  @State private var confirmingClearContinueWatching = false
  @State private var showingTransfer = false
  @State private var pickPresentation: EntertainmentPickPresentation?
  @State private var showingAI = false
  @State private var aiFeature: MyraAIFeature = .smartPick
  @State private var aiTitle: EntertainmentTitle?
  @State private var pendingAI = false
  @State private var randomPick: EntertainmentTitle?
  @State private var randomPickFilters = "your current filters"
  @State private var expandedShelves: Set<String> = []
  @State private var mood: MyraMood?
  @State private var tonight: [MyraRecommendation] = []
  @State private var tonightIndex = 0
  @State private var tonightHeadline = ""
  @State private var showingWhy = false
  @State private var showingFilters = false
  @State private var aiPrompt = ""
  @State private var showingCustomise = false
  @FocusState private var searchFocused: Bool
  @Environment(\.myraAccent) private var accent

  @State private var prepared = HomeCatalogueProjection()
  @State private var preparedFilter: HomeCatalogueFilter?
  private static let projectionWorker = HomeProjectionWorker()
  private var filter: HomeCatalogueFilter {
    .init(
      query: query, genre: genre, language: language, year: year, source: source,
      minimumRating: minimumRating, hideWatched: hideWatched, revision: store.projectionRevision)
  }
  private var filtered: [EntertainmentTitle] { prepared.filtered }
  private var genres: [String] { prepared.genres }
  private var languages: [String] { prepared.languages }
  private var years: [String] { prepared.years }
  private var sources: [String] { prepared.sources }
  private var ratedMovies: [EntertainmentTitle] { prepared.movies }
  private var recommendedSeries: [EntertainmentTitle] { prepared.series }
  private var latest: [EntertainmentTitle] { prepared.latest }
  private var watchlist: [EntertainmentTitle] { prepared.watchlist }
  private var automaticShelves: [HomeAutomaticShelf] { prepared.shelves }

  init(
    coordinator: AppCoordinator, store: EntertainmentStore, initialQuery: String = "",
    initialMood: MyraMood? = nil
  ) {
    self.coordinator = coordinator
    self.store = store
    _query = State(initialValue: initialQuery)
    _mood = State(initialValue: initialMood)
  }

  var body: some View {
    ScrollView {
      ScrollViewReader { proxy in
      VStack(alignment: .leading, spacing: 24) {
        if activeFilterCount > 0 { activeFilterSummary }
        if HomeAskMyra.isQuestion(query) { askMyraRow }
        if let message = store.errorMessage {
          HStack {
            Image(systemName: "exclamationmark.triangle")
            Text(message)
            Spacer()
          }
          .font(.callout).foregroundStyle(.orange)
        }
        if store.catalogue.isEmpty {
          ContentUnavailableView(
            "Your entertainment home", systemImage: "film.stack",
            description: Text(
              "Add your directory sources in Library and refresh the index. Indexed videos will appear here."
            )
          )
          .frame(minHeight: 280)
        } else {
          if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && filtered.isEmpty
            && preparedFilter == filter
          {
            ContentUnavailableView.search(text: query)
          }
          if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            tonightSection
          }
          upNextRow(
            filtered.filter { $0.resumeVersion != nil && !store.personal.watched.contains($0.id) }
              .sorted {
                ($0.resumeVersion?.lastPlayed ?? .distantPast)
                  > ($1.resumeVersion?.lastPlayed ?? .distantPast)
              })
          if !automaticShelves.isEmpty {
            HomeBrowseByRow(
              shelves: automaticShelves,
              scrollTo: { id in withAnimation { proxy.scrollTo("shelf-\(id)", anchor: .top) } },
              customise: { showingCustomise = true })
            ForEach(automaticShelves) { shelf in
              self.shelf(
                shelf.name, subtitle: shelf.subtitle, titles: shelf.titles,
                anchor: "shelf-\(shelf.id)")
            }
          }
          shelf(
            "Top Rated Movies", subtitle: "TMDB ratings weighted by vote count • minimum 20 votes",
            titles: ratedMovies)
          shelf(
            "Series to Watch", subtitle: "Unwatched shows available in your sources",
            titles: recommendedSeries)
          shelf(
            "Latest Releases", subtitle: "Release dates from matched titles in your index",
            titles: latest)
          shelf(
            "Recently Added", subtitle: "First discovered by your local index",
            titles: prepared.recent)
          shelf("Watchlist", subtitle: "Saved for later", titles: watchlist)
          if !store.newEpisodeIDs.isEmpty {
            shelf(
              "New Episodes", subtitle: "Newly indexed episodes of shows you follow",
              titles: filtered.filter { $0.versions.contains { store.hasNewEpisode($0) } })
          }
          ForEach(store.personal.collections) { collection in
            shelf(
              collection.name, subtitle: "Personal collection",
              titles: filtered.filter { collection.titleIDs.contains($0.id) })
          }
          Text(
            "Availability reflects the latest index, and a source may be offline. Metadata provided by TMDB. Myra uses the TMDB API but is not endorsed or certified by TMDB."
          )
          .font(.caption).foregroundStyle(.secondary)
          Link(
            "TMDB attribution and information",
            destination: URL(string: "https://www.themoviedb.org")!
          ).font(.caption)
        }
      }
      }
      .padding(.horizontal, 28).padding(.bottom, 28)
    }
    .contentMargins(.top, 20, for: .scrollContent)
    .searchable(text: $query, placement: .toolbar, prompt: "Search or ask Myra")
    .modifier(SearchFocusIfAvailable(isFocused: $searchFocused))
    .onReceive(NotificationCenter.default.publisher(for: MyraCommand.notification)) { note in
      // Find in the menu focuses the search field on this page.
      if MyraCommand(notification: note) == .find { searchFocused = true }
    }
    .toolbar { homeToolbar }

    .mediaHeaderScrollEffect()
    .task(id: filter) {
      let request = filter
      let catalogue = store.catalogue
      let personal = store.personal
      do {
        try await Task.sleep(for: .milliseconds(100))
        let projection = try await Self.projectionWorker.prepare(
          catalogue, personal: personal, filter: request)
        try Task.checkCancellation()
        prepared = projection
        preparedFilter = request
      } catch is CancellationError {} catch {}
    }
    .task(
      id: TonightRequest(
        mood: mood, filter: preparedFilter, personalRevision: store.personalChangeRevision)
    ) {
      guard preparedFilter != nil else { return }
      let context = tonightContext()
      let titles = filtered
      let personal = store.personal
      let results = await Task.detached(priority: .userInitiated) {
        MyraRecommender.recommend(titles: titles, personal: personal, context: context, limit: 9)
      }.value
      guard !Task.isCancelled else { return }
      tonight = results
      tonightIndex = 0
      tonightHeadline = MyraRecommender.headline(for: context)
    }
    .sheet(item: $details, onDismiss: presentPendingChoice) { title in
      EntertainmentDetailView(
        title: title, store: store, play: { start($0) },
        aiAction: { feature, title in
          aiFeature = feature
          aiTitle = title
          pendingAI = true
          details = nil
        })
    }
    .sheet(item: $pickPresentation, onDismiss: presentPendingChoice) { pick in
      EntertainmentPickView(
        title: pick.title, store: store, filters: pick.filters,
        anotherPick: { pickSomething() }, resetFilters: { resetFilters() }, play: { start($0) })
    }
    .sheet(item: $choosing) { title in
      EntertainmentVersionChooser(title: title, store: store) { version in
        choosing = nil
        details = nil
        if version.progressSeconds >= 5 {
          coordinator.resumeVersion(version)
        } else {
          coordinator.playChosenVersion(version.media)
        }
      }
    }
    .sheet(isPresented: $showingAI, onDismiss: presentPendingChoice) {
      MyraAIWorkspaceView(
        store: store, initialFeature: aiFeature, initialTitle: aiTitle, initialPrompt: aiPrompt
      ) {
        start($0)
      }
    }
    .sheet(isPresented: $showingCollections) { EntertainmentCollectionsView(store: store) }
    .sheet(isPresented: $showingCustomise) { CustomiseHomeSheet(store: store) }
    .sheet(isPresented: $showingTransfer) {
      EntertainmentTransferView(coordinator: coordinator, store: store)
    }
    .confirmationDialog(
      "Clear Up Next?", isPresented: $confirmingClearContinueWatching,
      titleVisibility: .visible
    ) {
      Button("Clear Up Next", role: .destructive) {
        Task { await store.clearContinueWatching() }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "Remove unfinished resume entries from all sources? Your files, watched status, watchlist and collections will not be deleted. Current playback will continue."
      )
    }
  }

  private var activeFilterCount: Int {
    [genre, language, year, source].filter { !$0.isEmpty }.count + (minimumRating > 0 ? 1 : 0)
      + (hideWatched ? 1 : 0)
  }

  private var activeFilterText: String {
    var terms = [genre, language, year, source].filter { !$0.isEmpty }
    if minimumRating > 0 { terms.append("Rated \(Int(minimumRating))+") }
    if hideWatched { terms.append("Unwatched only") }
    return "Filtered: " + terms.joined(separator: " · ")
  }

  private var activeFilterSummary: some View {
    HStack(spacing: 8) {
      Image(systemName: "line.3.horizontal.decrease.circle.fill").foregroundStyle(.tint)
      Text(activeFilterText).font(.callout).lineLimit(1)
      Spacer()
      Button("Edit Filters") { showingFilters = true }
      Button("Clear Filters") { clearFilters() }
    }
    .padding(.horizontal, 12).padding(.vertical, 8)
    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
  }

  private var askMyraRow: some View {
    Button {
      askMyra()
    } label: {
      HStack(spacing: 10) {
        Image(systemName: "sparkles").foregroundStyle(.tint)
        Text("Ask Myra: “\(query)”").lineLimit(1)
        Spacer()
        Text("Opens Myra AI · nothing is sent until you ask").font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding(.horizontal, 14).padding(.vertical, 10)
      .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  @ToolbarContentBuilder private var homeToolbar: some ToolbarContent {
    ToolbarItemGroup(placement: .primaryAction) {
      Button {
        pickSomething()
      } label: {
        Label("Pick Something", systemImage: "dice").labelStyle(.titleAndIcon)
      }
      .help("Pick something to watch")
      .disabled(preparedFilter != filter || store.catalogue.isEmpty)
      Menu {
        Button("Recommend for Tonight…", systemImage: "wand.and.stars") { openAI(.smartPick) }
        Button("Ask Myra…", systemImage: "bubble.left.and.text.bubble.right") {
          openAI(.assistant)
        }
        Button("Make a Collection…", systemImage: "rectangle.stack.badge.plus") {
          openAI(.collection)
        }
      } label: {
        Label("Myra AI", systemImage: "sparkles").labelStyle(.titleAndIcon)
      }
      .help("Myra AI")
      Button {
        showingFilters.toggle()
      } label: {
        Label(
          activeFilterCount > 0 ? "Filters (\(activeFilterCount))" : "Filters",
          systemImage: activeFilterCount > 0
            ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
      }
      .help(activeFilterCount > 0 ? "\(activeFilterCount) filters active" : "Show filters")
      .popover(isPresented: $showingFilters, arrowEdge: .bottom) {
        filterInspector.frame(width: 300).frame(minHeight: 360)
      }
      Menu {
        Button(store.isEnriching ? "Updating Metadata…" : "Update Metadata") {
          Task { await store.enrich() }
        }
        .disabled(store.isEnriching || store.catalogue.isEmpty)
        Divider()
        Button("Customise Home…") { showingCustomise = true }
        Button("Manage Collections…") { showingCollections = true }
        Button("Export / Import…") { showingTransfer = true }
      } label: {
        Label("More", systemImage: "ellipsis.circle")
      }
      .help("More actions")
    }
  }

  private var filterInspector: some View {
    Form {
      Section {
        filterPicker("Genre", selection: $genre, values: genres)
        filterPicker("Language", selection: $language, values: languages)
        filterPicker("Year", selection: $year, values: years)
        filterPicker("Source", selection: $source, values: sources)
        Picker("Rating", selection: $minimumRating) {
          Text("Any Rating").tag(0.0)
          ForEach([5.0, 6, 7, 8, 9], id: \.self) { Text("\(Int($0))+ / 10").tag($0) }
        }
        Toggle("Hide watched", isOn: $hideWatched)
      } header: {
        Text("Filters")
      } footer: {
        Text("Filters apply to every shelf and to Tonight's pick. Empty shelves are hidden.")
          .font(.caption).foregroundStyle(.secondary)
      }
      Button("Clear All") { clearFilters() }.disabled(activeFilterCount == 0)
    }
    .formStyle(.grouped)
  }

  private func filterPicker(_ label: String, selection: Binding<String>, values: [String])
    -> some View
  {
    Picker(label, selection: selection) {
      Text("All").tag("")
      ForEach(values, id: \.self) { Text($0).tag($0) }
    }
  }

  private func upNextRow(_ titles: [EntertainmentTitle]) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      if !titles.isEmpty {
        HStack {
          Text("Up Next").font(.title2.bold())
          Spacer()
          Menu {
            Button("Clear Up Next…", role: .destructive) { confirmingClearContinueWatching = true }
              .disabled(store.isClearingContinueWatching)
          } label: {
            Image(systemName: "ellipsis.circle")
          }
          .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
          .accessibilityLabel("Up Next options")
        }
        ScrollView(.horizontal) {
          LazyHStack(alignment: .top, spacing: 16) {
            ForEach(titles.prefix(20)) { title in
              UpNextTile(title: title, store: store, play: { start(title) }) {
                details = title
              }
            }
          }
          .padding(.bottom, 4)
        }
        .scrollIndicators(.hidden)
      }
    }
  }

  @ViewBuilder
  private func shelf(
    _ name: String, subtitle: String, titles: [EntertainmentTitle], anchor: String? = nil
  ) -> some View {
    if HomeShelfPresentation.isVisible(count: titles.count, query: query) {
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Text(name).font(.title2.bold())
          Text("\(titles.count)").foregroundStyle(.secondary)
          Spacer()
          if name == "Continue Watching" {
            Button("Clear") { confirmingClearContinueWatching = true }
              .disabled(
                store.isClearingContinueWatching
                  || !store.catalogue.contains {
                    $0.resumeVersion != nil && !store.personal.watched.contains($0.id)
                  }
              )
              .accessibilityLabel("Clear Continue Watching")
          }
          if titles.count > 60 {
            Button(expandedShelves.contains(name) ? "Show fewer" : "Show all") {
              if !expandedShelves.insert(name).inserted { expandedShelves.remove(name) }
            }.font(.caption)
          }
        }
        Text(subtitle).font(.caption).foregroundStyle(.secondary)
        if titles.isEmpty {
          Text(
            name == "Top Rated Movies" || name == "Latest Releases"
              ? "No matched titles for these filters. Add a TMDB key in Settings and update metadata."
              : "No titles here yet. Try adjusting your filters."
          )
          .foregroundStyle(.secondary).padding(.vertical, 12)
        } else {
          ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 16) {
              ForEach(expandedShelves.contains(name) ? titles : Array(titles.prefix(60))) { title in
                EntertainmentCard(
                  title: title, store: store,
                  play: { start(title) }, details: { details = title })
              }
            }.padding(.bottom, 6)
          }
        }
      }
      .id(anchor ?? name)
    }

  }

  private func start(_ title: EntertainmentTitle, resume: Bool = true) {
    if resume, let version = title.resumeVersion {
      details = nil
      pickPresentation = nil
      showingAI = false
      coordinator.resumeVersion(version)
      return
    }
    guard !title.versions.isEmpty else { return }
    if title.versions.count == 1, let version = title.versions.first {
      details = nil
      pickPresentation = nil
      showingAI = false
      coordinator.playChosenVersion(version.media)
    } else if details != nil || pickPresentation != nil || showingAI {
      pendingChoice = title
      details = nil
      pickPresentation = nil
      showingAI = false
    } else {
      choosing = title
    }
  }

  private func weightedRating(_ title: EntertainmentTitle) -> Double {
    guard let metadata = title.metadata else { return 0 }
    let votes = Double(metadata.voteCount)
    return (votes * metadata.rating + 50 * 6.5) / (votes + 50)
  }

  private func openAI(_ feature: MyraAIFeature) {
    aiFeature = feature
    aiTitle = nil
    aiPrompt = ""
    showingAI = true
  }

  private func presentPendingChoice() {
    if pendingAI {
      pendingAI = false
      showingAI = true
      return
    }
    if let pending = pendingChoice {
      pendingChoice = nil
      choosing = pending
    }
  }

  private func clearFilters() {
    genre = ""
    language = ""
    year = ""
    source = ""
    minimumRating = 0
    hideWatched = false
  }

  private func askMyra() {
    aiFeature = .assistant
    aiTitle = nil
    aiPrompt = query
    showingAI = true
  }

  private func resetFilters() {
    query = ""
    genre = ""
    language = ""
    year = ""
    source = ""
    minimumRating = 0
    hideWatched = false
  }

  private func tonightContext(now: Date = .now) -> MyraViewingContext {
    let feedback = store.personal.recommendationFeedback ?? .init()
    // Rotating the seed daily keeps picks stable through an evening but fresh tomorrow.
    let day = UInt64(Calendar.current.ordinality(of: .day, in: .era, for: now) ?? 0)
    return MyraViewingContext(
      date: now, mood: mood, liked: feedback.liked, disliked: feedback.disliked,
      dismissed: feedback.activeDismissals(at: now), seed: day)
  }

  private var tonightPick: MyraRecommendation? {
    tonight.isEmpty ? nil : tonight[tonightIndex % tonight.count]
  }

  @ViewBuilder private var tonightSection: some View {
    VStack(alignment: .leading, spacing: 14) {
      if let pick = tonightPick { tonightBanner(pick) }
      moodChips
      if let mood {
        shelf(
          "\(mood.title) picks", subtitle: "Ranked on this Mac from your mood, time and history",
          titles: tonight.filter { $0.id != tonightPick?.id }.map(\.title))
      }
    }
  }

  private func tonightBanner(_ pick: MyraRecommendation) -> some View {
    let title = pick.title
    var facts = [title.year ?? title.kind.rawValue.capitalized]
    facts += (title.metadata?.genres ?? []).prefix(2)
    if let minutes = MyraAIContext.runtime(title) {
      facts.append(MyraRecommender.duration(minutes))
    }
    if let rating = title.metadata?.rating, rating > 0 {
      facts.append(String(format: "★ %.1f", rating))
    }
    return ZStack(alignment: .leading) {
      AsyncImage(url: title.posterURL) { image in
        image.resizable().scaledToFill().blur(radius: 30).opacity(0.7)
      } placeholder: {
        LinearGradient(
          colors: [accent.color.opacity(0.45), Color.black.opacity(0.6)],
          startPoint: .topLeading, endPoint: .bottomTrailing)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
      LinearGradient(
        colors: [.black.opacity(0.85), .black.opacity(0.45), .black.opacity(0.1)],
        startPoint: .leading, endPoint: .trailing)
      HStack(alignment: .center, spacing: 28) {
        AsyncImage(url: title.posterURL) { image in
          image.resizable().scaledToFill()
        } placeholder: {
          ZStack {
            Rectangle().fill(.white.opacity(0.12))
            Image(systemName: title.kind == .series ? "tv" : "film").font(.largeTitle)
              .foregroundStyle(.white.opacity(0.7))
          }
        }
        .frame(width: 150, height: 222).clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.5), radius: 16, y: 8)
        VStack(alignment: .leading, spacing: 10) {
          Text("Tonight's pick · \(tonightHeadline)").textCase(.uppercase)
            .font(.caption.weight(.bold)).foregroundStyle(.yellow)
          Text(title.displayName).font(.system(size: 38, weight: .bold)).lineLimit(2)
          Text(facts.joined(separator: " · ")).font(.callout).foregroundStyle(.white.opacity(0.8))
          Label(
            pick.reasons.prefix(2).joined(separator: " · "), systemImage: "sparkles"
          )
          .font(.callout).foregroundStyle(.white.opacity(0.92))
          HStack(spacing: 10) {
            Button {
              start(title)
            } label: {
              Label(title.resumeVersion == nil ? "Play" : "Resume", systemImage: "play.fill")
            }
            .buttonStyle(BannerButtonStyle(prominent: true))
            Button("Another") { tonightIndex += 1 }
              .buttonStyle(BannerButtonStyle())
              .disabled(tonight.count < 2)
            Button("Why?") { showingWhy = true }
              .buttonStyle(BannerButtonStyle())
              .popover(isPresented: $showingWhy, arrowEdge: .bottom) { TonightWhyView(pick: pick) }
            Menu {
              RecommendationFeedbackItems(titleID: title.id, store: store)
            } label: {
              Image(systemName: "hand.thumbsup")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.white.opacity(0.18), in: Capsule())
            .help("Recommendation feedback").accessibilityLabel("Recommendation feedback")
          }
          .padding(.top, 6)
        }
        .foregroundStyle(.white)
        Spacer(minLength: 0)
      }
      .padding(28)
    }
    .frame(height: 290)
    .clipShape(RoundedRectangle(cornerRadius: 18))
    .environment(\.colorScheme, .dark)
  }

  private var moodChips: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        Text("In the mood for").font(.callout).foregroundStyle(.secondary)
        ForEach(MyraMood.allCases) { item in
          let selected = mood == item
          Button {
            mood = selected ? nil : item
          } label: {
            Text(item.title).padding(.horizontal, 12).padding(.vertical, 5)
              .foregroundStyle(selected ? Color.white : Color.primary)
              .background(
                selected ? AnyShapeStyle(accent.color) : AnyShapeStyle(.quaternary),
                in: Capsule())
          }
          .buttonStyle(.plain)
          .accessibilityAddTraits(selected ? .isSelected : [])
        }
      }
    }
  }

  private func pickSomething() {
    guard preparedFilter == filter else { return }
    randomPick = EntertainmentPick.select(
      from: filtered, watched: store.personal.watched, excluding: randomPick?.id)
    randomPickFilters = filterDescription
    pickPresentation = .init(
      id: pickPresentation?.id ?? UUID(), title: randomPick, filters: randomPickFilters)
  }

  private var filterDescription: String {
    var terms = [String]()
    if !query.isEmpty { terms.append("search ‘\(query)’") }
    if !genre.isEmpty { terms.append(genre) }
    if !language.isEmpty { terms.append(language) }
    if !year.isEmpty { terms.append(year) }
    if !source.isEmpty { terms.append(source) }
    if minimumRating > 0 { terms.append("rating \(Int(minimumRating))+") }
    return terms.isEmpty ? "your current filters (all sources)" : terms.joined(separator: ", ")
  }
}

private struct EntertainmentCard: View {
  let title: EntertainmentTitle
  @ObservedObject var store: EntertainmentStore
  let play: () -> Void
  let details: () -> Void
  @State private var hovering = false
  @Environment(\.myraAccent) private var accent

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      ZStack(alignment: .bottomLeading) {
        Button(action: details) {
          AsyncImage(url: title.posterURL) { image in
            image.resizable().scaledToFill()
          } placeholder: {
            ZStack {
              Rectangle().fill(.quaternary)
              Image(systemName: title.kind == .series ? "tv" : "film").font(.largeTitle)
                .foregroundStyle(.secondary)
            }
          }
          .frame(width: 170, height: 255).clipped()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title.displayName) details")
        if let resume = title.resumeVersion, resume.duration > 0 {
          ProgressView(value: min(1, resume.progressSeconds / resume.duration))
            .tint(.white).padding(.horizontal, 10).padding(.bottom, 8)
        }
        if hovering {
          HStack {
            Button(action: play) {
              Image(systemName: "play.fill").font(.body.bold())
                .frame(width: 36, height: 36)
                .background(.white, in: Circle()).foregroundStyle(.black)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title.resumeVersion == nil ? "Play" : "Resume")
            Spacer()
            Button {
              store.toggleWatchlist(title.id)
            } label: {
              Image(
                systemName: store.personal.watchlist.contains(title.id) ? "checkmark" : "plus"
              )
              .font(.body.bold()).frame(width: 30, height: 30)
              .background(.ultraThinMaterial, in: Circle()).foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .help("Toggle Watchlist")
          }
          .padding(10)
          .frame(maxHeight: .infinity, alignment: .bottom)
          .background(
            LinearGradient(
              colors: [.clear, .black.opacity(0.65)], startPoint: .center, endPoint: .bottom)
          )
          .allowsHitTesting(true)
        }
      }
      .frame(width: 170, height: 255)
      .overlay(alignment: .topTrailing) {
        if store.personal.watched.contains(title.id) {
          Image(systemName: "checkmark.circle.fill").font(.title3)
            .symbolRenderingMode(.palette).foregroundStyle(.white, accent.color)
            .padding(8).accessibilityLabel("Watched")
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: 12))
      .overlay(
        RoundedRectangle(cornerRadius: 12).stroke(
          hovering ? accent.color : .clear, lineWidth: 3)
      )
      .onHover { hovering = $0 }
      .contextMenu { menuItems }
      HStack(spacing: 4) {
        Text(title.displayName).font(.callout.weight(.semibold)).lineLimit(1)
        Spacer(minLength: 0)
        Menu {
          menuItems
        } label: {
          Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel("More for \(title.displayName)")
      }
      HStack(spacing: 6) {
        Text(title.year ?? title.kind.rawValue.capitalized)
        if let metadata = title.metadata, metadata.rating > 0 {
          Label(String(format: "%.1f", metadata.rating), systemImage: "star.fill")
            .labelStyle(.titleAndIcon)
            .help("TMDB rating from \(metadata.voteCount) votes")
        }
      }
      .font(.caption).foregroundStyle(.secondary)
    }
    .frame(width: 170)
  }

  @ViewBuilder private var menuItems: some View {
    Button(title.resumeVersion == nil ? "Play" : "Resume", action: play)
    Button("Details and Versions", action: details)
    Button(
      store.personal.watchlist.contains(title.id) ? "Remove from Watchlist" : "Add to Watchlist"
    ) { store.toggleWatchlist(title.id) }
    Button(store.personal.watched.contains(title.id) ? "Mark Unwatched" : "Mark Watched") {
      store.toggleWatched(title.id)
    }
    if title.kind == .series {
      Button(store.personal.followed.contains(title.id) ? "Unfollow Series" : "Follow Series") {
        store.toggleFollow(title.id)
      }
    }
    if !store.personal.collections.isEmpty {
      Menu("Collections") {
        ForEach(store.personal.collections) { collection in
          Button("\(collection.titleIDs.contains(title.id) ? "✓ " : "")\(collection.name)") {
            store.toggleCollection(titleID: title.id, collectionID: collection.id)
          }
        }
      }
    }
    Divider()
    RecommendationFeedbackItems(titleID: title.id, store: store)
  }
}

/// Wide 16:9 tile for Up Next, in the style of the TV app.
private struct UpNextTile: View {
  let title: EntertainmentTitle
  @ObservedObject var store: EntertainmentStore
  let play: () -> Void
  let details: () -> Void
  @State private var hovering = false
  @Environment(\.myraAccent) private var accent

  private var resume: EntertainmentVersion? { title.resumeVersion }
  private var subtitle: String {
    var parts: [String] = []
    if let season = resume?.season, let episode = resume?.episode {
      parts.append("S\(season), E\(episode)")
    }
    if let resume, resume.duration > 0 {
      let left = max(0, Int((resume.duration - resume.progressSeconds) / 60))
      parts.append("\(MyraRecommender.duration(left)) left")
    }
    return parts.isEmpty ? (title.year ?? "") : parts.joined(separator: " · ")
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Button(action: play) {
        ZStack(alignment: .bottom) {
          AsyncImage(url: title.posterURL) { image in
            image.resizable().scaledToFill()
          } placeholder: {
            ZStack {
              Rectangle().fill(.quaternary)
              Image(systemName: title.kind == .series ? "tv" : "film").font(.largeTitle)
                .foregroundStyle(.secondary)
            }
          }
          .frame(width: 300, height: 169).clipped()
          LinearGradient(
            colors: [.clear, .black.opacity(0.6)], startPoint: .center, endPoint: .bottom)
          if hovering {
            Image(systemName: "play.fill").font(.title2.bold()).foregroundStyle(.black)
              .frame(width: 48, height: 48).background(.white, in: Circle())
              .frame(maxWidth: .infinity, maxHeight: .infinity)
          }
          if let resume, resume.duration > 0 {
            ProgressView(value: min(1, resume.progressSeconds / resume.duration))
              .tint(.white).padding(.horizontal, 12).padding(.bottom, 10)
          }
        }
        .frame(width: 300, height: 169)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
          RoundedRectangle(cornerRadius: 12).stroke(
            hovering ? accent.color : .clear, lineWidth: 3))
      }
      .buttonStyle(.plain)
      .onHover { hovering = $0 }
      .accessibilityLabel("Resume \(title.displayName)")
      .contextMenu {
        Button("Resume", action: play)
        Button("Details and Versions", action: details)
        Button("Mark Watched") { store.toggleWatched(title.id) }
      }
      Text(title.displayName).font(.callout.weight(.semibold)).lineLimit(1)
      Text(subtitle).font(.caption).foregroundStyle(.secondary)
    }
    .frame(width: 300)
  }
}

private struct BannerButtonStyle: ButtonStyle {
  var prominent = false
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.body.weight(.semibold))
      .padding(.horizontal, prominent ? 20 : 16).padding(.vertical, 9)
      .foregroundStyle(prominent ? Color.black : Color.white)
      .background(
        prominent ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.white.opacity(0.18)),
        in: Capsule()
      )
      .opacity(configuration.isPressed ? 0.75 : 1)
      .contentShape(Capsule())
  }
}

enum HomeAskMyra {
  /// A multi-word sentence reads as a request rather than a title search.
  static func isQuestion(_ query: String) -> Bool {
    let words = query.split(whereSeparator: \.isWhitespace)
    return words.count >= 3
  }
}

struct TonightWhyView: View {
  let pick: MyraRecommendation

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Why \(pick.title.displayName)?").font(.headline)
      if pick.reasons.isEmpty {
        Text("A well-rated unwatched title from your library.")
      }
      ForEach(pick.reasons, id: \.self) { Label($0, systemImage: "checkmark") }
      Text(
        "Ranked on this Mac from your mood, the time of day and your viewing history. No AI request was made."
      )
      .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
    .padding(16).frame(width: 300)
  }
}

private struct TonightRequest: Hashable {
  var mood: MyraMood?
  var filter: HomeCatalogueFilter?
  var personalRevision: Int
}

/// Feedback items shared by the Tonight banner and card menus; saved in personal data.
struct RecommendationFeedbackItems: View {
  let titleID: String
  @ObservedObject var store: EntertainmentStore

  var body: some View {
    let feedback = store.personal.recommendationFeedback
    Button {
      store.react(.like, to: titleID)
    } label: {
      Label(
        "More Like This",
        systemImage: feedback?.liked.contains(titleID) == true
          ? "hand.thumbsup.fill" : "hand.thumbsup")
    }
    Button {
      store.react(.dislike, to: titleID)
    } label: {
      Label(
        "Less Like This",
        systemImage: feedback?.disliked.contains(titleID) == true
          ? "hand.thumbsdown.fill" : "hand.thumbsdown")
    }
    Button {
      store.react(.notTonight, to: titleID)
    } label: {
      Label("Not Tonight", systemImage: "moon.zzz")
    }
  }
}

enum HomeShelfPresentation {
  static func isVisible(count: Int, query: String) -> Bool {
    count > 0 || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
}

struct HomeCatalogueFilter: Hashable, Sendable {
  var query: String
  var genre: String
  var language: String
  var year: String
  var source: String
  var minimumRating: Double
  var hideWatched: Bool
  var revision: Int
}

struct HomeCatalogueProjection: Sendable {
  var filtered: [EntertainmentTitle] = []
  var movies: [EntertainmentTitle] = []
  var series: [EntertainmentTitle] = []
  var latest: [EntertainmentTitle] = []
  var recent: [EntertainmentTitle] = []
  var watchlist: [EntertainmentTitle] = []
  var genres: [String] = []
  var languages: [String] = []
  var years: [String] = []
  var sources: [String] = []
  /// Automatic shelves built from the filtered titles, in the user's arrangement, hidden shelves removed.
  var shelves: [HomeAutomaticShelf] = []
}

actor HomeProjectionWorker {
  func prepare(
    _ catalogue: [EntertainmentTitle], personal: EntertainmentPersonalData,
    filter: HomeCatalogueFilter
  ) throws -> HomeCatalogueProjection {
    var result = HomeCatalogueProjection()
    var genres: Set<String> = []
    var languages: Set<String> = []
    var years: Set<String> = []
    var sources: Set<String> = []
    for title in catalogue {
      try Task.checkCancellation()
      genres.formUnion(title.metadata?.genres ?? [])
      if let language = title.metadata?.language { languages.insert(language) }
      if let year = title.year { years.insert(year) }
      for version in title.versions { sources.insert(version.media.categoryName) }
      guard
        filter.query.isEmpty || title.displayName.localizedCaseInsensitiveContains(filter.query),
        filter.genre.isEmpty || title.metadata?.genres.contains(filter.genre) == true,
        filter.language.isEmpty || title.metadata?.language == filter.language,
        filter.year.isEmpty || title.year == filter.year
          || title.metadata?.releaseDate?.hasPrefix(filter.year) == true,
        filter.source.isEmpty
          || title.versions.contains(where: { $0.media.categoryName == filter.source }),
        filter.minimumRating == 0 || (title.metadata?.rating ?? 0) >= filter.minimumRating,
        !filter.hideWatched || !personal.watched.contains(title.id)
      else { continue }
      result.filtered.append(title)
      if title.kind == .movie && (title.metadata?.voteCount ?? 0) >= 20 {
        result.movies.append(title)
      }
      if title.kind == .series && !personal.watched.contains(title.id) {
        result.series.append(title)
      }
      if title.latestReleaseDate != nil { result.latest.append(title) }
      if personal.watchlist.contains(title.id) { result.watchlist.append(title) }
    }
    func score(_ title: EntertainmentTitle) -> Double {
      guard let metadata = title.metadata else { return 0 }
      let votes = Double(metadata.voteCount)
      return (votes * metadata.rating + 50 * 6.5) / (votes + 50)
    }
    result.movies.sort { score($0) > score($1) }
    result.series.sort { score($0) > score($1) }
    result.latest.sort { ($0.latestReleaseDate ?? "") > ($1.latestReleaseDate ?? "") }
    result.recent = result.filtered.sorted { $0.latestDiscovered > $1.latestDiscovered }
    result.genres = genres.sorted()
    result.languages = languages.sorted()
    result.years = years.sorted(by: >)
    result.sources = sources.sorted()
    result.shelves = HomeShelfBuilder.shelves(
      from: result.filtered, preferences: personal.homeCategories ?? HomeCategoryPreferences())
    return result
  }
}

/// The sheet receives the chosen title atomically, including on its first presentation.
struct EntertainmentPickPresentation: Identifiable {
  let id: UUID
  let title: EntertainmentTitle?
  let filters: String
}

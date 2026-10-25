import AppKit
import SwiftUI

/// Measurements taken from the approved Home section of the redesign preview.
enum HomeLayout {
  /// `.content` side padding.
  static let pageInset: CGFloat = 26
  /// `.hero` height and corner radius.
  static let heroHeight: CGFloat = 290
  static let heroRadius: CGFloat = 18
  /// `.shelf` column width for posters, and `.shelf.wide` for Up Next stills.
  static let posterWidth: CGFloat = 148
  static let stillWidth: CGFloat = 260
  /// Gap between shelf columns.
  static let shelfSpacing: CGFloat = 16
  /// Left inset so the first Up Next card is not clipped by the scroll edge.
  static let upNextLeadingInset: CGFloat = 16
  /// A shelf shows this many cards until "See All" expands it.
  static let shelfPreviewLimit = 60

  static func visibleCount(total: Int, expanded: Bool) -> Int {
    expanded ? total : min(total, shelfPreviewLimit)
  }

  static func seeAllTitle(expanded: Bool) -> String {
    expanded ? "Show Fewer" : "See All"
  }

  /// A filter chip shows its selected value once one is chosen, otherwise its label.
  static func filterChipTitle(label: String, selection: String) -> String {
    selection.isEmpty ? label : selection
  }

  static func backdropCandidates(_ title: EntertainmentTitle) -> [ArtworkCandidate] {
    var candidates: [ArtworkCandidate] = []
    if let backdrop = title.metadata?.backdropURL {
      candidates.append(.image(.tmdbBackdrop, backdrop))
    }
    if let poster = title.posterURL {
      candidates.append(.image(.tmdbPoster, poster))
    }
    return candidates.isEmpty ? [.titleCard] : candidates
  }

  static func posterCandidates(_ title: EntertainmentTitle) -> [ArtworkCandidate] {
    guard let poster = title.posterURL else { return [.titleCard] }
    return [.image(.tmdbPoster, poster)]
  }
}

/// Discovery is read from the local catalogue; remote enrichment is a separate, bounded operation.
struct HomeView: View {
  @ObservedObject var coordinator: AppCoordinator
  @ObservedObject var store: EntertainmentStore
  /// Shared with the shell's toolbar search field.
  private var query: String { coordinator.searchText }
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

  init(coordinator: AppCoordinator, store: EntertainmentStore, initialMood: MyraMood? = nil) {
    self.coordinator = coordinator
    self.store = store
    _mood = State(initialValue: initialMood)
  }

  var body: some View {
    ScrollView {
      ScrollViewReader { proxy in
        VStack(alignment: .leading, spacing: 0) {
          if HomeAskMyra.isQuestion(query) { askMyraRow.padding(.top, 26) }
          if let message = store.errorMessage {
            HStack {
              Image(systemName: "exclamationmark.triangle")
              Text(message)
              Spacer()
            }
            .font(.callout).foregroundStyle(.orange)
            .padding(.top, 26)
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
            HomeBrowseByRow(
              shelves: automaticShelves,
              scrollTo: { id in withAnimation { proxy.scrollTo("shelf-\(id)", anchor: .top) } },
              customise: { showingCustomise = true }
            )
            .padding(.top, 26)
            ForEach(automaticShelves) { shelf in
              self.shelf(
                shelf.name, subtitle: shelf.subtitle, titles: shelf.titles,
                anchor: "shelf-\(shelf.id)")
            }
            filterRow.padding(.top, 30)
            shelf(
              "Top Rated Movies", subtitle: "TMDB ratings weighted by vote count • minimum 20 votes",
              titles: ratedMovies)
            shelf(
              "Recently Added", subtitle: "First discovered by your local index",
              titles: prepared.recent)
            shelf(
              "Series to Watch", subtitle: "Unwatched shows available in your sources",
              titles: recommendedSeries)
            shelf(
              "Latest Releases", subtitle: "Release dates from matched titles in your index",
              titles: latest)
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
            .padding(.top, 30)
            Link(
              "TMDB attribution and information",
              destination: URL(string: "https://www.themoviedb.org")!
            ).font(.caption)
          }
        }
        .padding(.horizontal, HomeLayout.pageInset)
        .padding(.bottom, 30)
      }
    }
    .contentMargins(.top, 4, for: .scrollContent)
    .modifier(SearchFocusIfAvailable(isFocused: $searchFocused))
    .onReceive(NotificationCenter.default.publisher(for: MyraCommand.notification)) { note in
      // The shell's page actions post these commands; Home runs its own Pick and Ask actions.
      guard let command = MyraCommand(notification: note) else { return }
      switch command {
      case .find: searchFocused = true
      case .pickSomething: pickSomething()
      case .askMyra: askMyra()
      default: break
      }
    }
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

  /// Visible filter chips (`.chips` after the section head). Each chip opens its menu or toggles.
  private var filterRow: some View {
    HStack(alignment: .center, spacing: 8) {
      FlowLayout(spacing: 6) {
        filterMenu("Genre", selection: $genre, values: genres)
        filterMenu("Language", selection: $language, values: languages)
        filterMenu("Year", selection: $year, values: years)
        filterMenu("Source", selection: $source, values: sources)
        Menu {
          Picker("Rating", selection: $minimumRating) {
            Text("Any Rating").tag(0.0)
            ForEach([5.0, 6, 7, 8, 9], id: \.self) { Text("\(Int($0))+ / 10").tag($0) }
          }
        } label: {
          HomeChip(
            title: minimumRating > 0 ? "\(Int(minimumRating))+ rating" : "Rating",
            isOn: minimumRating > 0, caret: true)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel("Rating filter")
        Button {
          hideWatched.toggle()
        } label: {
          HomeChip(title: "Hide watched", isOn: hideWatched)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(hideWatched ? .isSelected : [])
      }
      Spacer(minLength: 8)
      Button("Reset") { clearFilters() }
        .buttonStyle(.plain)
        .foregroundStyle(accent.color)
        .disabled(activeFilterCount == 0)
      Menu {
        Button("Recommend for Tonight…") { openAI(.smartPick) }
        Button("Ask Myra…") { openAI(.assistant) }
        Button("Make a Collection…") { openAI(.collection) }
        Divider()
        Button(store.isEnriching ? "Updating Metadata…" : "Update Metadata") {
          Task { await store.enrich() }
        }
        .disabled(store.isEnriching || store.catalogue.isEmpty)
        Button("Manage Collections…") { showingCollections = true }
        Button("Export / Import…") { showingTransfer = true }
      } label: {
        Image(systemName: "ellipsis.circle")
      }
      .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
      .help("More actions")
      .accessibilityLabel("More actions")
    }
    .padding(.bottom, 4)
  }

  private func filterMenu(_ label: String, selection: Binding<String>, values: [String])
    -> some View
  {
    Menu {
      Picker(label, selection: selection) {
        Text("All").tag("")
        ForEach(values, id: \.self) { Text($0).tag($0) }
      }
    } label: {
      HomeChip(
        title: HomeLayout.filterChipTitle(label: label, selection: selection.wrappedValue),
        isOn: !selection.wrappedValue.isEmpty, caret: true)
    }
    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    .accessibilityLabel("\(label) filter")
  }

  /// Up Next: wide 16:9 stills with a 16pt inset at the leading edge.
  private func upNextRow(_ titles: [EntertainmentTitle]) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      if !titles.isEmpty {
        SectionHeader(title: "Up Next", count: titles.count)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text("Resume unfinished movies and the next episode of shows you follow")
            .font(.system(size: 12)).foregroundStyle(MyraColor.text2)
          Spacer(minLength: 8)
          Menu {
            Button("Clear Up Next…", role: .destructive) { confirmingClearContinueWatching = true }
              .disabled(store.isClearingContinueWatching)
          } label: {
            Image(systemName: "ellipsis.circle")
          }
          .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
          .accessibilityLabel("Up Next options")
        }
        .padding(.bottom, 12)
        ScrollView(.horizontal) {
          LazyHStack(alignment: .top, spacing: HomeLayout.shelfSpacing) {
            ForEach(titles.prefix(20)) { title in
              HomeStillCard(title: title, store: store, play: { start(title) }) {
                details = title
              }
              .frame(width: HomeLayout.stillWidth)
            }
          }
          .padding(.leading, HomeLayout.upNextLeadingInset)
          .padding(.bottom, 6)
        }
        .scrollIndicators(.hidden)
      }
    }
  }

  /// A titled shelf of posters with its count and a "See All" control. Empty shelves are hidden.
  @ViewBuilder
  private func shelf(
    _ name: String, subtitle: String, titles: [EntertainmentTitle], anchor: String? = nil
  ) -> some View {
    if !titles.isEmpty {
      let canExpand = titles.count > HomeLayout.shelfPreviewLimit
      let expanded = canExpand && expandedShelves.contains(name)
      let toggleExpanded: () -> Void = {
        if !expandedShelves.insert(name).inserted { expandedShelves.remove(name) }
      }
      VStack(alignment: .leading, spacing: 0) {
        // "See All" reveals the cards beyond the preview limit; shelves within it show every card.
        SectionHeader(
          title: name, count: titles.count,
          actionTitle: HomeLayout.seeAllTitle(expanded: expanded),
          action: toggleExpanded
        )
        Text(subtitle)
          .font(.system(size: 12)).foregroundStyle(MyraColor.text2)
          .padding(.bottom, 12)
        ScrollView(.horizontal) {
          LazyHStack(alignment: .top, spacing: HomeLayout.shelfSpacing) {
            ForEach(
              titles.prefix(HomeLayout.visibleCount(total: titles.count, expanded: expanded))
            ) { title in
              HomePosterCard(
                title: title, store: store,
                play: { start(title) }, details: { details = title })
                .frame(width: HomeLayout.posterWidth, alignment: .topLeading)
            }
          }
          .padding(.bottom, 6)
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
    coordinator.searchText = ""
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
    if let pick = tonightPick { tonightBanner(pick) }
    moodRow.padding(.top, 18)
    if let mood {
      shelf(
        "\(mood.title) picks", subtitle: "Ranked on this Mac from your mood, time and history",
        titles: tonight.filter { $0.id != tonightPick?.id }.map(\.title)
      )
    }
  }

  /// The `.hero` banner: blurred artwork under a dark gradient, clipped to its own frame.
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
    return ZStack(alignment: .bottomLeading) {
      // The black base and the clip confine the blurred artwork to the banner frame.
      Color.black
        .overlay {
          FallbackArtworkView(
            title: title.displayName, candidates: HomeLayout.backdropCandidates(title)
          )
          .blur(radius: 30)
          .opacity(0.7)
        }
        .clipped()
      LinearGradient(
        stops: [
          .init(color: .black.opacity(0.55), location: 0),
          .init(color: .black.opacity(0.1), location: 0.65),
        ],
        startPoint: .leading, endPoint: .trailing)
      VStack(alignment: .leading, spacing: 0) {
        Text("Tonight's pick · \(tonightHeadline)")
          .font(.system(size: 11, weight: .semibold))
          .tracking(0.88)
          .textCase(.uppercase)
          .foregroundStyle(.white.opacity(0.85))
        Text(title.displayName)
          .font(.system(size: 32, weight: .bold))
          .tracking(-0.64)
          .lineLimit(2)
          .padding(.top, 6).padding(.bottom, 4)
        Text(facts.joined(separator: " · "))
          .font(.system(size: 12))
          .foregroundStyle(.white.opacity(0.9))
          .padding(.bottom, 14)
        Label(pick.reasons.prefix(2).joined(separator: " · "), systemImage: "sparkles")
          .font(.system(size: 13))
          .foregroundStyle(.white.opacity(0.9))
          .padding(.bottom, 16)
        HStack(spacing: 8) {
          Button {
            start(title)
          } label: {
            Label(title.resumeVersion == nil ? "Play" : "Resume", systemImage: "play.fill")
          }
          .buttonStyle(HeroButtonStyle(prominent: true))
          Button("Another") { tonightIndex += 1 }
            .buttonStyle(HeroButtonStyle())
            .disabled(tonight.count < 2)
          Button("Why?") { showingWhy = true }
            .buttonStyle(HeroButtonStyle())
            .popover(isPresented: $showingWhy, arrowEdge: .bottom) { TonightWhyView(pick: pick) }
          Menu {
            RecommendationFeedbackItems(titleID: title.id, store: store)
          } label: {
            Image(systemName: "hand.thumbsup")
              .font(.system(size: 13))
              .foregroundStyle(.white)
              .padding(.horizontal, 12).padding(.vertical, 6)
              .background(Color.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
              .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.25), lineWidth: 1))
          }
          .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
          .help("Recommendation feedback").accessibilityLabel("Recommendation feedback")
        }
      }
      .foregroundStyle(.white)
      .padding(.leading, 28).padding(.trailing, 28).padding(.bottom, 26)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxWidth: .infinity)
    .frame(height: HomeLayout.heroHeight)
    .clipShape(RoundedRectangle(cornerRadius: HomeLayout.heroRadius))
    .environment(\.colorScheme, .dark)
  }

  /// `.moods`: the label, then the mood chips on one wrapping row. The selected chip uses the accent.
  private var moodRow: some View {
    HStack(alignment: .center, spacing: 10) {
      Text("In the mood for")
        .font(.system(size: 13)).foregroundStyle(MyraColor.text2)
      FlowLayout(spacing: 6) {
        ForEach(MyraMood.allCases) { item in
          let selected = mood == item
          Button {
            mood = selected ? nil : item
          } label: {
            HomeChip(title: item.title, isOn: selected)
          }
          .buttonStyle(.plain)
          .accessibilityAddTraits(selected ? .isSelected : [])
        }
      }
    }
  }

  private func pickSomething() {
    guard preparedFilter == filter, !store.catalogue.isEmpty else { return }
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

/// A poster card (`.card`): a click opens details, and the context menu holds the title actions.
private struct HomePosterCard: View {
  let title: EntertainmentTitle
  @ObservedObject var store: EntertainmentStore
  let play: () -> Void
  let details: () -> Void

  private var subtitle: String {
    [title.year ?? title.kind.rawValue.capitalized, title.metadata?.genres.first]
      .compactMap { $0 }
      .joined(separator: " · ")
  }

  var body: some View {
    Button(action: details) {
      MediaCard(
        title: title.displayName, subtitle: subtitle,
        posterURL: title.posterURL,
        rating: (title.metadata?.rating ?? 0) > 0 ? title.metadata?.rating : nil,
        watched: store.personal.watched.contains(title.id))
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(title.displayName) details")
    .contextMenu { menuItems }
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

/// A 16:9 still (`.still`) for Up Next: artwork, a play button on hover, a progress bar at the bottom.
private struct HomeStillCard: View {
  let title: EntertainmentTitle
  @ObservedObject var store: EntertainmentStore
  let play: () -> Void
  let details: () -> Void
  @State private var hovering = false

  private var resume: EntertainmentVersion? { title.resumeVersion }
  private var progress: Double? {
    guard let resume, resume.duration > 0 else { return nil }
    return min(1, resume.progressSeconds / resume.duration)
  }
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
        Color.clear
          .aspectRatio(16.0 / 9.0, contentMode: .fit)
          .overlay {
            FallbackArtworkView(
              title: title.displayName, candidates: HomeLayout.posterCandidates(title))
          }
          .overlay(alignment: .bottomLeading) {
            VStack(alignment: .leading, spacing: 10) {
              Text(title.displayName)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
                .lineLimit(1)
              if let progress {
                ProgressBarView(fraction: progress, track: .white.opacity(0.3), tint: .white)
              }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, progress == nil ? 10 : 8)
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          .overlay {
            Image(systemName: "play.fill")
              .font(.system(size: 18))
              .foregroundStyle(.white)
              .frame(width: 44, height: 44)
              .background(.ultraThinMaterial, in: Circle())
              .background(Color.white.opacity(0.25), in: Circle())
              .opacity(hovering ? 1 : 0)
          }
          .clipShape(RoundedRectangle(cornerRadius: 10))
          .contentShape(RoundedRectangle(cornerRadius: 10))
      }
      .buttonStyle(.plain)
      .onHover { hovering = $0 }
      .accessibilityLabel("Resume \(title.displayName)")
      .contextMenu {
        Button("Resume", action: play)
        Button("Details and Versions", action: details)
        Button("Mark Watched") { store.toggleWatched(title.id) }
      }
      Text(subtitle)
        .font(.system(size: 12)).foregroundStyle(MyraColor.text2)
        .lineLimit(1)
    }
  }
}

/// The hero's buttons (`.btn`, `.btn.primary`, `.btn.glass`): 8pt radius, the accent when prominent.
private struct HeroButtonStyle: ButtonStyle {
  var prominent = false
  @Environment(\.myraAccent) private var accent

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 13))
      .padding(.horizontal, 12).padding(.vertical, 6)
      .foregroundStyle(.white)
      .background(
        RoundedRectangle(cornerRadius: 8).fill(
          prominent
            ? accent.color
            : Color.white.opacity(configuration.isPressed ? 0.28 : 0.18))
      )
      .overlay {
        if !prominent {
          RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.25), lineWidth: 1)
        }
      }
      .contentShape(RoundedRectangle(cornerRadius: 8))
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

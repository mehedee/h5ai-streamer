import SwiftUI

/// An automatic Home shelf after the user's hidden, pinned and order choices are applied,
/// with its titles resolved from the filtered catalogue in shelf order.
struct HomeAutomaticShelf: Identifiable, Sendable {
  let arranged: ArrangedHomeCategory
  let titles: [EntertainmentTitle]

  var id: String { arranged.id }
  var name: String { arranged.category.displayName }
  var subtitle: String {
    arranged.isPinned
      ? "Pinned • automatic shelf" : "Automatic shelf • \(arranged.category.count) titles"
  }
}

enum HomeShelfBuilder {
  /// Shelves for Home. Hidden shelves are dropped and pinned shelves stay at the front.
  static func shelves(
    from titles: [EntertainmentTitle], preferences: HomeCategoryPreferences
  ) -> [HomeAutomaticShelf] {
    let byID = Dictionary(titles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    return HomeCategoryBuilder.arranged(for: titles, preferences: preferences)
      .filter { !$0.isHidden }
      .map { arranged in
        HomeAutomaticShelf(
          arranged: arranged,
          titles: arranged.category.titleIDs.compactMap { byID[$0] })
      }
  }
}

/// "Browse by" chips that scroll Home to an automatic shelf, plus the entry point to Customise Home.
struct HomeBrowseByRow: View {
  let shelves: [HomeAutomaticShelf]
  let scrollTo: (String) -> Void
  let customise: () -> Void

  var body: some View {
    HStack(alignment: .center, spacing: 10) {
      Text("Browse by").font(.callout).foregroundStyle(.secondary)
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
          ForEach(shelves) { shelf in
            Button {
              scrollTo(shelf.id)
            } label: {
              Text(shelf.name)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(.quaternary, in: Capsule())
            }
            .buttonStyle(.plain)
            .help("Jump to \(shelf.name)")
            .accessibilityLabel("Browse by \(shelf.name)")
          }
        }
        .padding(.vertical, 2)
      }
      Button("Customise Home…", action: customise)
        .buttonStyle(.borderless)
        .help("Show, hide, reorder and pin shelves")
    }
  }
}

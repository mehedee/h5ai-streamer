import SwiftUI

/// The Watchlist as the UI sees it: a set of saved title IDs.
///
/// Storage is the profile's existing personal data (`EntertainmentPersonalData.watchlist`, toggled by
/// `EntertainmentStore.toggleWatchlist`), so the context menus, the detail view, the Ask Myra cards,
/// the bookmark on posters, the sidebar badge and the Watchlist page all agree and survive
/// relaunches and profile backups. This type only derives what the pages show from that set.
enum WatchlistStore {
  /// The saved titles that are still in the catalogue, A to Z. A saved ID whose title left the
  /// library (a source removed) is kept in the set but not shown.
  static func titles(in catalogue: [EntertainmentTitle], saved: Set<String>) -> [EntertainmentTitle]
  {
    catalogue.filter { saved.contains($0.id) }
      .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
  }

  /// The sidebar badge: how many saved titles exist in the catalogue.
  static func badgeCount(in catalogue: [EntertainmentTitle], saved: Set<String>) -> Int {
    saved.isEmpty ? 0 : catalogue.reduce(0) { $0 + (saved.contains($1.id) ? 1 : 0) }
  }
}

/// The bookmark on a poster (`.bm`), bottom right: a 28 pt dark disc that appears on hover and
/// stays filled with the accent once the title is saved.
struct WatchlistBookmarkButton: View {
  let isSaved: Bool
  let isCardHovered: Bool
  let toggle: () -> Void

  @Environment(\.myraAccent) private var accent

  var body: some View {
    Button(action: toggle) {
      Image(systemName: isSaved ? "bookmark.fill" : "bookmark")
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.white)
        .frame(width: 28, height: 28)
        .background {
          Circle().fill(isSaved ? AnyShapeStyle(accent.color) : AnyShapeStyle(.black.opacity(0.5)))
        }
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .opacity(isSaved || isCardHovered ? 1 : 0)
    .animation(.easeOut(duration: 0.15), value: isCardHovered)
    .help(isSaved ? "Remove from Watchlist" : "Add to Watchlist")
    .accessibilityLabel(isSaved ? "Remove from Watchlist" : "Add to Watchlist")
    .accessibilityAddTraits(isSaved ? .isSelected : [])
  }
}

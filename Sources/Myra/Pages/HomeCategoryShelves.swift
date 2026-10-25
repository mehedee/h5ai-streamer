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

/// A capsule chip in the preview's `.chip` style. A selected chip fills with the accent and shows white
/// text. `caret` adds the dropdown marker for menu chips, and `count` adds a muted trailing figure.
struct HomeChip: View {
  let title: String
  var isOn = false
  var caret = false
  var count: String?

  @Environment(\.myraAccent) private var accent

  var body: some View {
    HStack(spacing: 5) {
      Text(title)
      if let count {
        Text(count)
          .font(.system(size: 11))
          .foregroundStyle(isOn ? Color.white.opacity(0.8) : MyraColor.text3)
          .monospacedDigit()
      }
      if caret {
        Text("▾")
          .font(.system(size: 10))
          .foregroundStyle(isOn ? Color.white.opacity(0.8) : MyraColor.text3)
      }
    }
    .font(.system(size: 13))
    .padding(.horizontal, 11)
    .padding(.vertical, 4)
    .foregroundStyle(isOn ? Color.white : MyraColor.text)
    .background(Capsule().fill(isOn ? accent.color : MyraColor.fill))
    .overlay {
      if !isOn {
        Capsule().stroke(MyraColor.line, lineWidth: 1)
      }
    }
    .contentShape(Capsule())
    .fixedSize()
  }
}

/// "Browse by" chips that scroll Home to an automatic shelf, with "Customise Home…" at the end of the row.
/// The row stays visible without shelves so Customise remains reachable.
struct HomeBrowseByRow: View {
  let shelves: [HomeAutomaticShelf]
  let scrollTo: (String) -> Void
  let customise: () -> Void

  @Environment(\.myraAccent) private var accent

  var body: some View {
    HStack(alignment: .center, spacing: 6) {
      Text("Browse by")
        .font(.system(size: 13)).foregroundStyle(MyraColor.text2)
        .padding(.trailing, 4)
      FlowLayout(spacing: 6) {
        ForEach(shelves) { shelf in
          Button {
            scrollTo(shelf.id)
          } label: {
            HomeChip(title: shelf.name, count: "\(shelf.arranged.category.count)")
          }
          .buttonStyle(.plain)
          .help("Jump to \(shelf.name)")
          .accessibilityLabel("Browse by \(shelf.name)")
        }
      }
      Spacer(minLength: 8)
      Button("Customise Home…", action: customise)
        .buttonStyle(.plain)
        .font(.system(size: 13))
        .foregroundStyle(accent.color)
        .help("Show, hide, reorder and pin shelves")
    }
  }
}

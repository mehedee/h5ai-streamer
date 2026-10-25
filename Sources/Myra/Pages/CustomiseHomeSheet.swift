import SwiftUI

/// Shows, hides, reorders and pins the automatic Home shelves. Each choice is saved as it is made.
struct CustomiseHomeSheet: View {
  @ObservedObject var store: EntertainmentStore
  @Environment(\.dismiss) private var dismiss

  private var rows: [ArrangedHomeCategory] { store.arrangedHomeCategories() }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Customise Home").font(.title2.bold())
          Text("Shelves appear on Home in this order. Pinned shelves come first.")
            .font(.callout).foregroundStyle(.secondary)
        }
        Spacer()
        Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
      }
      if rows.isEmpty {
        ContentUnavailableView(
          "No automatic shelves yet", systemImage: "rectangle.stack",
          description: Text(
            "A shelf appears once \(HomeCategoryRules.minimumTitleCount) titles match it."))
        .frame(maxWidth: .infinity, minHeight: 200)
      } else {
        List {
          ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
            CustomiseHomeRow(
              row: row, canMoveUp: index > 0, canMoveDown: index < rows.count - 1,
              setHidden: { store.setHomeCategoryHidden(row.id, $0) },
              setPinned: { store.setHomeCategoryPinned(row.id, $0) },
              moveUp: { store.moveHomeCategory(row.id, to: index - 1) },
              moveDown: { store.moveHomeCategory(row.id, to: index + 1) })
          }
          .onMove { source, destination in
            var ids = rows.map(\.id)
            ids.move(fromOffsets: source, toOffset: destination)
            store.setHomeCategoryOrder(ids)
          }
        }
      }
      HStack {
        Button("Restore Defaults") { store.resetHomeCategories() }
          .help("Show every shelf again, in the default order, with no pins")
        Spacer()
      }
    }
    .padding(24)
    .frame(minWidth: 560, minHeight: 460)
  }
}

private struct CustomiseHomeRow: View {
  let row: ArrangedHomeCategory
  let canMoveUp: Bool
  let canMoveDown: Bool
  let setHidden: (Bool) -> Void
  let setPinned: (Bool) -> Void
  let moveUp: () -> Void
  let moveDown: () -> Void

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      Toggle("Show on Home", isOn: Binding(get: { !row.isHidden }, set: { setHidden(!$0) }))
        .labelsHidden()
        .help("Show \(row.category.displayName) on Home")
      VStack(alignment: .leading, spacing: 3) {
        Text(row.category.displayName).font(.headline)
        Text("\(row.category.count) titles • \(row.category.rule)")
          .font(.caption).foregroundStyle(.secondary).lineLimit(2)
      }
      Spacer(minLength: 8)
      Button {
        setPinned(!row.isPinned)
      } label: {
        Image(systemName: row.isPinned ? "pin.fill" : "pin")
      }
      .buttonStyle(.borderless)
      .help(row.isPinned ? "Unpin \(row.category.displayName)" : "Pin to the top of Home")
      .accessibilityLabel(
        row.isPinned ? "Unpin \(row.category.displayName)" : "Pin \(row.category.displayName)")
      Button(action: moveUp) {
        Image(systemName: "arrow.up")
      }
      .buttonStyle(.borderless).disabled(!canMoveUp)
      .help("Move \(row.category.displayName) up")
      .accessibilityLabel("Move \(row.category.displayName) up")
      Button(action: moveDown) {
        Image(systemName: "arrow.down")
      }
      .buttonStyle(.borderless).disabled(!canMoveDown)
      .help("Move \(row.category.displayName) down")
      .accessibilityLabel("Move \(row.category.displayName) down")
    }
    .padding(.vertical, 4)
    .opacity(row.isHidden ? 0.55 : 1)
  }
}

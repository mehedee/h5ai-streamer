import SwiftUI

/// The filter bar pinned above Home and the category pages (`.fbar`): an All / Movies / Series
/// segment, Genre, Language, Year, Quality and Source popovers with search, multi-select and
/// counts, Hide watched, the result count and Clear.
struct LibraryFilterBar<Trailing: View>: View {
  @ObservedObject var model: LibraryFilterModel
  let options: LibraryFilterOptions
  let shown: Int
  let total: Int
  @ViewBuilder var trailing: Trailing

  @State private var openFacet: LibraryFacet?

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      FlowLayout(spacing: 8) {
      SegmentedControl(
        options: LibraryKind.allCases.map { SegmentOption(value: $0, title: $0.title) },
        selection: $model.selection.kind)
      ForEach(LibraryFacet.allCases) { facet in
        facetChip(facet)
      }
      Button {
        model.selection.hideWatched.toggle()
      } label: {
        HomeChip(
          title: model.selection.hideWatched ? "✓ Hide watched" : "Hide watched",
          isOn: model.selection.hideWatched)
      }
      .buttonStyle(.plain)
      .accessibilityAddTraits(model.selection.hideWatched ? .isSelected : [])
      }
      Spacer(minLength: 8)
      HStack(spacing: 8) {
      Text("\(shown.formatted()) of \(total.formatted()) titles")
        .font(.system(size: 13)).foregroundStyle(MyraColor.text2).monospacedDigit()
        .lineLimit(1)
      if model.selection.isActive {
        Button("Clear \(model.selection.activeCount)") { model.clear() }
          .buttonStyle(.plain)
          .foregroundStyle(.tint)
          .accessibilityLabel("Clear \(model.selection.activeCount) filters")
      }
      trailing
      }
      .fixedSize()
    }
    .lineLimit(1)
    .padding(.horizontal, HomeLayout.pageInset)
    .padding(.vertical, 10)
    .background {
      ZStack {
        Rectangle().fill(.ultraThinMaterial)
        Rectangle().fill(MyraColor.window.opacity(0.5))
      }
    }
    .overlay(alignment: .bottom) { Rectangle().fill(MyraColor.line).frame(height: 1) }
  }

  private func facetChip(_ facet: LibraryFacet) -> some View {
    let selected = model.selection.values(for: facet)
    let label: String =
      selected.isEmpty
      ? facet.title
      : "\(facet.title) · \(selected.count == 1 ? display(selected.first!, facet) : "\(selected.count)")"
    return Button {
      openFacet = facet
    } label: {
      HomeChip(title: label, isOn: !selected.isEmpty, caret: true)
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(facet.title) filter")
    .accessibilityValue(selected.isEmpty ? "Any" : "\(selected.count) selected")
    .popover(
      isPresented: Binding(
        get: { openFacet == facet },
        set: { if !$0, openFacet == facet { openFacet = nil } }),
      arrowEdge: .bottom
    ) {
      FacetPopover(
        facet: facet, options: items(for: facet),
        selection: Binding(
          get: { model.selection.values(for: facet) },
          set: { model.selection.setValues($0, for: facet) }),
        display: { display($0, facet) })
    }
  }

  private func items(for facet: LibraryFacet) -> [FilterOption] {
    switch facet {
    case .genre: options.genres
    case .language: options.languages
    case .year: options.years
    case .quality: options.qualities
    case .source: options.sources
    }
  }

  private func display(_ value: String, _ facet: LibraryFacet) -> String {
    facet == .language ? LibraryFilter.displayName(language: value) : value
  }
}

/// A facet's popover (`.pop`): a search field, checkbox rows with counts and a Clear footer.
struct FacetPopover: View {
  let facet: LibraryFacet
  let options: [FilterOption]
  @Binding var selection: Set<String>
  let display: (String) -> String

  @State private var query = ""
  @Environment(\.myraAccent) private var accent

  private var visible: [FilterOption] {
    let trimmed = query.trimmingCharacters(in: .whitespaces)
    return trimmed.isEmpty
      ? options : options.filter { display($0.value).localizedCaseInsensitiveContains(trimmed) }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(facet.title).font(.system(size: 13, weight: .bold))
      HStack(spacing: 6) {
        Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(MyraColor.text3)
        TextField("Search \(facet.title.lowercased())", text: $query)
          .textFieldStyle(.plain)
      }
      .padding(.horizontal, 9).padding(.vertical, 5)
      .background(MyraColor.fill, in: RoundedRectangle(cornerRadius: 8))
      .overlay(RoundedRectangle(cornerRadius: 8).stroke(MyraColor.line, lineWidth: 1))
      if options.isEmpty {
        Text("Nothing to filter by yet").font(.system(size: 12)).foregroundStyle(MyraColor.text2)
          .padding(.vertical, 8)
      } else {
        ScrollView {
          LazyVStack(spacing: 0) {
            ForEach(visible) { option in
              row(option)
            }
          }
        }
        .frame(maxHeight: 240)
      }
      HStack {
        Text(selection.isEmpty ? "Any" : "\(selection.count) selected")
          .font(.system(size: 12)).foregroundStyle(MyraColor.text2)
        Spacer()
        Button("Clear") { selection = [] }
          .buttonStyle(.plain).foregroundStyle(accent.color)
          .disabled(selection.isEmpty)
      }
      .padding(.top, 6)
      .overlay(alignment: .top) { Rectangle().fill(MyraColor.line).frame(height: 1) }
    }
    .font(.system(size: 13))
    .padding(12)
    .frame(width: 270)
  }

  private func row(_ option: FilterOption) -> some View {
    let on = selection.contains(option.value)
    return Button {
      if !selection.insert(option.value).inserted { selection.remove(option.value) }
    } label: {
      HStack(spacing: 9) {
        Image(systemName: on ? "checkmark.square.fill" : "square")
          .font(.system(size: 14))
          .foregroundStyle(on ? accent.color : MyraColor.text3)
        Text(display(option.value)).lineLimit(1)
        Spacer(minLength: 6)
        Text(option.count.formatted())
          .foregroundStyle(MyraColor.text3).monospacedDigit()
      }
      .padding(.horizontal, 8).padding(.vertical, 5)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(on ? .isSelected : [])
  }
}

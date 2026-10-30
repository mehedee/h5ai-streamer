import SwiftUI

/// A row of circular accent swatches, in macOS order. Bind it to the stored accent choice.
struct MyraAccentPicker: View {
  @Binding var selection: MyraAccent

  var body: some View {
    HStack(spacing: MyraSpacing.xs) {
      ForEach(MyraAccent.allCases) { accent in
        Button {
          selection = accent
        } label: {
          Circle()
            .fill(accent.color)
            .frame(width: 18, height: 18)
            .overlay {
              if accent == selection {
                Image(systemName: "checkmark")
                  .font(.system(size: 9, weight: .bold))
                  .foregroundStyle(.white)
              }
            }
        }
        .buttonStyle(.plain)
        .help(accent.title)
        .accessibilityLabel(accent.title)
        .accessibilityAddTraits(accent == selection ? .isSelected : [])
      }
    }
  }
}

// MARK: - Section header (`.section-head`)

/// A section title with an optional count and an optional trailing accent action ("See All").
struct SectionHeader: View {
  let title: String
  var count: Int?
  var actionTitle: String?
  var action: (() -> Void)?

  @Environment(\.myraAccent) private var accent

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(title)
        .font(.system(size: 17, weight: .bold))
        .lineLimit(1)
      if let count {
        Text(count.formatted())
          .foregroundStyle(MyraColor.text3)
          .monospacedDigit()
      }
      Spacer(minLength: 8)
      if let actionTitle, let action {
        Button(actionTitle, action: action)
          .buttonStyle(.plain)
          .foregroundStyle(accent.color)
      }
    }
    .padding(.top, 26)
    .padding(.bottom, 4)
  }
}

// MARK: - Media card (`.card`, `.poster`)

/// A 2:3 poster with a rating pill, a watched check and an optional progress bar, with the title
/// and subtitle beneath. The poster falls back to the title card when artwork is missing.
struct MediaCard: View {
  let title: String
  var subtitle: String?
  var posterURL: URL?
  var rating: Double?
  var watched = false
  /// Playback progress from 0 to 1, drawn along the bottom of the poster.
  var progress: Double?
  /// Whether the title is on the Watchlist. With `toggleSaved`, a bookmark shows at the bottom
  /// right of the poster on hover, and stays filled once saved.
  var isSaved = false
  var toggleSaved: (() -> Void)?

  @State private var isHovering = false
  @Environment(\.myraAccent) private var accent

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      poster
      Text(title)
        .font(.system(size: 13, weight: .semibold))
        .lineLimit(1)
        .truncationMode(.tail)
        .padding(.top, 8)
      if let subtitle {
        Text(subtitle)
          .font(.system(size: 12))
          .foregroundStyle(MyraColor.text2)
          .lineLimit(1)
      }
    }
    .onHover { isHovering = $0 }
  }

  private var poster: some View {
    Color.clear
      .aspectRatio(2.0 / 3.0, contentMode: .fit)
      .overlay {
        FallbackArtworkView(title: title, candidates: candidates)
      }
      .clipShape(RoundedRectangle(cornerRadius: 10))
      .shadow(color: .black.opacity(0.15), radius: 1.5, y: 1)
      .overlay(alignment: .topTrailing) {
        if let rating {
          Text("★ \(rating.formatted(.number.precision(.fractionLength(1))))")
            .font(.system(size: 11))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
            .padding(8)
        }
      }
      .overlay(alignment: .topLeading) {
        if watched {
          Image(systemName: "checkmark")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(Color.green, in: Circle())
            .padding(8)
        }
      }
      .overlay(alignment: .bottom) {
        if let progress {
          ProgressBarView(fraction: progress, track: .white.opacity(0.3), tint: .white)
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
        }
      }
      .overlay(alignment: .bottomTrailing) {
        if let toggleSaved {
          WatchlistBookmarkButton(isSaved: isSaved, isCardHovered: isHovering, toggle: toggleSaved)
            .padding(8)
        }
      }
      .background {
        if isHovering {
          RoundedRectangle(cornerRadius: 12)
            .stroke(accent.color, lineWidth: 3)
            .padding(-3)
        }
      }
  }

  private var candidates: [ArtworkCandidate] {
    guard let posterURL else { return [.titleCard] }
    return [.image(.tmdbPoster, posterURL)]
  }
}

// MARK: - Status pill (`.status`)

/// A small capsule with a dot and a semibold label. Green, orange and red are system colours.
struct StatusPill: View {
  enum Style: Equatable {
    case ok, warn, err, live, neutral
  }

  let text: String
  var style: Style = .neutral

  @Environment(\.myraAccent) private var accent
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    HStack(spacing: 5) {
      Circle()
        .frame(width: 6, height: 6)
      Text(text)
    }
    .font(.system(size: 11, weight: .semibold))
    .foregroundStyle(foreground)
    .padding(.horizontal, 8)
    .padding(.vertical, 2)
    .background(background, in: Capsule())
  }

  private var foreground: Color {
    switch style {
    case .ok: .green
    case .warn: .orange
    case .err: .red
    case .live: accent.color
    case .neutral: MyraColor.text2
    }
  }

  private var background: Color {
    switch style {
    case .ok: Color.green.opacity(0.12)
    case .warn: Color.orange.opacity(0.14)
    case .err: Color.red.opacity(0.12)
    case .live: accent.color.opacity(colorScheme == .dark ? 0.20 : 0.13)
    case .neutral: MyraColor.fill
    }
  }
}

// MARK: - Progress bar (`.progress`)

/// A 4pt bar: the track in the fill colour, the fill in the accent unless a tint is given.
struct ProgressBarView: View {
  let fraction: Double
  var track: Color = MyraColor.fill2
  var tint: Color?

  @Environment(\.myraAccent) private var accent

  var body: some View {
    let clamped = min(1, max(0, fraction))
    GeometryReader { geometry in
      ZStack(alignment: .leading) {
        Capsule().fill(track)
        Capsule()
          .fill(tint ?? accent.color)
          .frame(width: geometry.size.width * clamped)
      }
    }
    .frame(height: 4)
    .clipShape(Capsule())
    .accessibilityValue(Text("\(Int((clamped * 100).rounded())) percent"))
  }
}

// MARK: - Chips (`.chips`, `.chip`, `.chip.on`)

/// One chip in a `ChipBar`. `showsCaret` adds the dropdown marker used by filter chips.
struct ChipItem<ID: Hashable>: Identifiable {
  let id: ID
  let title: String
  var showsCaret = false
}

/// A wrapping row of capsule chips. A selected chip is filled with the accent and shows white text.
struct ChipBar<ID: Hashable>: View {
  let items: [ChipItem<ID>]
  let isOn: (ID) -> Bool
  let action: (ID) -> Void

  var body: some View {
    FlowLayout(spacing: 6) {
      ForEach(items) { item in
        ChipView(item: item, isOn: isOn(item.id)) { action(item.id) }
      }
    }
  }
}

private struct ChipView<ID: Hashable>: View {
  let item: ChipItem<ID>
  let isOn: Bool
  let action: () -> Void

  @Environment(\.myraAccent) private var accent

  var body: some View {
    Button(action: action) {
      HStack(spacing: 5) {
        Text(item.title)
        if item.showsCaret {
          Text("▾")
            .font(.system(size: 10))
            .foregroundStyle(isOn ? Color.white.opacity(0.8) : MyraColor.text3)
        }
      }
      .padding(.horizontal, 11)
      .padding(.vertical, 4)
      .foregroundStyle(isOn ? Color.white : MyraColor.text)
      .background(
        Capsule().fill(isOn ? accent.color : MyraColor.fill)
      )
      .overlay {
        if !isOn {
          Capsule().stroke(MyraColor.line, lineWidth: 1)
        }
      }
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isOn ? .isSelected : [])
  }
}

/// Lays subviews out left to right, wrapping onto a new line when the proposed width runs out.
struct FlowLayout: Layout {
  var spacing: CGFloat = 6

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let maxWidth = proposal.width ?? .infinity
    var x: CGFloat = 0
    var y: CGFloat = 0
    var rowHeight: CGFloat = 0
    var widest: CGFloat = 0
    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if x > 0, x + size.width > maxWidth {
        x = 0
        y += rowHeight + spacing
        rowHeight = 0
      }
      x += size.width + spacing
      rowHeight = max(rowHeight, size.height)
      widest = max(widest, x - spacing)
    }
    return CGSize(width: widest, height: y + rowHeight)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var x = bounds.minX
    var y = bounds.minY
    var rowHeight: CGFloat = 0
    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if x > bounds.minX, x + size.width > bounds.maxX {
        x = bounds.minX
        y += rowHeight + spacing
        rowHeight = 0
      }
      subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
      x += size.width + spacing
      rowHeight = max(rowHeight, size.height)
    }
  }
}

// MARK: - Toolbar pill and buttons (`.tgroup`, `.tbtn`)

/// The rounded glass group that holds page actions in the toolbar.
struct ToolbarPill<Content: View>: View {
  @ViewBuilder var content: Content

  var body: some View {
    HStack(spacing: 2) {
      content
    }
    .padding(3)
    .background {
      Capsule().fill(.ultraThinMaterial)
      Capsule().fill(MyraColor.glass)
    }
    .overlay(Capsule().stroke(MyraColor.line, lineWidth: 1))
  }
}

/// A toolbar action: optional SF Symbol, title, hover fill, and an accent-filled primary style.
/// Apply `.disabled(_:)` to gate it, as the menu does.
struct ToolbarButton: View {
  let title: String
  var systemImage: String?
  var primary = false
  let action: () -> Void

  @State private var isHovering = false
  @Environment(\.myraAccent) private var accent
  @Environment(\.isEnabled) private var isEnabled

  var body: some View {
    Button(action: action) {
      HStack(spacing: 6) {
        if let systemImage {
          Image(systemName: systemImage)
            .font(.system(size: 13, weight: .medium))
            .frame(width: 16, height: 16)
        }
        Text(title)
      }
      .font(.system(size: 13))
      .padding(.horizontal, 10)
      .padding(.vertical, 5)
      .foregroundStyle(primary ? Color.white : MyraColor.text)
      .background(
        Capsule().fill(primary ? accent.color : (isHovering ? MyraColor.fill2 : .clear))
      )
      .contentShape(Capsule())
      .opacity(isEnabled ? 1 : 0.4)
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
    .help(title)
  }
}

// MARK: - Icon button (`.icon-btn`)

/// A 28pt square icon button with a 7pt radius and a hover fill.
struct IconButton: View {
  let systemName: String
  let help: String
  let action: () -> Void

  @State private var isHovering = false

  var body: some View {
    Button(action: action) {
      Image(systemName: systemName)
        .font(.system(size: 14, weight: .medium))
        .frame(width: 28, height: 28)
        .background(isHovering ? MyraColor.fill2 : .clear, in: RoundedRectangle(cornerRadius: 7))
        .foregroundStyle(isHovering ? MyraColor.text : MyraColor.text2)
        .contentShape(RoundedRectangle(cornerRadius: 7))
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
    .help(help)
    .accessibilityLabel(help)
  }
}

// MARK: - Button style (`.btn`)

/// The bordered button from the preview. `prominent` gives the accent-filled primary variant.
struct MyraButtonStyle: ButtonStyle {
  var prominent = false

  @Environment(\.myraAccent) private var accent
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 13))
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      .foregroundStyle(prominent ? Color.white : MyraColor.text)
      .background(
        RoundedRectangle(cornerRadius: 8)
          .fill(
            prominent
              ? accent.color
              : (configuration.isPressed ? MyraColor.fill2 : MyraColor.fill))
      )
      .overlay {
        if !prominent {
          RoundedRectangle(cornerRadius: 8).stroke(MyraColor.line, lineWidth: 1)
        }
      }
      .opacity(isEnabled ? 1 : 0.4)
  }
}

// MARK: - Search field (`.search`)

/// A 260pt capsule search field with a leading magnifier and a placeholder for the page.
struct SearchField: View {
  @Binding var text: String
  let prompt: String
  var isFocused: FocusState<Bool>.Binding

  var body: some View {
    HStack(spacing: 7) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(MyraColor.text3)
      TextField(prompt, text: $text)
        .textFieldStyle(.plain)
        .foregroundStyle(MyraColor.text)
        .focused(isFocused)
    }
    .font(.system(size: 13))
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    // 260 pt when there is room; it gives way to the page actions and the indexing indicator.
    .frame(minWidth: 150, idealWidth: 260, maxWidth: 260)
    .background {
      Capsule().fill(.ultraThinMaterial)
      Capsule().fill(MyraColor.glass)
    }
    .overlay(Capsule().stroke(MyraColor.line, lineWidth: 1))
    .accessibilityLabel(prompt)
  }
}

// MARK: - Segmented control (`.seg`)

/// One segment of a `SegmentedControl`.
struct SegmentOption<Value: Hashable>: Identifiable {
  let value: Value
  let title: String

  var id: Value { value }
}

/// The inline two-or-more-way control from the preview. The selected segment lifts onto the content colour.
struct SegmentedControl<Value: Hashable>: View {
  let options: [SegmentOption<Value>]
  @Binding var selection: Value

  var body: some View {
    HStack(spacing: 0) {
      ForEach(options) { option in
        let selected = option.value == selection
        Button {
          selection = option.value
        } label: {
          Text(option.title)
            .font(.system(size: 13, weight: selected ? .semibold : .regular))
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .foregroundStyle(MyraColor.text)
            .background(
              RoundedRectangle(cornerRadius: 7)
                .fill(selected ? MyraColor.content : .clear)
                .shadow(color: .black.opacity(selected ? 0.15 : 0), radius: 1.5, y: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
      }
    }
    .padding(2)
    .background(MyraColor.fill2, in: RoundedRectangle(cornerRadius: 9))
  }
}

// MARK: - Row card (`.panel`, `.row`)

/// The thumbnail, name, meta and action treatment for one entry in a `RowCard`.
struct RowCardAction: Identifiable {
  enum Style: Equatable {
    /// A 28pt icon button.
    case icon
    /// A bordered text button, used for "Retry" and similar.
    case button
  }

  let id: String
  let title: String
  var systemImage: String?
  var style: Style = .icon
  let action: () -> Void
}

/// One row of a `RowCard`. The thumbnail is a gradient tile, or a neutral tile when no colours are given.
struct RowCardItem: Identifiable {
  let id: String
  var title: String
  var thumbnailSymbol = "film"
  var thumbnailColors: [Color] = []
  var thumbnailTint: Color = .white
  var tags: [String] = []
  var meta: [String] = []
  var status: StatusPill?
  var progress: Double?
  var actions: [RowCardAction] = []
}

/// A panel of rows separated by 1pt lines. Each row shows a 44pt thumbnail, a name, a meta line
/// with tags, status and details, an optional progress bar, and trailing actions.
struct RowCard: View {
  let rows: [RowCardItem]
  /// The compact popover rows in the preview have no thumbnail.
  var showsThumbnails = true

  var body: some View {
    VStack(spacing: 0) {
      ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
        if index > 0 {
          Rectangle()
            .fill(MyraColor.line)
            .frame(height: 1)
        }
        RowCardRow(row: row, showsThumbnail: showsThumbnails)
      }
    }
    .background(MyraColor.content, in: RoundedRectangle(cornerRadius: MyraRadius.panel))
    .overlay(RoundedRectangle(cornerRadius: MyraRadius.panel).stroke(MyraColor.line, lineWidth: 1))
    .clipShape(RoundedRectangle(cornerRadius: MyraRadius.panel))
  }
}

private struct RowCardRow: View {
  let row: RowCardItem
  let showsThumbnail: Bool

  var body: some View {
    HStack(alignment: .center, spacing: 14) {
      if showsThumbnail {
        thumbnail
      }
      VStack(alignment: .leading, spacing: 0) {
        Text(row.title)
          .font(.system(size: 13, weight: .semibold))
          .lineLimit(1)
          .truncationMode(.tail)
        metaLine
        if let progress = row.progress {
          ProgressBarView(fraction: progress)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      if !row.actions.isEmpty {
        HStack(spacing: 4) {
          ForEach(row.actions) { action in
            switch action.style {
            case .icon:
              IconButton(systemName: action.systemImage ?? "questionmark", help: action.title, action: action.action)
            case .button:
              Button(action: action.action) {
                if let systemImage = action.systemImage {
                  Label(action.title, systemImage: systemImage)
                } else {
                  Text(action.title)
                }
              }
              .buttonStyle(MyraButtonStyle())
            }
          }
        }
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
  }

  private var thumbnail: some View {
    ZStack {
      if row.thumbnailColors.isEmpty {
        RoundedRectangle(cornerRadius: 9).fill(MyraColor.fill2)
      } else {
        RoundedRectangle(cornerRadius: 9).fill(
          LinearGradient(
            colors: row.thumbnailColors, startPoint: .topLeading, endPoint: .bottomTrailing))
      }
      Image(systemName: row.thumbnailSymbol)
        .font(.system(size: 18))
        .foregroundStyle(row.thumbnailColors.isEmpty ? row.thumbnailTint : .white)
    }
    .frame(width: 44, height: 44)
  }

  private var metaLine: some View {
    HStack(spacing: 10) {
      ForEach(row.tags, id: \.self) { tag in
        Text(tag.uppercased())
          .font(.system(size: 10, weight: .bold))
          .tracking(0.4)
          .foregroundStyle(MyraColor.text2)
          .padding(.horizontal, 6)
          .padding(.vertical, 1)
          .background(MyraColor.fill2, in: RoundedRectangle(cornerRadius: 4))
      }
      if let status = row.status {
        status
      }
      ForEach(row.meta, id: \.self) { part in
        Text(part)
      }
    }
    .font(.system(size: 12))
    .foregroundStyle(MyraColor.text2)
    .monospacedDigit()
    .lineLimit(1)
    .padding(.top, 3)
    .padding(.bottom, 6)
  }
}

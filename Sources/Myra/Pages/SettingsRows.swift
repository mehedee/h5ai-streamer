import SwiftUI

/// Measurements from the approved preview's Settings window (`.settings`, `.tabs`, `.group`, `.toggle`, `.select`).
enum SettingsMetrics {
  static let windowWidth: CGFloat = 680
  static let tabBarPadding: CGFloat = 10
  static let tabMinWidth: CGFloat = 70
  static let tabRadius: CGFloat = 8
  static let tabIconSize: CGFloat = 20
  static let tabLabelSize: CGFloat = 11
  static let groupRadius: CGFloat = 10
  static let rowHorizontalPadding: CGFloat = 12
  static let rowVerticalPadding: CGFloat = 9
  static let rowSpacing: CGFloat = 16
  static let switchWidth: CGFloat = 34
  static let switchHeight: CGFloat = 20
  static let knobDiameter: CGFloat = 16
  static let selectRadius: CGFloat = 6
  static let footerText = "Settings save automatically"
}

/// Colours that the preview defines outside `MyraColor`. The "on" state of a switch is the system green.
enum SettingsStyle {
  static let switchOn = MyraColor.dynamic((0x1F9D55, 1), (0x34C759, 1))
}

/// A section title with an optional note, drawn as a grouped rounded panel (`.group`).
/// Rows inside are separated by 1pt lines. The note appears under the panel as `.note`.
struct SettingsGroup<Content: View>: View {
  let title: String
  var note: String?
  @ViewBuilder var content: Content

  var body: some View {
    Section {
      VStack(spacing: 0) {
        content
      }
      .background(MyraColor.content, in: RoundedRectangle(cornerRadius: SettingsMetrics.groupRadius))
      .overlay(
        RoundedRectangle(cornerRadius: SettingsMetrics.groupRadius)
          .stroke(MyraColor.line, lineWidth: 1)
      )
      .listRowInsets(EdgeInsets())
      .listRowBackground(Color.clear)
      .listRowSeparator(.hidden)
    } header: {
      Text(title)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(MyraColor.text2)
        .padding(.leading, 4)
    } footer: {
      if let note {
        Text(note)
          .font(.system(size: 11))
          .foregroundStyle(MyraColor.text2)
          .padding(.leading, 4)
      }
    }
  }
}

/// One `.f` row: a label with an optional secondary line on the left and a control on the right.
struct SettingsRow<Control: View>: View {
  let title: String
  var detail: String?
  @ViewBuilder var control: Control

  var body: some View {
    HStack(spacing: SettingsMetrics.rowSpacing) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.system(size: 13))
          .foregroundStyle(MyraColor.text)
          .fixedSize(horizontal: false, vertical: true)
        if let detail {
          Text(detail)
            .font(.system(size: 11))
            .foregroundStyle(MyraColor.text2)
            .lineLimit(1)
            .truncationMode(.middle)
        }
      }
      Spacer(minLength: 8)
      control
    }
    .padding(.horizontal, SettingsMetrics.rowHorizontalPadding)
    .padding(.vertical, SettingsMetrics.rowVerticalPadding)
    .frame(maxWidth: .infinity, alignment: .leading)
    .overlay(alignment: .top) {
      Rectangle().fill(MyraColor.line).frame(height: 1)
    }
  }
}

/// A row whose control is a switch (`.toggle`), bound to a stored value.
struct SettingsToggleRow: View {
  let title: String
  var detail: String?
  @Binding var isOn: Bool

  var body: some View {
    SettingsRow(title: title, detail: detail) {
      Toggle(title, isOn: $isOn)
        .labelsHidden()
        .toggleStyle(SettingsSwitchStyle(title: title))
    }
  }
}

/// The 34 by 20 switch from the preview: a green track when on, a white knob that slides.
struct SettingsSwitchStyle: ToggleStyle {
  let title: String

  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    Button {
      configuration.isOn.toggle()
    } label: {
      ZStack {
        Capsule()
          .fill(configuration.isOn ? SettingsStyle.switchOn : MyraColor.fill2)
        Circle()
          .fill(Color.white)
          .shadow(color: .black.opacity(0.3), radius: 1, y: 1)
          .frame(width: SettingsMetrics.knobDiameter, height: SettingsMetrics.knobDiameter)
          .frame(
            maxWidth: .infinity,
            alignment: configuration.isOn ? .trailing : .leading
          )
          .padding(2)
      }
      .frame(width: SettingsMetrics.switchWidth, height: SettingsMetrics.switchHeight)
      .animation(.easeInOut(duration: 0.15), value: configuration.isOn)
    }
    .buttonStyle(.plain)
    .opacity(isEnabled ? 1 : 0.4)
    .accessibilityLabel(Text(title))
    .accessibilityValue(configuration.isOn ? "On" : "Off")
    .accessibilityAddTraits(.isToggle)
  }
}

/// One choice in a `SettingsSelect`.
struct SettingsOption<Value: Hashable>: Identifiable {
  let value: Value
  let title: String

  var id: Value { value }
}

/// The `.select` pill: the current value and a chevron. Choosing an item sets the bound value.
struct SettingsSelect<Value: Hashable>: View {
  let title: String
  @Binding var selection: Value
  let options: [SettingsOption<Value>]

  private var currentTitle: String {
    options.first { $0.value == selection }?.title ?? ""
  }

  var body: some View {
    Menu {
      ForEach(options) { option in
        Button {
          selection = option.value
        } label: {
          if option.value == selection {
            Label(option.title, systemImage: "checkmark")
          } else {
            Text(option.title)
          }
        }
      }
    } label: {
      HStack(spacing: 4) {
        Text(currentTitle)
        Image(systemName: "chevron.down")
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(MyraColor.text2)
      }
      .font(.system(size: 13))
      .foregroundStyle(MyraColor.text)
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .background(MyraColor.fill, in: RoundedRectangle(cornerRadius: SettingsMetrics.selectRadius))
      .overlay(
        RoundedRectangle(cornerRadius: SettingsMetrics.selectRadius)
          .stroke(MyraColor.line, lineWidth: 1)
      )
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .accessibilityLabel(title)
    .accessibilityValue(currentTitle)
  }
}

/// A validation or status line inside a group, shown under its rows in the same panel.
struct SettingsInlineMessage: View {
  let text: String
  var color: Color = MyraColor.text2

  var body: some View {
    Text(text)
      .font(.system(size: 11))
      .foregroundStyle(color)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, SettingsMetrics.rowHorizontalPadding)
      .padding(.vertical, SettingsMetrics.rowVerticalPadding)
      .overlay(alignment: .top) {
        Rectangle().fill(MyraColor.line).frame(height: 1)
      }
  }
}

/// Options for the preview's select pills ("3 ▾", "Unlimited ▾"). A stored value outside the
/// presets stays listed, so opening a select never changes a setting.
enum SettingsChoices {
  static func numbers(
    _ presets: [Int], current: Int, title: (Int) -> String = { "\($0)" }
  ) -> [SettingsOption<Int>] {
    var values = presets
    if !values.contains(current) { values = (values + [current]).sorted() }
    return values.map { SettingsOption(value: $0, title: title($0)) }
  }

  static func strings(_ presets: [(String, String)], current: String) -> [SettingsOption<String>] {
    var options = presets.map { SettingsOption(value: $0.0, title: $0.1) }
    if !presets.contains(where: { $0.0 == current }) {
      options.append(SettingsOption(value: current, title: current))
    }
    return options
  }
}

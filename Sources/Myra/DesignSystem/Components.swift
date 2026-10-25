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

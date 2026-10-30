import SwiftUI

struct PlaybackChoices: Identifiable {
  let id = UUID()
  let versions: [EntertainmentVersion]
  let preferredURL: URL
  /// Why the highlighted version was chosen, shown under the heading.
  var reason: String? = nil
  /// The title whose "Always use" quality can be set from this sheet.
  var titleID: String? = nil
}

struct PlaybackChoicesView: View {
  let choices: PlaybackChoices
  let play: (GlobalSearchResult) -> Void
  /// Saves a title's "Always use" resolution (title id, label such as "1080p").
  var rememberQuality: (String, String) -> Void = { _, _ in }
  @Environment(\.dismiss) private var dismiss

  private var preferredVersion: EntertainmentVersion? {
    choices.versions.first { $0.media.entry.url == choices.preferredURL }
  }

  /// The "Always use" offer, when the highlighted release has a resolution to remember.
  private var rememberable: (titleID: String, label: String)? {
    guard let titleID = choices.titleID, let version = preferredVersion else { return nil }
    let height = BestVersionPicker.height(of: version)
    return height > 0 ? (titleID, "\(height)p") : nil
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Choose a version").font(.title2.bold())
      Text("Different releases of the same title are grouped together.")
        .foregroundStyle(.secondary)
      if let reason = choices.reason {
        Label(reason, systemImage: "sparkles")
          .font(.callout).foregroundStyle(.secondary)
          .accessibilityLabel("Why this version: \(reason)")
      }
      ScrollView {
        VStack(spacing: 10) {
          ForEach(choices.versions) { version in
            Button {
              dismiss()
              play(version.media)
            } label: {
              VStack(alignment: .leading, spacing: 5) {
                HStack {
                  Text(version.media.entry.name).font(.headline)
                  if version.media.entry.url == choices.preferredURL {
                    Text(version.lastPlayed == nil ? "Selected" : "Previously played")
                      .font(.caption).foregroundStyle(.tint)
                  }
                }
                Text(version.quality.isEmpty ? "Quality unknown" : version.quality)
                HStack {
                  Text(version.media.categoryName)
                  if let size = version.media.entry.size {
                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                  }
                  if version.progressSeconds > 0 {
                    Text("Resume at \(PlayerTime.string(version.progressSeconds))")
                  }
                }.font(.caption).foregroundStyle(.secondary)
              }
              .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }.buttonStyle(.bordered)
          }
        }
      }
      HStack {
        if let rememberable {
          Button("Always use \(rememberable.label) for this title") {
            rememberQuality(rememberable.titleID, rememberable.label)
            dismiss()
            if let preferredVersion { play(preferredVersion.media) }
          }
        }
        Spacer()
        Button("Cancel") { dismiss() }
      }
    }.padding(24).frame(width: 620, height: 440)
  }
}

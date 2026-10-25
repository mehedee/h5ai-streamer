import AppKit
import SwiftUI

/// Shows the first candidate that loads, moving on after a failure or a missing image.
/// The title card is shown while loading and whenever no candidate loads.
struct FallbackArtworkView: View {
  let title: String
  let candidates: [ArtworkCandidate]
  var loader: ArtworkLoader = .shared

  @State private var image: NSImage?

  var body: some View {
    ZStack {
      if let image {
        Image(nsImage: image)
          .resizable()
          .scaledToFill()
      } else {
        TitleCardView(title: title)
      }
    }
    .clipped()
    .task(id: candidates) {
      image = nil
      image = await firstLoadedImage()
    }
  }

  private func firstLoadedImage() async -> NSImage? {
    for candidate in candidates {
      guard case .image(_, let url) = candidate else { return nil }
      if Task.isCancelled { return nil }
      if let data = try? await loader.data(for: url), let loaded = NSImage(data: data) {
        return loaded
      }
    }
    return nil
  }
}

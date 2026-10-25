import AppKit
import SwiftUI

struct TMDBAttributionView: View {
  private var logo: NSImage? {
    #if SWIFT_PACKAGE
      let url = Bundle.module.url(forResource: "TMDB", withExtension: "png")
    #else
      let url = Bundle.main.url(forResource: "TMDB", withExtension: "png")
    #endif
    return url.flatMap(NSImage.init(contentsOf:))
  }
  var body: some View {
    HStack(spacing: 16) {
      if let logo { Image(nsImage: logo).resizable().scaledToFit().frame(width: 65, height: 65) }
      VStack(alignment: .leading, spacing: 6) {
        Text("This product uses the TMDB API but is not endorsed or certified by TMDB.")
        Link("The Movie Database", destination: URL(string: "https://www.themoviedb.org")!)
        Text("Metadata and images for personal, noncommercial use.").font(.caption).foregroundStyle(
          .secondary)
      }
    }
  }
}

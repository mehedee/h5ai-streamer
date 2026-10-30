import Foundation

/// Finds a Skip Intro target from embedded chapter markers.
///
/// The button is offered only near the start of a video (the first 2.5 minutes), and only
/// while the playhead is inside a chapter whose name says it is an intro or opening. Videos
/// without such chapters get no button, and the existing marker-based skip still applies.
enum PlayerIntroSkip {
  static let windowSeconds: Double = 150

  static func isIntroName(_ name: String) -> Bool {
    let lowered = name.lowercased()
    return lowered.contains("intro") || lowered.contains("opening")
  }

  /// The range to skip, from the intro chapter's start to its end, or nil when none applies.
  /// A chapter without a duration ends where the next chapter starts.
  static func range(in chapters: [PlayerChapter], elapsed: Double, duration: Double)
    -> PlayerSkipRange?
  {
    guard elapsed.isFinite, elapsed >= 0, elapsed < windowSeconds,
      duration.isFinite, duration > 0
    else { return nil }
    let starts = chapters.compactMap(\.startSeconds).filter { $0.isFinite && $0 >= 0 }.sorted()
    for chapter in chapters where isIntroName(chapter.name) {
      guard let start = chapter.startSeconds, start.isFinite, start >= 0 else { continue }
      let end: Double
      if let length = chapter.durationSeconds, length.isFinite, length > 0 {
        end = start + length
      } else if let next = starts.first(where: { $0 > start }) {
        end = next
      } else {
        continue
      }
      guard end > start, end <= duration else { continue }
      let visibleEnd = min(end, windowSeconds)
      if elapsed >= start && elapsed < visibleEnd {
        return PlayerSkipRange(start: start, end: end)
      }
    }
    return nil
  }
}

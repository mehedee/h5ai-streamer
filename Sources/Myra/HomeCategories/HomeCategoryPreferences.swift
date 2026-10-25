import Foundation

/// The user's choices for automatic Home shelves. Stored inside personal data.
///
/// Every field decodes with a default, so personal data written before this type existed,
/// or with a field missing, still loads.
struct HomeCategoryPreferences: Codable, Sendable, Equatable {
  static let currentVersion = 1

  var version: Int
  /// Category ids in the user's chosen order. Categories not listed keep their default order after these.
  var order: [String]
  var hidden: Set<String>
  var pinned: Set<String>

  init(
    version: Int = HomeCategoryPreferences.currentVersion,
    order: [String] = [], hidden: Set<String> = [], pinned: Set<String> = []
  ) {
    self.version = version
    self.order = order
    self.hidden = hidden
    self.pinned = pinned
  }

  private enum CodingKeys: String, CodingKey { case version, order, hidden, pinned }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    version =
      (try? container.decodeIfPresent(Int.self, forKey: .version))
      ?? HomeCategoryPreferences.currentVersion
    order = (try? container.decodeIfPresent([String].self, forKey: .order)) ?? []
    hidden = (try? container.decodeIfPresent(Set<String>.self, forKey: .hidden)) ?? []
    pinned = (try? container.decodeIfPresent(Set<String>.self, forKey: .pinned)) ?? []
  }

  mutating func setHidden(_ id: String, _ isHidden: Bool) {
    if isHidden { hidden.insert(id) } else { hidden.remove(id) }
  }

  mutating func setPinned(_ id: String, _ isPinned: Bool) {
    if isPinned { pinned.insert(id) } else { pinned.remove(id) }
  }

  /// Stores a full order, typically the ids from the arranged list after a drag.
  mutating func setOrder(_ ids: [String]) {
    var seen = Set<String>()
    order = ids.filter { seen.insert($0).inserted }
  }

  /// Moves one category to `destination` within `currentIDs`, the ids in their current arrangement.
  mutating func move(_ id: String, to destination: Int, in currentIDs: [String]) {
    var ids = currentIDs.filter { $0 != id }
    ids.insert(id, at: min(max(destination, 0), ids.count))
    setOrder(ids)
  }

  /// Applies pins and order to categories. Pinned categories come first, then the rest.
  /// Hidden categories are kept so a settings screen can show and restore them.
  func arrange(_ categories: [HomeCategory]) -> [ArrangedHomeCategory] {
    var rank: [String: Int] = [:]
    for (index, id) in order.enumerated() where rank[id] == nil { rank[id] = index }
    let ordered = categories.enumerated().sorted { lhs, rhs in
      let leftPinned = pinned.contains(lhs.element.id)
      let rightPinned = pinned.contains(rhs.element.id)
      if leftPinned != rightPinned { return leftPinned }
      let leftRank = rank[lhs.element.id] ?? (order.count + lhs.offset)
      let rightRank = rank[rhs.element.id] ?? (order.count + rhs.offset)
      if leftRank != rightRank { return leftRank < rightRank }
      return lhs.offset < rhs.offset
    }
    return ordered.map { _, category in
      ArrangedHomeCategory(
        category: category, isPinned: pinned.contains(category.id),
        isHidden: hidden.contains(category.id))
    }
  }
}

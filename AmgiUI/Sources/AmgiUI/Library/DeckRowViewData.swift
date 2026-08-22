import Foundation

/// Anki-agnostic view data for a single Library deck row. Containers
/// map from their domain model (e.g. AnkiKit's `DeckListRow`) to this
/// type so AmgiUI doesn't link the Anki backend.
public struct DeckRowViewData: Identifiable, Equatable, Hashable, Sendable {
    public let id: Int64
    public let name: String        // last path segment, e.g. "한국어"
    public let fullName: String    // full path, e.g. "Languages::한국어"
    public let newCount: Int
    public let learnCount: Int
    public let reviewCount: Int
    public let isFiltered: Bool
    public let subdeckCount: Int
    /// Persisted or name-derived icon (Phosphor case name). Nil ⇒ the tile
    /// falls back to the emoji/letter/monogram glyph.
    public var iconName: String?

    public init(
        id: Int64,
        name: String,
        fullName: String,
        newCount: Int,
        learnCount: Int,
        reviewCount: Int,
        isFiltered: Bool,
        subdeckCount: Int,
        iconName: String? = nil
    ) {
        self.id = id
        self.name = name
        self.fullName = fullName
        self.newCount = newCount
        self.learnCount = learnCount
        self.reviewCount = reviewCount
        self.isFiltered = isFiltered
        self.subdeckCount = subdeckCount
        self.iconName = iconName
    }

    public func updatingIconName(_ newName: String?) -> DeckRowViewData {
        var copy = self
        copy.iconName = newName
        return copy
    }

    public var totalCount: Int { newCount + learnCount + reviewCount }
}

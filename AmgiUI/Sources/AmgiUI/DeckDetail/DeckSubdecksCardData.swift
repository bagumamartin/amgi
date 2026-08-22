import Foundation

/// Pure DTO for a row in the Subdecks card. AmgiUI stays decoupled from
/// AnkiKit's `DeckTreeNode` — Containers map from the tree.
public struct DeckSubdeckRowData: Equatable, Hashable, Identifiable, Sendable {
    public let id: Int64
    public let name: String
    public let fullName: String
    public let newCount: Int
    public let learnCount: Int
    public let reviewCount: Int
    public let isFiltered: Bool
    /// Persisted or name-derived icon (Phosphor case name). Nil ⇒ the row
    /// keeps the generic stack-glyph placeholder.
    public var iconName: String?

    public init(
        id: Int64,
        name: String,
        fullName: String,
        newCount: Int,
        learnCount: Int,
        reviewCount: Int,
        isFiltered: Bool,
        iconName: String? = nil
    ) {
        self.id = id
        self.name = name
        self.fullName = fullName
        self.newCount = newCount
        self.learnCount = learnCount
        self.reviewCount = reviewCount
        self.isFiltered = isFiltered
        self.iconName = iconName
    }
}

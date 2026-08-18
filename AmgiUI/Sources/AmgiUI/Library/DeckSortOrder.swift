import Foundation

/// How deck rows are ordered in the Library list and deck-detail subdeck
/// card. Persisted by the app container; AmgiUI only renders the choice.
public enum DeckSortOrder: String, CaseIterable, Identifiable, Sendable, Hashable {
    case mostUsed
    case alphabetical
    case mostDue
    case collectionOrder

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .mostUsed: "Most used"
        case .alphabetical: "A–Z"
        case .mostDue: "Most due"
        case .collectionOrder: "Collection order"
        }
    }

    public var menuLabel: String {
        switch self {
        case .mostUsed: "Most used"
        case .alphabetical: "Alphabetical"
        case .mostDue: "Most due"
        case .collectionOrder: "Collection order"
        }
    }
}

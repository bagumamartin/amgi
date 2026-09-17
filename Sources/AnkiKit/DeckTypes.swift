package import Foundation

/// Search-term ordering for a filtered deck (mirrors
/// `Deck.Filtered.SearchTerm.Order` 1:1 so the wire values align).
public enum FilteredDeckOrder: Int, Sendable, Hashable, CaseIterable {
    case oldestReviewedFirst = 0
    case random = 1
    case intervalsAscending = 2
    case intervalsDescending = 3
    case lapses = 4
    case added = 5
    case due = 6
    case reverseAdded = 7
    case retrievabilityAscending = 8
    case retrievabilityDescending = 9
    case relativeOverdueness = 10

    public var label: String {
        switch self {
        case .oldestReviewedFirst: "Oldest reviewed first"
        case .random: "Random"
        case .intervalsAscending: "Intervals ascending"
        case .intervalsDescending: "Intervals descending"
        case .lapses: "Most lapses"
        case .added: "Order added"
        case .due: "Due"
        case .reverseAdded: "Reverse order added"
        case .retrievabilityAscending: "Retrievability ascending"
        case .retrievabilityDescending: "Retrievability descending"
        case .relativeOverdueness: "Relative overdueness"
        }
    }
}

/// One-shot spec for creating/updating a filtered deck from Browse.
public struct FilteredDeckSpec: Sendable, Equatable {
    public var name: String
    public var search: String
    public var limit: UInt32
    public var order: FilteredDeckOrder
    public var reschedule: Bool
    public var allowEmpty: Bool

    public init(
        name: String,
        search: String,
        limit: UInt32 = 100,
        order: FilteredDeckOrder = .oldestReviewedFirst,
        reschedule: Bool = true,
        allowEmpty: Bool = false
    ) {
        self.name = name
        self.search = search
        self.limit = limit
        self.order = order
        self.reschedule = reschedule
        self.allowEmpty = allowEmpty
    }
}

/// Server-prepared blank deck returned by `Request.newDeck`. Carries
/// the backend's default field values opaquely; consumers pair this
/// with `Request.addDeck(template:name:)` to persist.
public struct DeckTemplate: Sendable {
    package let bytes: Data
    package init(bytes: Data) { self.bytes = bytes }
}

public struct DeckInfo: Sendable, Equatable, Identifiable, Hashable {
    public let id: DeckID
    public var name: String
    public var counts: DeckCounts
    public var isFiltered: Bool

    public init(id: DeckID, name: String, counts: DeckCounts = .zero, isFiltered: Bool = false) {
        self.id = id
        self.name = name
        self.counts = counts
        self.isFiltered = isFiltered
    }
}

public struct DeckTreeNode: Sendable, Equatable, Identifiable {
    public let id: DeckID
    public var name: String
    public var fullName: String
    public var counts: DeckCounts
    public var isFiltered: Bool
    public var children: [DeckTreeNode]

    public init(
        id: DeckID,
        name: String,
        fullName: String,
        counts: DeckCounts = .zero,
        isFiltered: Bool = false,
        children: [DeckTreeNode] = []
    ) {
        self.id = id
        self.name = name
        self.fullName = fullName
        self.counts = counts
        self.isFiltered = isFiltered
        self.children = children
    }
}

public struct DeckCounts: Sendable, Equatable, Hashable {
    public var newCount: Int
    public var learnCount: Int
    public var reviewCount: Int

    public var total: Int { newCount + learnCount + reviewCount }

    public static let zero = DeckCounts(newCount: 0, learnCount: 0, reviewCount: 0)

    public init(newCount: Int, learnCount: Int, reviewCount: Int) {
        self.newCount = newCount
        self.learnCount = learnCount
        self.reviewCount = reviewCount
    }
}

extension DeckTreeNode {
    /// Recursively walks the subtree rooted at `self`, returning a flat
    /// `DeckInfo` for every descendant. The receiver is not included —
    /// callers typically operate on the synthetic root's children.
    public func flattened() -> [DeckInfo] {
        var result: [DeckInfo] = []
        for child in children {
            result.append(child.asDeckInfo)
            result.append(contentsOf: child.flattened())
        }
        return result
    }

    public var asDeckInfo: DeckInfo {
        DeckInfo(id: id, name: fullName, counts: counts, isFiltered: isFiltered)
    }

    /// Depth-first search by id over the subtree rooted at `self`.
    public func find(_ id: DeckID) -> DeckTreeNode? {
        if self.id == id { return self }
        for child in children {
            if let hit = child.find(id) { return hit }
        }
        return nil
    }
}

extension Array where Element == DeckTreeNode {
    /// Flattens every top-level node and its descendants into `[DeckInfo]`,
    /// using `fullName` for `DeckInfo.name`.
    public func flattened() -> [DeckInfo] {
        flatMap { node in [node.asDeckInfo] + node.flattened() }
    }

    public var sortedByName: [DeckInfo] {
        flattened().sorted { $0.name < $1.name }
    }

    public func find(_ id: DeckID) -> DeckTreeNode? {
        for node in self {
            if let hit = node.find(id) { return hit }
        }
        return nil
    }
}

extension Array where Element == DeckInfo {
    public var sortedByName: [DeckInfo] {
        sorted { $0.name < $1.name }
    }
}

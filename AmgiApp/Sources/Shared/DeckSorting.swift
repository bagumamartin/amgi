import AmgiUI
import AnkiKit

/// Review volume inferred from the synced collection (revlog via graphs).
/// Not local open-counts — those cannot travel with Anki sync.
struct DeckUsageRank: Equatable, Sendable {
    var reviewTotal: Int = 0
    /// 0 = today; more negative = older; `Int.min` = no reviews in the window.
    var lastActiveOffset: Int = .min
}

/// Applies `DeckSortOrder` to Library rows and deck-detail subdeck rows.
enum DeckSorting {
    static func libraryRows(
        _ rows: [DeckListRow],
        order: DeckSortOrder,
        ranks: [Int64: DeckUsageRank] = [:]
    ) -> [DeckListRow] {
        sorted(
            rows,
            order: order,
            id: { $0.id.rawValue },
            name: { $0.name },
            dueCount: { $0.counts.total },
            ranks: ranks
        )
    }

    static func subdeckRows(
        _ nodes: [DeckTreeNode],
        order: DeckSortOrder,
        ranks: [Int64: DeckUsageRank] = [:]
    ) -> [DeckTreeNode] {
        sorted(
            nodes,
            order: order,
            id: { $0.id.rawValue },
            name: { $0.name },
            dueCount: { $0.counts.total },
            ranks: ranks
        )
    }

    private static func sorted<T>(
        _ items: [T],
        order: DeckSortOrder,
        id: (T) -> Int64,
        name: (T) -> String,
        dueCount: (T) -> Int,
        ranks: [Int64: DeckUsageRank]
    ) -> [T] {
        let indexed = items.enumerated().map { (offset: $0.offset, element: $0.element) }
        let sortedIndexed = indexed.sorted { lhs, rhs in
            compare(
                lhs.element,
                rhs.element,
                lhsIndex: lhs.offset,
                rhsIndex: rhs.offset,
                order: order,
                id: id,
                name: name,
                dueCount: dueCount,
                ranks: ranks
            )
        }
        return sortedIndexed.map(\.element)
    }

    private static func compare<T>(
        _ lhs: T,
        _ rhs: T,
        lhsIndex: Int,
        rhsIndex: Int,
        order: DeckSortOrder,
        id: (T) -> Int64,
        name: (T) -> String,
        dueCount: (T) -> Int,
        ranks: [Int64: DeckUsageRank]
    ) -> Bool {
        switch order {
        case .collectionOrder:
            return lhsIndex < rhsIndex
        case .alphabetical:
            let nameOrder = name(lhs).localizedStandardCompare(name(rhs))
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return id(lhs) < id(rhs)
        case .mostDue:
            let leftDue = dueCount(lhs)
            let rightDue = dueCount(rhs)
            if leftDue != rightDue { return leftDue > rightDue }
            return tieBreak(lhs, rhs, id: id, name: name)
        case .mostUsed:
            let left = ranks[id(lhs)] ?? DeckUsageRank()
            let right = ranks[id(rhs)] ?? DeckUsageRank()
            if left.reviewTotal != right.reviewTotal {
                return left.reviewTotal > right.reviewTotal
            }
            if left.lastActiveOffset != right.lastActiveOffset {
                return left.lastActiveOffset > right.lastActiveOffset
            }
            return tieBreak(lhs, rhs, id: id, name: name)
        }
    }

    private static func tieBreak<T>(
        _ lhs: T,
        _ rhs: T,
        id: (T) -> Int64,
        name: (T) -> String
    ) -> Bool {
        let nameOrder = name(lhs).localizedStandardCompare(name(rhs))
        if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
        return id(lhs) < id(rhs)
    }
}

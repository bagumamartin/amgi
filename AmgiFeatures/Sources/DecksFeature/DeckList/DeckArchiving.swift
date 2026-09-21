import AnkiClients
import AnkiKit
import Foundation

/// Fully suspended decks leave the main list. Anki's built-in Default
/// deck (`id == 1`) and filtered Custom Study decks stay put even when
/// every card is parked. Empty decks are not archived — they never had
/// cards to park.
enum DeckArchiving {
    static let defaultDeckID = DeckID(1)

    struct Item: Sendable {
        let id: DeckID
        let fullName: String
        let isFiltered: Bool
        let dueCount: Int
    }

    static func isExempt(id: DeckID, isFiltered: Bool) -> Bool {
        isFiltered || id == defaultDeckID
    }

    static func isFullySuspended(totalCards: Int, suspendedCards: Int) -> Bool {
        totalCards > 0 && suspendedCards >= totalCards
    }

    static func archivedIDs(in items: [Item], using client: CardClient) async -> Set<DeckID> {
        let candidates = items.filter { item in
            item.dueCount == 0 && !isExempt(id: item.id, isFiltered: item.isFiltered)
        }
        guard !candidates.isEmpty else { return [] }

        return await withTaskGroup(of: DeckID?.self, returning: Set<DeckID>.self) { group in
            var iterator = candidates.makeIterator()
            func enqueue() {
                guard let item = iterator.next() else { return }
                group.addTask {
                    let scope = DeckSearch.term(item.fullName)
                    async let totalIDs = client.searchIds(scope, nil)
                    async let suspendedIDs = client.searchIds("\(scope) is:suspended", nil)
                    let total = (try? await totalIDs)?.count ?? 0
                    let suspended = (try? await suspendedIDs)?.count ?? 0
                    return isFullySuspended(totalCards: total, suspendedCards: suspended)
                        ? item.id
                        : nil
                }
            }
            for _ in 0..<min(8, candidates.count) {
                enqueue()
            }
            var ids: Set<DeckID> = []
            for await id in group {
                if let id { ids.insert(id) }
                enqueue()
            }
            return ids
        }
    }
}

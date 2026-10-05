import AmgiAppCore
import AmgiAppShared
import AmgiUI
import AnkiKit
import Foundation

extension DeckListModel {
    // Implemented in the owning file so the private persisted inputs never
    // escape to a view. This file groups the presentation-only value types.
    struct DecisionTarget {
        let deck: DeckTreeNode
        let profile: ProfileContext
        let scope: DeckDecisionScope
    }

    struct Deletion: Identifiable {
        let deck: DeckTreeNode
        let profile: ProfileContext
        let scope: DeckDecisionScope
        var id: DeckID { deck.id }
        var descendantCount: Int {
            func count(_ node: DeckTreeNode) -> Int { node.children.reduce(0) { $0 + 1 + count($1) } }
            return count(deck)
        }
    }
}

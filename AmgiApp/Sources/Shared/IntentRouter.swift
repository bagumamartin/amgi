import AnkiKit
import Dependencies
import Foundation
import Observation

/// In-process handoff from App Intents to the UI. Intent `perform()` runs
/// in this app process (the system cold-launches us after a force-quit,
/// which is what makes these intents force-quit-proof); the router parks
/// the request until the scene activates and the host view consumes it.
@MainActor
@Observable
final class IntentRouter {
    static let shared = IntentRouter()

    /// Deck to drop straight into review for.
    private(set) var pendingReviewDeckID: DeckID?

    /// Hand off and clear. Called by the app host on scene activation.
    func consumePendingReviewDeck() -> DeckID? {
        defer { pendingReviewDeckID = nil }
        return pendingReviewDeckID
    }

    func requestReview(deckID: DeckID?) {
        pendingReviewDeckID = deckID ?? DeckID(0)  // 0 = "no specific deck"
    }
}

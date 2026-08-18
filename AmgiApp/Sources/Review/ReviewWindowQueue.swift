import Foundation
import AnkiKit

#if os(macOS)

/// One-shot queue of deck requests for the macOS review windows.
///
/// This SDK's `WindowGroup` scene has no value-carrying initializer, so a
/// requested deck can't be passed straight through `openWindow`. Instead the
/// caller enqueues the deck, then opens a new review window; each window's
/// content claims the next deck on appear and holds it in its own `@State`.
/// This is what lets several decks be reviewed concurrently — one window per
/// request, unlike the previous single-instance `Window` scene.
@MainActor
final class ReviewWindowQueue {
    static let shared = ReviewWindowQueue()

    private var pending: [DeckID] = []
    private init() {}

    func enqueue(_ deckID: DeckID) {
        pending.append(deckID)
    }

    func dequeue() -> DeckID? {
        guard !pending.isEmpty else { return nil }
        return pending.removeFirst()
    }
}

#endif

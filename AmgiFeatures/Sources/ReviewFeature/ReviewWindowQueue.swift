#if os(macOS)
package import SwiftUI
import AmgiTheme
#endif
import Foundation
package import AnkiKit

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
package final class ReviewWindowQueue {
    package static let shared = ReviewWindowQueue()

    private var pending: [DeckID] = []
    private init() {}

    package func enqueue(_ deckID: DeckID) {
        pending.append(deckID)
    }

    package func dequeue() -> DeckID? {
        guard !pending.isEmpty else { return nil }
        return pending.removeFirst()
    }
}

/// Root content of a single review window. Each window claims its deck from
/// `ReviewWindowQueue` on appear and holds it in its own `@State`, so several
/// decks can be reviewed concurrently in separate windows.
package struct ReviewWindowHost: View {
    @State private var deckID: DeckID?

    package init() {}

    package var body: some View {
        Group {
            if let deckID {
                ReviewView(deckId: deckID) { }
            } else {
                VStack(spacing: AmgiSpacing.md) {
                    Image(systemName: "graduationcap")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("No deck selected")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            if deckID == nil {
                deckID = ReviewWindowQueue.shared.dequeue()
            }
        }
    }
}

#endif

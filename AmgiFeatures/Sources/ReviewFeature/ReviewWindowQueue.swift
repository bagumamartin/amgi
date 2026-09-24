#if os(macOS)
package import SwiftUI
import AmgiAppCore
import AmgiTheme
import Foundation
package import AnkiKit

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

    private struct PendingDeck {
        let deckID: DeckID
        let profile: ProfileContext
    }

    private var pending: [PendingDeck] = []
    private init() {}

    package func enqueue(_ deckID: DeckID) {
        pending.append(PendingDeck(deckID: deckID, profile: AccountStore.shared.selectedContext))
    }

    package func dequeue() -> DeckID? {
        let current = AccountStore.shared.selectedContext
        while let first = pending.first {
            pending.removeFirst()
            guard first.profile.isCurrent(current) else { continue }
            return first.deckID
        }
        return nil
    }
}

/// Root content of a single review window. Each window claims its deck from
/// `ReviewWindowQueue` on appear and holds it in its own `@State`, so several
/// decks can be reviewed concurrently in separate windows.
package struct ReviewWindowHost: View {
    @State private var deckID: DeckID?
    @Environment(\.palette) private var palette

    package init() {}

    package var body: some View {
        Group {
            if let deckID {
                ReviewView(deckId: deckID) { }
            } else {
                VStack(spacing: AmgiSpacing.md) {
                    Image(systemName: "graduationcap")
                        .amgiFont(.displayHero)
                        .foregroundStyle(palette.textSecondary)
                    Text("No deck selected")
                        .foregroundStyle(palette.textSecondary)
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

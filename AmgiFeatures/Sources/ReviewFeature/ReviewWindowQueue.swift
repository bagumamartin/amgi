#if os(macOS)
package import SwiftUI
package import AmgiAppCore
import AmgiTheme
import Foundation
package import AnkiKit

/// One-shot routing for the single Mac study window. The engine exposes one
/// mutable current-deck/undo context, so the host deliberately serializes
/// requests: a newer request replaces an unclaimed one and an already-open
/// window is retargeted in place instead of spawning a second owner.
@MainActor
package final class ReviewWindowQueue {
    package static let shared = ReviewWindowQueue()

    package struct Request: Sendable {
        package let deckID: DeckID
        package let profile: ProfileContext
        package let pullCooling: Bool

        package init(deckID: DeckID, profile: ProfileContext, pullCooling: Bool) {
            self.deckID = deckID
            self.profile = profile
            self.pullCooling = pullCooling
        }
    }

    private var pending: Request?
    private init() {}

    package func enqueue(_ deckID: DeckID, pullCooling: Bool = false) {
        pending = Request(
            deckID: deckID,
            profile: AccountStore.shared.selectedContext,
            pullCooling: pullCooling
        )
        NotificationCenter.default.post(name: .amgiReviewWindowRequest, object: nil)
    }

    package func dequeue() -> Request? {
        let current = AccountStore.shared.selectedContext
        guard let pending, pending.profile.isCurrent(current) else {
            self.pending = nil
            return nil
        }
        self.pending = nil
        return pending
    }

    package func discardPending() {
        pending = nil
    }
}

extension Notification.Name {
    fileprivate static let amgiReviewWindowRequest = Notification.Name("com.ijuka.review-window-request")
}

/// Root content of the single review window. It can consume a request that
/// arrives before the first render or while an older review is already open.
package struct ReviewWindowHost: View {
    @State private var request: ReviewWindowQueue.Request?
    @Bindable private var accountStore = AccountStore.shared
    @Bindable private var appLocale = AppLocaleModel.shared
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss

    package init() {}

    package var body: some View {
        Group {
            if let request {
                ReviewView(
                    deckId: request.deckID,
                    pullCooling: request.pullCooling,
                    onDismiss: { dismiss() }
                )
                .id(request.deckID.rawValue)
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
            if request == nil {
                request = ReviewWindowQueue.shared.dequeue()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .amgiReviewWindowRequest)) { _ in
            request = ReviewWindowQueue.shared.dequeue()
        }
        .onChange(of: accountStore.selectionID) { _, _ in
            ReviewWindowQueue.shared.discardPending()
            dismiss()
        }
        .environment(\.locale, appLocale.locale)
    }
}

#endif

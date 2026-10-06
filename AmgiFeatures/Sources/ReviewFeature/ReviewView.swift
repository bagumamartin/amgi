package import SwiftUI
import AmgiCardWeb
import AmgiTheme
import AmgiUI
import AmgiAppCore
import AmgiAppShared
import AnkiClients
package import AnkiKit
import Dependencies
import BrowseFeature
import SyncFeature
import TemplatesFeature
import Sharing
import AmgiReviewCore
import SwiftUINavigation


/// Container: owns the `ReviewSession`, the review preferences, the sheet
/// selection state, and the session lifecycle (`start()`, audio-session
/// application, widget snapshot on disappear). Hands the session plus pref
/// values and sheet bindings to the pure `ReviewContent`, which is what the
/// `#Preview`s build with a stub session.
package struct ReviewView: View {
    let deckId: DeckID
    let onDismiss: () -> Void

    @Shared(.appStorage(ReviewPreferences.Keys.openLinksExternally))
    private var openLinksExternally: Bool = true

    @Shared(.appStorage(ReviewPreferences.Keys.cardContentAlignment))
    private var cardContentAlignment: String = CardWebViewContentAlignment.center.rawValue

    @Shared(.appStorage(ReviewPreferences.Keys.autoMatchCardBackground))
    private var autoMatchCardBackground: Bool = true

    @Shared(.appStorage(ReviewPreferences.Keys.showRemainingDays))
    private var showRemainingDays: Bool = true

    @Shared(.appStorage(ReviewPreferences.Keys.showNextReviewTime))
    private var showNextReviewTime: Bool = true

    @Shared(.appStorage(ReaderPreferences.Keys.tapLookup))
    private var tapLookup: Bool = true

    @Shared(.appStorage(ReviewPreferences.Keys.playAudioInSilentMode))
    private var playAudioInSilentMode: Bool = false

    @State private var session: ReviewSession
    @State private var destination: ReviewDestination?
    @State private var toreDownSession = false
    @State private var endedSession = false

    private let accountStore = AccountStore.shared
    @Dependency(\.deckClient) private var deckClient
    @Dependency(\.collectionStore) private var store
    @Dependency(\.liveReviewCounts) private var liveCounts
    @Dependency(\.syncCoordinator) private var syncCoordinator

    package init(deckId: DeckID, pullCooling: Bool = false, onDismiss: @escaping () -> Void) {
        self.deckId = deckId
        self.onDismiss = onDismiss
        let session = ReviewSession(deckId: deckId)
        session.pullCoolingOnStart = pullCooling
        self._session = State(initialValue: session)
    }

    package var body: some View {
        ReviewContent(
            session: session,
            showRemainingDays: showRemainingDays,
            autoMatchCardBackground: autoMatchCardBackground,
            openLinksExternally: openLinksExternally,
            cardContentAlignment: cardContentAlignment,
            tapLookup: tapLookup,
            showNextReviewTime: showNextReviewTime,
            destination: $destination,
            onDismiss: dismiss
        )
        .task {
            ReviewAudioSession.apply(playInSilent: playAudioInSilentMode)
            // A post-review flush may be sleeping toward launch; drop it so
            // the session's first cards don't serialize behind a sync on the
            // backend lock. Dirty state persists and this review re-arms.
            syncCoordinator.cancelPendingAutomaticSync()
            session.start()
        }
        .alert(
            L10n.text("Couldn’t save that review"),
            isPresented: Binding(
                get: { session.answerError != nil },
                set: { if !$0 { session.answerError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { session.answerError = nil }
        } message: {
            Text(session.answerError ?? "")
        }
        .onChange(of: playAudioInSilentMode) { _, newValue in
            ReviewAudioSession.apply(playInSilent: newValue)
        }
        .onChange(of: accountStore.selectionID) { _, _ in
            // Profile switching drains and revokes the lease in Root before the
            // selection flips. End immediately from the feature side as well so
            // owner-scoped live counts/context cannot leak into the new profile.
            session.end()
        }
        .onChange(of: session.successfulMutationCount) { _, _ in
            // The review engine commits answers outside CollectionStore, so
            // explicitly publish the mutation to the app-level activity rail.
            store.markLocalMutation()
        }
        .onDisappear {
            Task {
                // Keep the session's lease through temporary-deck cleanup so a
                // newly opened review cannot interleave with that engine work.
                await tearDownCompletedSession()
                endReview()
                await WidgetRefreshCoordinator.shared.refreshNow()
            }
        }
    }

    private func endReview() {
        guard !endedSession else { return }
        endedSession = true
        session.end()
        liveCounts.clear(sessionID: session.sessionID)
        // Answer commits happen outside CollectionStore. End-of-review is the
        // durable hand-off point: invalidate deck/count caches exactly once so
        // every consumer reloads the scheduler's final state.
        store.invalidateAll(origin: .localUser)
        // The scheduler lease is released above, so deferred automatic syncs
        // may run again. Flush the session's accumulated mutations now — one
        // sync for the whole sitting instead of attempts interleaved with
        // ratings — and let the scheduled pull catch up if the session
        // outlasted its interval.
        syncCoordinator.resumeAutomaticSyncIfNeeded(reason: "Review session ended")
        syncCoordinator.runScheduledCollectionSyncIfNeeded()
    }

    /// A filtered deck built for one sitting ("Study · …", Custom Study)
    /// goes back to its home decks and leaves the library once the queue
    /// is done. Closing early keeps it so the sitting can be resumed.
    private func dismiss() {
        Task {
            await tearDownCompletedSession()
            onDismiss()
        }
    }

    private func tearDownCompletedSession() async {
        let profile = session.profile
        guard profile.isCurrent(AccountStore.shared.selectedContext),
              session.isFinished,
              !toreDownSession,
              deckId.rawValue != 0
        else { return }
        guard ReviewSessionActivity.shared.beginMutation() else { return }
        defer { ReviewSessionActivity.shared.endMutation() }
        toreDownSession = true
        guard let decks = try? await deckClient.fetchAll() else { return }
        guard profile.isCurrent(AccountStore.shared.selectedContext),
              let deck = decks.first(where: { $0.id == deckId }),
              deck.isFiltered,
              Self.isTemporarySession(deck.name) else { return }
        _ = try? await deckClient.delete(deckId)
        store.invalidateAll(origin: .localUser)
    }

    /// Is this filtered deck one of the app's own study sessions, and so safe
    /// to delete when the session ends?
    ///
    /// Recognized by name, because that is all the engine gives us — a
    /// filtered deck carries no marker beyond the name the app chose. The
    /// names are therefore *data*, not UI copy: they are written into the
    /// collection, compared after relaunch, and matched by
    /// `StudyDeckRow` too. Keep them stable, keep them in
    /// `StudyDeckNaming`, and never run them through the catalog. User-created
    /// filtered decks ("Custom Study Session" and friends) are the app's
    /// other temporary decks and are matched by the same rules.
    private static func isTemporarySession(_ name: String) -> Bool {
        StudyDeckNaming.isTemporarySessionDeck(name)
    }
}

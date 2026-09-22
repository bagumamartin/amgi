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

    @Dependency(\.deckClient) private var deckClient
    @Dependency(\.collectionStore) private var store

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
            session.start()
        }
        .alert(
            "Couldn't save that review",
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
        .onDisappear {
            Task {
                await tearDownCompletedSession()
                await writeWidgetSnapshot()
            }
        }
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
        guard session.isFinished, !toreDownSession, deckId.rawValue != 0 else { return }
        toreDownSession = true
        guard let decks = try? await deckClient.fetchAll(),
              let deck = decks.first(where: { $0.id == deckId }),
              deck.isFiltered,
              Self.isTemporarySession(deck.name) else { return }
        _ = try? await deckClient.delete(deckId)
        store.invalidateAll(origin: .localUser)
    }

    private static func isTemporarySession(_ name: String) -> Bool {
        name == "Custom Study Session" || name.hasPrefix("Study · ")
    }
}

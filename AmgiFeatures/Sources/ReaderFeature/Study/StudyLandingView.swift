package import SwiftUI
import AmgiAppShared
import AmgiReviewCore
import AmgiUI
import AmgiReader
package import AnkiKit
import Dependencies

/// Study tab container. Holds a `StudyLandingModel` that loads the deck tree
/// + reader books and maps to `StudyLandingContent.State`; forwards
/// navigation callbacks to the parent (`RootView`).
package struct StudyLandingView: View {
    /// Called when the user taps a deck row or "Begin Session".
    /// Sets `pendingReviewDeckId` on RootView to trigger the
    /// existing fullscreen cover.
    let onSelectDeck: (DeckID) -> Void

    package init(onSelectDeck: @escaping (DeckID) -> Void) {
        self.onSelectDeck = onSelectDeck
    }

    @Dependency(\.collectionStore) private var store
    @Dependency(\.liveReviewCounts) private var liveCounts
    @State private var model = StudyLandingModel()

    package var body: some View {
        StudyLandingContent(
            state: model.contentState,
            onBeginSession: beginSession,
            onSelectDeck: { id in onSelectDeck(DeckID(id)) },
            onSelectBook: { bookID in model.selectBook(bookID) },
            onRefresh: { await model.load() }
        )
        .navigationTitle("Today")
        .navigationBarTitleDisplayMode(.large)
        .navigationSubtitleIfAvailable(todaySubtitle)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                SyncToolbarButton()
            }
        }
        .sheet(item: $model.selectedBook) { book in
            NavigationStack {
                ChapterListView(book: book, progress: model.progressCoordinator)
            }
        }
        // Keyed on the store's generation: any Invalidation re-runs the
        // load; `.task` cancels itself on disappear.
        .task(id: store.generation) { await model.load() }
        // Keyed on the live review snapshot: repaint the ring's composition
        // as cards are answered, without a deck-tree refetch per answer.
        // A nil snapshot (review dismissed) resets the session anchor so the
        // next session re-anchors on a fresh collection snapshot.
        .task(id: liveCounts.snapshot) {
            if let snapshot = liveCounts.snapshot {
                model.applyLiveCounts(snapshot)
            } else {
                model.clearLiveCounts()
            }
        }
    }

    /// Weekday / due copy that used to sit under the in-content "Today"
    /// hero. Same string, now the navigation subtitle so the large title
    /// matches Library.
    private var todaySubtitle: String {
        if case .loaded(let summary, _, _) = model.contentState {
            summary.subtitleLabel
        } else {
            ""
        }
    }

    private func beginSession() {
        // Launch the virtual all-decks review scope, matching the Library's
        // "Start today's review". The button is only enabled when totalDue > 0.
        guard case .loaded(let summary, _, _) = model.contentState,
              summary.totalDue > 0 else { return }
        onSelectDeck(DeckID(0))
    }
}

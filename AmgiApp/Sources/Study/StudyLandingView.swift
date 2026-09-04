// AmgiApp/Sources/Study/StudyLandingView.swift
import SwiftUI
import AmgiUI
import AmgiReader
import AnkiKit
import Dependencies

/// Study tab container. Holds a `StudyLandingModel` that loads the deck tree
/// + reader books and maps to `StudyLandingContent.State`; forwards
/// navigation callbacks to the parent (`ContentView`).
struct StudyLandingView: View {
    /// Called when the user taps a deck row or "Begin Session".
    /// Sets `pendingReviewDeckId` on ContentView to trigger the
    /// existing fullscreen cover.
    let onSelectDeck: (DeckID) -> Void

    @Dependency(\.collectionStore) private var store
    @Dependency(\.liveReviewCounts) private var liveCounts
    @State private var model = StudyLandingModel()

    /// Account menu (profile switch + settings push). iOS renders it in
    /// the landing header's accessory slot because the navigation bar is
    /// hidden there; macOS gets the standard toolbar placement. Note search
    /// lives in the app's dedicated search surface (.search tab / macOS
    /// toolbar field) — Study needs no query state of its own.
    #if os(iOS)
    @State private var accountDestination: AccountMenuDestination?
    private var headerAccessory: some View {
        ProfilePickerMenu(open: $accountDestination)
            .accountMenuDestinations($accountDestination)
    }
    #endif

    var body: some View {
        #if os(iOS)
        studyContent(
            headerAccessory: headerAccessory
        )
        .toolbar(.hidden, for: .navigationBar)
        #else
        studyContent(headerAccessory: EmptyView())
            .accountMenu()
        #endif
    }

    @ViewBuilder
    private func studyContent<Accessory: View>(headerAccessory: Accessory) -> some View {
        StudyLandingContent(
            state: model.contentState,
            headerAccessory: headerAccessory,
            onBeginSession: beginSession,
            onSelectDeck: { id in onSelectDeck(DeckID(id)) },
            onSelectBook: { bookID in model.selectBook(bookID) },
            onRefresh: { await model.load() }
        )
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

    private func beginSession() {
        // Launch the virtual all-decks review scope, matching the Library's
        // "Start today's review". The button is only enabled when totalDue > 0.
        guard case .loaded(let summary, _, _) = model.contentState,
              summary.totalDue > 0 else { return }
        onSelectDeck(DeckID(0))
    }
}

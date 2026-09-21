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
    /// Called when the user starts a session or a single deck.
    /// Sets `pendingReviewDeckId` on RootView to trigger the
    /// existing fullscreen cover.
    let onSelectDeck: (DeckID) -> Void
    /// Empty collection sends people to Library. Study does not import.
    let onOpenLibrary: () -> Void
    /// Continue-reading is offered only when the Read tab itself is on.
    let showsContinueReading: Bool

    package init(
        onSelectDeck: @escaping (DeckID) -> Void,
        onOpenLibrary: @escaping () -> Void = {},
        showsContinueReading: Bool = false
    ) {
        self.onSelectDeck = onSelectDeck
        self.onOpenLibrary = onOpenLibrary
        self.showsContinueReading = showsContinueReading
    }

    @Dependency(\.collectionStore) private var store
    @Dependency(\.liveReviewCounts) private var liveCounts
    @State private var model = StudyLandingModel()
    @State private var timeRow: StudyTimeRow?

    package var body: some View {
        StudyLandingContent(
            state: model.contentState,
            showsContinueReading: showsContinueReading,
            grain: model.grain,
            chart: model.chart,
            showsTodayDesk: model.showsTodayDesk,
            spanHeadline: model.spanHeadline,
            spanRows: model.spanRows,
            spanRowsLoading: model.spanRowsLoading,
            canStepPast: model.canStepPast,
            canStepFuture: model.canStepFuture,
            onBeginSession: beginSession,
            onSelectDeck: { id in onSelectDeck(DeckID(id)) },
            onSelectBook: { bookID in model.selectBook(bookID) },
            onOpenLibrary: onOpenLibrary,
            onRefresh: { await model.load() },
            onStepPast: { model.step(towardsPast: true) },
            onStepFuture: { model.step(towardsPast: false) },
            onSelectGrain: { model.selectGrain($0) },
            onSelectOffset: { model.selectDay($0) },
            onSelectTimeRow: { timeRow = $0 }
        )
        .navigationTitle(model.spanTitle)
        .navigationBarTitleDisplayMode(.large)
        .navigationSubtitleIfAvailable(navigationSubtitle)
        .navigationDestination(item: $timeRow) { row in
            StudyTimeDetailScreen(row: row, model: model, onOpenDeck: onSelectDeck)
        }
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

    private var navigationSubtitle: String {
        guard model.showsTodayDesk,
              case .loaded(let summary, _, _) = model.contentState else {
            return ""
        }
        return summary.subtitleLabel
    }

    private func beginSession() {
        // Whole-collection queue. The button only exists while cards are
        // answerable, so a caught-up day never lands here.
        guard case .loaded(let summary, _, _) = model.contentState,
              summary.totalDue > 0 else { return }
        onSelectDeck(DeckID(0))
    }
}

/// Pushed from a rating or due row. Owns the sitting size and the
/// reschedule switch; the model only builds the filtered deck.
private struct StudyTimeDetailScreen: View {
    let row: StudyTimeRow
    let model: StudyLandingModel
    let onOpenDeck: (DeckID) -> Void

    @State private var limit: Int
    @State private var reschedules: Bool
    @State private var message: String?
    @State private var busy = false

    init(row: StudyTimeRow, model: StudyLandingModel, onOpenDeck: @escaping (DeckID) -> Void) {
        self.row = row
        self.model = model
        self.onOpenDeck = onOpenDeck
        _limit = State(initialValue: row.count)
        _reschedules = State(initialValue: row.reschedulesByDefault)
    }

    var body: some View {
        StudyTimeDetailContent(
            row: row,
            limit: $limit,
            reschedules: $reschedules,
            isBusy: busy,
            message: message,
            onStudy: study
        )
    }

    private func study() {
        guard row.count > 0, limit > 0 else { return }
        Task {
            busy = true
            let result = await model.study(row: row, limit: limit, reschedule: reschedules)
            busy = false
            if let deckID = result.deckID {
                onOpenDeck(deckID)
            } else {
                message = result.message
            }
        }
    }
}

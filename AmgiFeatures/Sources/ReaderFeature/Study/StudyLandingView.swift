package import SwiftUI
import AmgiAppCore
import AmgiAppShared
import AmgiReviewCore
import AppIntents
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
    /// Today's only remaining cards are cooling. Opens all-decks review
    /// with the learn-ahead window widened for the rest of the day.
    let onPullCooling: () -> Void
    /// Incremented by the root when a widget/deep link explicitly requests
    /// the Today destination.
    let todayRequest: Int
    /// Optional configured widget deck; 0/nil means all decks.
    let todayDeckID: Int64?

    package init(
        onSelectDeck: @escaping (DeckID) -> Void,
        onOpenLibrary: @escaping () -> Void = {},
        showsContinueReading: Bool = false,
        onPullCooling: @escaping () -> Void = {},
        todayRequest: Int = 0,
        todayDeckID: Int64? = nil
    ) {
        self.onSelectDeck = onSelectDeck
        self.onOpenLibrary = onOpenLibrary
        self.showsContinueReading = showsContinueReading
        self.onPullCooling = onPullCooling
        self.todayRequest = todayRequest
        self.todayDeckID = todayDeckID
    }

    @Dependency(\.collectionStore) private var store
    @Dependency(\.liveReviewCounts) private var liveCounts
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = StudyLandingModel()
    @State private var timeRow: StudyTimeRow?

    package var body: some View {
        let profile = AccountStore.shared.selectedContext
        return StudyLandingContent(
            state: model.contentState,
            showsContinueReading: showsContinueReading,
            scopeLabel: model.landingDeckName,
            onShowAllDecks: { Task { await model.showToday(deckID: nil) } },
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
            onSelectOffset: { model.focusDay($0) },
            onSelectTimeRow: { timeRow = $0 },
            onDoCoolingNow: onPullCooling,
            onSelectMonth: { model.selectMonth($0) },
            onExploreHistory: {
                timeRow = nil
                model.selectedBook = nil
                Task { await model.showHistory() }
            },
            forecast: model.forecast,
            todayAttentionRows: model.todayAttentionRows,
            spanDeckRows: model.spanDeckRows,
            spanDeckRowsLoading: model.spanDeckRowsLoading,
            spanDeckTitle: model.spanDeckTitle,
            showsRelevantDecks: model.grain == .day && model.dayOffset != 0,
            spanRowsError: model.spanRowsError,
            spanDeckRowsError: model.spanDeckRowsError,
            workloadError: model.workloadError
        )
        .appEntityIdentifierIfAvailable(forSelectionType: Int64.self) { rawID in
            guard let entity = DeckEntity(
                context: profile,
                deckID: DeckID(rawID),
                name: "Deck"
            ) else { return nil }
            return EntityIdentifier(for: entity)
        }
        .navigationTitle(model.spanTitle)
        .navigationBarTitleDisplayMode(.large)
        .navigationSubtitleIfAvailable(navigationSubtitle)
        .navigationDestination(item: $timeRow) { row in
            StudyTimeDetailScreen(row: row, model: model, onOpenDeck: onSelectDeck)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                SyncToolbarButton()
            }
            if model.showsJump {
                if #available(iOS 26.0, macOS 26.0, *) {
                    ToolbarSpacer(.fixed, placement: .topBarTrailing)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(model.jumpTitle) { model.returnToNow() }
                }
            }
        }
        .sheet(item: $model.selectedBook) { book in
            NavigationStack {
                ReaderBookDetailView(book: book, progress: model.progressCoordinator)
            }
        }
        // Keyed on the store's generation: any Invalidation re-runs the
        // load; `.task` cancels itself on disappear.
        .task(id: store.generation) { await model.load() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await model.load() }
        }
        .task {
            await model.waitForNextRollover()
        }
        // Widgets and explicit Study deep links use the same route. A token
        // makes repeated taps work even when the tab is already selected and
        // resets both the period and any pushed historical detail.
        .task(id: todayRequest) {
            guard todayRequest > 0 else { return }
            timeRow = nil
            model.selectedBook = nil
            await model.showToday(deckID: todayDeckID)
        }
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
        if model.showsTodayDesk,
           case .loaded(let summary, _, _) = model.contentState,
           !summary.subtitleLabel.isEmpty {
            return summary.subtitleLabel
        }
        return model.spanSubtitle
    }

    private func beginSession() {
        // Use the active deck scope when a configured widget opened this desk;
        // otherwise start the collection-wide queue. The button only exists
        // while cards are answerable, so a caught-up day never lands here.
        guard case .loaded(let summary, _, _) = model.contentState,
              summary.totalDue > 0 else { return }
        onSelectDeck(DeckID(model.landingDeckID ?? 0))
    }
}

/// Pushed from a chart row. Owns the sitting size, the deck scope, and
/// the reschedule switch. The model only counts and builds the filtered deck.
private struct StudyTimeDetailScreen: View {
    let row: StudyTimeRow
    let model: StudyLandingModel
    let onOpenDeck: (DeckID) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var limit: Int
    @State private var reschedules: Bool
    @State private var matchCount: Int
    @State private var deckID: Int64 = StudyDeckChoice.all.id
    @State private var includeSubdecks = true
    @State private var decks: [StudyDeckChoice] = [.all]
    @State private var message: String?
    @State private var busy = false

    init(row: StudyTimeRow, model: StudyLandingModel, onOpenDeck: @escaping (DeckID) -> Void) {
        self.row = row
        self.model = model
        self.onOpenDeck = onOpenDeck
        _limit = State(initialValue: row.count)
        _matchCount = State(initialValue: row.count)
        _reschedules = State(initialValue: row.reschedulesByDefault)
        _deckID = State(initialValue: row.initialDeckID ?? StudyDeckChoice.all.id)
        var initialDecks: [StudyDeckChoice] = [.all]
        if let deckID = row.initialDeckID, let fullName = row.deckFullName {
            initialDecks.append(StudyDeckChoice(
                id: deckID,
                title: fullName.replacingOccurrences(of: "::", with: " · "),
                fullName: fullName
            ))
        }
        _decks = State(initialValue: initialDecks)
    }

    var body: some View {
        StudyTimeDetailContent(
            row: row,
            matchCount: matchCount,
            decks: decks,
            deckID: $deckID,
            includeSubdecks: $includeSubdecks,
            limit: $limit,
            reschedules: $reschedules,
            isBusy: busy,
            message: message,
            onScopeChange: { Task { await recount() } },
            onStudy: study,
            onBrowse: {
                BrowseLauncher.shared.launch(query: activeSearch)
                dismiss()
            }
        )
        .task {
            decks = await model.deckChoices()
            // Recount even for collection-wide rows. This keeps the displayed
            // total aligned with the exact search and prevents a stale graph
            // hint from masquerading as a detail result.
            await recount()
        }
    }

    private var activeSearch: String {
        let name = decks.first { $0.id == deckID }?.fullName
            ?? row.deckFullName
            ?? ""
        return StudySpan.scopedSearch(row.search, deckFullName: name, includeSubdecks: includeSubdecks)
    }

    private func recount() async {
        busy = true
        defer { busy = false }
        guard let count = await model.matchCount(activeSearch) else {
            message = "The card count couldn't be loaded. Pull to refresh or try again."
            return
        }
        matchCount = count
        limit = max(count, 1)
        message = nil
    }

    private func study() {
        guard matchCount > 0, limit > 0 else { return }
        let search = activeSearch
        Task {
            busy = true
            let result = await model.study(search: search, limit: limit, reschedule: reschedules)
            busy = false
            if let deckID = result.deckID {
                dismiss()
                onOpenDeck(deckID)
            } else {
                message = result.message
            }
        }
    }
}

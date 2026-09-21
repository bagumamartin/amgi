import OSLog
import AmgiAppCore
import AmgiAppShared
import AmgiReader
import AmgiReviewCore
import AmgiUI
import AnkiClients
import AnkiKit
import Dependencies
import Foundation

/// Data loading for the study landing screen. Owns the deck + reader-book
/// clients, the progress coordinator, the mapped `StudyLandingContent.State`,
/// and the book-sheet selection so the Container carries no `@Dependency`;
/// the Container keeps only its navigation callback and load-task lifecycle.
@Observable
@MainActor
final class StudyLandingModel {
    var contentState: StudyLandingState = .loading
    var selectedBook: ReaderBook?
    var extraStudyError: String?
    var extraStudyBusyID: String?

    let progressCoordinator = ReaderProgressCoordinator()

    /// Whole-collection counts captured when the active review session began.
    /// The live ring composition is derived from this anchor so the segments
    /// move as cards are answered without refetching the deck tree per answer.
    private var liveAnchorCounts: DeckCounts?
    private var liveSessionID: UUID?

    @ObservationIgnored @Dependency(\.readerBookClient) private var readerBookClient
    @ObservationIgnored @Dependency(\.collectionStore) private var store
    @ObservationIgnored @Dependency(\.statsClient) private var statsClient
    @ObservationIgnored @Dependency(\.deckClient) private var deckClient

    private var loadToken = 0

    func load() async {
        loadToken += 1
        let token = loadToken
        let hadContent: Bool
        if case .loaded = contentState { hadContent = true } else { hadContent = false }
        do {
            // 1. Deck tree → top-level decks only. Parent counts already
            //    aggregate descendants, so a deck with due subdecks still
            //    surfaces. Subdeck names become a caption, not nested rows.
            let tree = try await store.tree()
            guard token == loadToken else { return }
            guard !tree.isEmpty else {
                contentState = .empty
                return
            }

            let deckRows = tree
                .filter { $0.counts.total > 0 }
                .sorted { $0.counts.total > $1.counts.total }
                .map { Self.makeDeckRow(from: $0) }

            // 2. Answerable counts are the tree. Learning cards due later
            //    today sit outside the learn-ahead window, so they are a
            //    note — not part of the ring — or "due now" would include
            //    cards the reviewer will not show yet.
            let totalDue = tree.reduce(0) { $0 + $1.counts.total }
            let totalNew = tree.reduce(0) { $0 + $1.counts.newCount }
            let treeLearn = tree.reduce(0) { $0 + $1.counts.learnCount }
            let learningToday = (try? await statsClient.learningDueToday(search: "")) ?? treeLearn
            let learningReturning = max(0, learningToday - treeLearn)
            let totalReview = tree.reduce(0) { $0 + $1.counts.reviewCount }
            let deckCount = tree.filter { $0.counts.total > 0 }.count
            guard token == loadToken else { return }

            let weekday = Date().formatted(.dateTime.weekday(.wide))
            let subtitleLabel = deckCount == 0
                ? weekday
                : "\(weekday) · \(deckCount) deck\(deckCount == 1 ? "" : "s") due"
            let dayProgress = await resolveCollectionProgress(totalDue: totalDue)
            guard token == loadToken else { return }

            // Carry streak/forecast across a refresh so the second phase
            // doesn't flash back to a placeholder.
            let carried = carriedSummary
            let summary = StudySummaryData(
                totalDue: totalDue,
                newCount: totalNew,
                learnCount: treeLearn,
                reviewCount: totalReview,
                todayLabel: "Today",
                subtitleLabel: subtitleLabel,
                deckCount: deckCount,
                reviewedToday: dayProgress.reviewedToday,
                dueBaselineToday: dayProgress.dueBaselineToday,
                learningReturning: learningReturning,
                answerCount: carried?.answerCount ?? 0,
                answerMillis: carried?.answerMillis ?? 0,
                streak: carried?.streak ?? 0,
                streakPending: carried == nil,
                tomorrowDue: carried?.tomorrowDue,
                backlogNote: carried?.backlogNote,
                rolloverNote: carried?.rolloverNote
            )

            let continueReading = totalDue == 0 ? await loadContinueReading() : nil
            guard token == loadToken else { return }
            contentState = .loaded(summary: summary, decks: deckRows, continueReading: continueReading)

            await DeckIconLookup.refresh?()
            var iconRows = deckRows
            await Self.attachIconNames(to: &iconRows)
            guard token == loadToken else { return }
            if case .loaded(let refreshedSummary, _, let refreshedReading) = contentState {
                contentState = .loaded(
                    summary: refreshedSummary,
                    decks: iconRows,
                    continueReading: refreshedReading
                )
            }

            await loadActivity(token: token)
        } catch {
            Log.reader.error("Error loading: \(error)")
            guard token == loadToken, !hadContent else { return }
            contentState = .failed(error.localizedDescription)
        }
    }

    /// Builds a filtered deck for a caught-up action and returns its id
    /// once it actually gathered cards.
    func beginExtraStudy(_ action: StudyKeepGoingAction) async -> DeckID? {
        extraStudyBusyID = action.id
        extraStudyError = nil
        defer { extraStudyBusyID = nil }
        do {
            let spec = FilteredDeckSpec(
                name: action.deckName,
                search: action.search,
                limit: action.limit,
                order: .due,
                reschedule: action.reschedule
            )
            let created = try await deckClient.createFilteredDeck(spec)
            let gathered = try await deckClient.rebuildFilteredDeck(created.id)
            guard gathered > 0 else {
                extraStudyError = "No cards matched."
                return nil
            }
            store.invalidateAll(origin: .localUser)
            return created.id
        } catch {
            Log.reader.error("Extra study failed: \(error)")
            extraStudyError = "Couldn't start \(action.title.lowercased())."
            return nil
        }
    }

    private var carriedSummary: StudySummaryData? {
        if case .loaded(let summary, _, _) = contentState { return summary }
        return nil
    }

    /// Streak, time studied, tomorrow, and the rollover note. Published
    /// onto whatever summary is current so a live review repaint in
    /// between isn't overwritten with the pre-session counts.
    private func loadActivity(token: Int) async {
        let graphs = try? await statsClient.fetchGraphs("", 28)
        guard token == loadToken, case .loaded(let summary, let decks, let reading) = contentState else { return }
        let updated: StudySummaryData
        if let graphs {
            updated = summary.withActivity(
                answerCount: graphs.today.answerCount,
                answerMillis: graphs.today.answerMillis,
                streak: StreakCalculator.streak(reviews: graphs.reviews.count),
                tomorrowDue: graphs.futureDue.futureDue[1] ?? 0,
                backlogNote: StudySummaryData.backlogNote(haveBacklog: graphs.futureDue.haveBacklog),
                rolloverNote: AnkiDay.rolloverNote(now: Date(), rolloverHour: graphs.rolloverHour)
            )
        } else if summary.streakPending {
            updated = summary.withActivity(
                answerCount: summary.answerCount,
                answerMillis: summary.answerMillis,
                streak: summary.streak,
                tomorrowDue: summary.tomorrowDue ?? 0,
                backlogNote: summary.backlogNote,
                rolloverNote: summary.rolloverNote
            )
        } else {
            return
        }
        contentState = .loaded(summary: updated, decks: decks, continueReading: reading)
    }

    func selectBook(_ bookID: String) {
        guard let configuration = ReaderConfigurationLoader.loadConfiguration() else { return }
        Task {
            if let book = try? await readerBookClient.loadBook(bookID, configuration) {
                selectedBook = book
            }
        }
    }

    /// Repaints the ring's new/learning/review composition from the live
    /// session without a full deck-tree refetch. The ring always shows the
    /// whole collection: subtract the session's baseline from the pre-session
    /// anchor, then add the session's live counts. The day-progress arc,
    /// deck rows, and reading recommendations stay on the last full snapshot.
    func applyLiveCounts(_ snapshot: LiveReviewSnapshot) {
        guard case .loaded(let summary, let decks, let continueReading) = contentState else { return }
        if liveSessionID != snapshot.sessionID {
            liveAnchorCounts = DeckCounts(
                newCount: summary.newCount,
                learnCount: summary.learnCount,
                reviewCount: summary.reviewCount
            )
            liveSessionID = snapshot.sessionID
        }
        guard let anchor = liveAnchorCounts else { return }

        let whole = DeckCounts(
            newCount: max(0, anchor.newCount - snapshot.baseline.newCount) + snapshot.live.newCount,
            learnCount: max(0, anchor.learnCount - snapshot.baseline.learnCount) + snapshot.live.learnCount,
            reviewCount: max(0, anchor.reviewCount - snapshot.baseline.reviewCount) + snapshot.live.reviewCount
        )

        contentState = .loaded(
            summary: summary.withLiveCounts(
                totalDue: whole.total,
                newCount: whole.newCount,
                learnCount: whole.learnCount,
                reviewCount: whole.reviewCount
            ),
            decks: decks,
            continueReading: continueReading
        )
    }

    /// Forgets the live-session anchor. The next full `load()` (triggered by
    /// the review-end generation bump) restores a fresh whole-collection
    /// snapshot, so the displayed ring keeps its last accurate state in the
    /// interim.
    func clearLiveCounts() {
        liveSessionID = nil
        liveAnchorCounts = nil
    }

    /// Maps a top-level deck. Due children are a caption, not rows.
    private static func makeDeckRow(from node: DeckTreeNode) -> StudyDeckRowData {
        StudyDeckRowData(
            id: node.id.rawValue,
            name: node.name,
            totalDue: node.counts.total,
            newCount: node.counts.newCount,
            learnCount: node.counts.learnCount,
            reviewCount: node.counts.reviewCount,
            isFiltered: node.isFiltered,
            includesLabel: includesLabel(for: node),
            iconName: DeckIconLookup.initialIcon?(node.id.rawValue, node.name)
        )
    }

    private static func includesLabel(for node: DeckTreeNode) -> String? {
        let names = node.children
            .filter { $0.counts.total > 0 }
            .sorted { $0.counts.total > $1.counts.total }
            .map(\.name)
        guard !names.isEmpty else { return nil }
        let shown = names.prefix(3).joined(separator: ", ")
        if names.count > 3 {
            return "Includes \(shown)…"
        }
        return "Includes \(shown)"
    }

    /// Recursively resolves icons for every row (top-level decks and nested
    /// subdecks alike). Study rows carry only the leaf name — suggestions
    /// derive from it; manual overrides are id-keyed and unaffected.
    private static func attachIconNames(to rows: inout [StudyDeckRowData]) async {
        for index in rows.indices {
            let row = rows[index]
            let iconName = await DeckIconLookup.resolvedIcon?(
                row.id,
                row.name,
                row.name
            )
            var subdecks = row.subdecks
            await attachIconNames(to: &subdecks)
            if iconName != row.iconName || subdecks != row.subdecks {
                rows[index] = StudyDeckRowData(
                    id: row.id,
                    name: row.name,
                    totalDue: row.totalDue,
                    newCount: row.newCount,
                    learnCount: row.learnCount,
                    reviewCount: row.reviewCount,
                    isFiltered: row.isFiltered,
                    subdecks: subdecks,
                    includesLabel: row.includesLabel,
                    iconName: iconName
                )
            }
        }
    }

    private func resolveCollectionProgress(totalDue: Int) async -> (reviewedToday: Int, dueBaselineToday: Int) {
        do {
            let completedToday = try await statsClient.graduatedToday(search: "")
            // Live denominator (completed + remaining) rather than a frozen
            // baseline, so the ring can't read 100% while cards are still due.
            let baseline = max(completedToday + totalDue, 1)
            return (completedToday, baseline)
        } catch {
            return (0, max(totalDue, 1))
        }
    }

    /// The book opened most recently, only when it has saved progress.
    private func loadContinueReading() async -> StudyReadingRecData? {
        guard let configuration = ReaderConfigurationLoader.loadConfiguration(),
              let books = try? await readerBookClient.loadBooks(configuration) else {
            return nil
        }

        var best: (book: ReaderBook, at: Date)?
        for book in books {
            guard let at = await progressCoordinator.resolved(bookID: book.id)?.updatedAt else { continue }
            if let current = best {
                if at > current.at { best = (book, at) }
            } else {
                best = (book, at)
            }
        }
        guard let best else { return nil }
        return StudyReadingRecData(
            id: best.book.id,
            title: best.book.title,
            coverImagePath: best.book.coverImagePath,
            authorLabel: best.book.author ?? ""
        )
    }
}

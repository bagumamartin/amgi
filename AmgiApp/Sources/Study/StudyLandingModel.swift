import AmgiReader
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
    var contentState: StudyLandingContent.State = .loading
    var selectedBook: ReaderBook?

    let progressCoordinator = ReaderProgressCoordinator()

    /// Whole-collection counts captured when the active review session began.
    /// The live ring composition is derived from this anchor so the segments
    /// move as cards are answered without refetching the deck tree per answer.
    private var liveAnchorCounts: DeckCounts?
    private var liveSessionID: UUID?

    @ObservationIgnored @Dependency(\.readerBookClient) private var readerBookClient
    @ObservationIgnored @Dependency(\.collectionStore) private var store
    @ObservationIgnored @Dependency(\.statsClient) private var statsClient

    func load() async {
        do {
            // 1. Deck tree → top-level decks only, with subdecks nested.
            //    Parent counts already aggregate descendants in `deck_tree`,
            //    so a deck with due subdecks still surfaces with a due count.
            let tree = try await store.tree()
            guard !tree.isEmpty else {
                contentState = .empty
                return
            }

            let deckRows = tree
                .filter { $0.counts.total > 0 }
                .sorted { $0.counts.total > $1.counts.total }
                .map { Self.makeDeckRow(from: $0) }

            // 2. Summary counts mirror the Library hero: sum top-level nodes
            //    only. Each node's counts already include its descendants
            //    (Anki aggregates children into parents in `deck_tree`), so
            //    summing the flattened tree would double-count subdecks.
            let totalDue = tree.reduce(0) { $0 + $1.counts.total }
            let totalNew = tree.reduce(0) { $0 + $1.counts.newCount }
            let totalLearn = tree.reduce(0) { $0 + $1.counts.learnCount }
            let totalReview = tree.reduce(0) { $0 + $1.counts.reviewCount }
            let deckCount = tree.filter { $0.counts.total > 0 }.count

            // 3. Build subtitle label from current weekday + deck count
            let weekday = Date().formatted(.dateTime.weekday(.wide))
            let subtitleLabel: String
            if deckCount == 0 {
                subtitleLabel = weekday
            } else {
                subtitleLabel = "\(weekday) · \(deckCount) deck\(deckCount == 1 ? "" : "s") due"
            }

            // 3b. Resolve collection-wide daily progress for the ring. The
            //     baseline is frozen at the first observation of today's Anki
            //     day so the arc stays stable across the whole day.
            let dayProgress = await resolveCollectionProgress(totalDue: totalDue)

            let summary = StudySummaryData(
                totalDue: totalDue,
                newCount: totalNew,
                learnCount: totalLearn,
                reviewCount: totalReview,
                todayLabel: "Today",
                subtitleLabel: subtitleLabel,
                deckCount: deckCount,
                reviewedToday: dayProgress.reviewedToday,
                dueBaselineToday: dayProgress.dueBaselineToday
            )

            // 4. Books → sort by lastRead desc → take 8 → map to DTO
            let readingRecs = await loadReadingRecs()

            contentState = .loaded(summary: summary, decks: deckRows, readingRecs: readingRecs)

            // 5. Icons paint progressively: manual overrides are dictionary
            //    lookups, semantic suggestions are RPC-backed per row. Same
            //    paint-then-refine pattern as Library.
            await DeckIconOverrides.refresh()
            var iconRows = deckRows
            await Self.attachIconNames(to: &iconRows)
            if case .loaded(let refreshedSummary, _, let refreshedRecs) = contentState {
                contentState = .loaded(
                    summary: refreshedSummary,
                    decks: iconRows,
                    readingRecs: refreshedRecs
                )
            }
        } catch {
            print("[StudyLandingModel] Error loading: \(error)")
            contentState = .empty
        }
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
        guard case .loaded(let summary, let decks, let readingRecs) = contentState else { return }
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
            summary: StudySummaryData(
                totalDue: whole.total,
                newCount: whole.newCount,
                learnCount: whole.learnCount,
                reviewCount: whole.reviewCount,
                todayLabel: summary.todayLabel,
                subtitleLabel: summary.subtitleLabel,
                deckCount: summary.deckCount,
                reviewedToday: summary.reviewedToday,
                dueBaselineToday: summary.dueBaselineToday
            ),
            decks: decks,
            readingRecs: readingRecs
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

    /// Recursively maps a `DeckTreeNode` to view data. The top-level list
    /// shows only this node's own `name` (last path segment), with its due
    /// subdecks nested underneath — never the `parent::child` full path.
    private static func makeDeckRow(from node: DeckTreeNode) -> StudyDeckRowData {
        StudyDeckRowData(
            id: node.id.rawValue,
            name: node.name,
            totalDue: node.counts.total,
            newCount: node.counts.newCount,
            learnCount: node.counts.learnCount,
            reviewCount: node.counts.reviewCount,
            isFiltered: node.isFiltered,
            subdecks: node.children
                .filter { $0.counts.total > 0 }
                .sorted { $0.counts.total > $1.counts.total }
                .map { makeDeckRow(from: $0) },
            // Manual overrides + cached suggestions paint instantly.
            iconName: DeckIconOverrides.initialIcon(deckId: node.id.rawValue, name: node.name)
        )
    }

    /// Recursively resolves icons for every row (top-level decks and nested
    /// subdecks alike). Study rows carry only the leaf name — suggestions
    /// derive from it; manual overrides are id-keyed and unaffected.
    private static func attachIconNames(to rows: inout [StudyDeckRowData]) async {
        for index in rows.indices {
            let row = rows[index]
            let iconName = await DeckIconOverrides.resolvedIcon(
                deckId: row.id,
                name: row.name
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

    private func loadReadingRecs() async -> [StudyReadingRecData] {
        guard let configuration = ReaderConfigurationLoader.loadConfiguration(),
              let books = try? await readerBookClient.loadBooks(configuration) else {
            return []
        }

        var lastRead: [String: Date] = [:]
        for book in books {
            lastRead[book.id] = await progressCoordinator.resolved(bookID: book.id)?.updatedAt
        }

        return books
            .sorted { lhs, rhs in
                (lastRead[lhs.id] ?? .distantPast) > (lastRead[rhs.id] ?? .distantPast)
            }
            .prefix(8)
            .map { book in
                StudyReadingRecData(
                    id: book.id,
                    title: book.title,
                    coverImagePath: book.coverImagePath,
                    authorLabel: ""
                )
            }
    }
}

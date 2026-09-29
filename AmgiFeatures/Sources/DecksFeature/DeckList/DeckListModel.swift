import OSLog
import AmgiUI
import AmgiAppCore
import AmgiAppShared
import AnkiClients
import AnkiKit
import Dependencies
import Foundation

/// Data state + load/mutation logic for the Library screen. Mirrors
/// `DeckDetailModel`: the View owns navigation, sheets, and the toolbar,
/// while the model owns I/O and the engine → view-data assembly so that
/// assembly is testable in isolation and the View stays a thin
/// presentation wiring layer.
@Observable
@MainActor
final class DeckListModel {
    var state: LibraryListContent.State = .loading

    /// Unsorted collection-order rows. View state is a sorted projection —
    /// keep the source so changing `DeckSortOrder` does not refetch the tree.
    private var deckRows: [DeckListRow] = []
    private var lastSortOrder: DeckSortOrder = .mostUsed
    private var usageRanks: [Int64: DeckUsageRank] = [:]
    /// Per-deck daily new limits for the new-wall signal, keyed by deck.
    /// Best-effort enrichment fetched off the critical path (at most 4
    /// decks per load); absent means unknown, never zero.
    private var newPerDayLimits: [DeckID: Int] = [:]
    /// Guards the fill-missing background rank fetch so concurrent loads
    /// don't stack duplicate fetches.
    private var backgroundRankFetchInFlight = false
    /// Top-level decks whose every card is suspended. Default and filtered
    /// decks are never included, even when parked.
    private var archivedDeckIDs: Set<DeckID> = []

    @ObservationIgnored @Dependency(\.deckClient) private var deckClient
    @ObservationIgnored @Dependency(\.statsClient) private var statsClient
    @ObservationIgnored @Dependency(\.cardClient) private var cardClient
    @ObservationIgnored @Dependency(\.collectionStore) private var store

    /// Two phase, deliberately. The deck rows and the hero's due counts come
    /// straight from the deck tree; the streak, sparkline, and heatmap need a
    /// 365-day revlog scan. Publishing both together meant the primary content
    /// waited on the secondary — a blank screen at launch on a large
    /// collection. Rows go out first, activity fills in.
    func load() async {
        await load(sortOrder: lastSortOrder)
    }

    func load(sortOrder: DeckSortOrder) async {
        lastSortOrder = sortOrder
        await AppSignpost.measure("DeckListLoad") { await loadBody() }
    }

    /// Re-projects `deckRows` under a new order without refetching the tree.
    /// `mostUsed` lazily pulls revlog ranks if this session has not yet.
    func resort(sortOrder: DeckSortOrder) {
        lastSortOrder = sortOrder
        guard !deckRows.isEmpty, case .loaded(_, let hero, let heatmap, _) = state else { return }
        if sortOrder == .mostUsed && usageRanks.isEmpty {
            Task {
                usageRanks = await fetchUsageRanks(for: deckRows)
                guard lastSortOrder == .mostUsed else { return }
                republishLoaded()
            }
        }
        publishLoaded(hero: hero, heatmap: heatmap)
    }

    private func loadBody() async {
        // Carry the previous activity data through a refresh rather than
        // flashing placeholders over numbers that are still on screen.
        // Triage needs no carrying: phase one recomputes it from the
        // stored ranks, which persist across loads.
        let carried: (hero: HeroData, heatmap: HeatmapCardData?)?
        if case .loaded(_, let hero, let heatmap, _) = state {
            carried = (hero, heatmap)
        } else {
            carried = nil
        }

        await DeckIconOverrides.refresh()

        do {
            // Separates engine wait from Swift assembly. Phase one measured
            // 145 ms in-app but only 0.44 ms against stubbed clients
            // (DeckListLoadPerformanceTests), so the cost has to be in here —
            // and it is I/O-bound, which is why the CPU profile barely sees it.
            let tree = try await AppSignpost.measure("DeckTreeFetch") {
                try await store.tree()
            }
            if tree.isEmpty {
                deckRows = []
                usageRanks = [:]
                archivedDeckIDs = []
                state = .empty
                return
            }
            deckRows = tree.map(DeckListRow.init(node:))
            archivedDeckIDs = await fetchArchivedDeckIDs(for: deckRows)
            let totalDue = deckRows.reduce(0) { $0 + $1.counts.total }
            publishLoaded(
                hero: HeroData(
                    totalDue: totalDue,
                    deckCount: reviewableDeckCount,
                    streak: carried?.hero.streak ?? 0,
                    recentDayTotals: carried?.hero.recentDayTotals
                        ?? Array(repeating: 0, count: HeroData.sparklineCapacity)
                ),
                heatmap: carried?.heatmap
            )

            // Nested inside DeckListLoad on purpose: phase one (the deck
            // tree) and phase two (a 365-day revlog scan) have very
            // different costs, and a single interval hides which one the
            // launch path is actually waiting on. Usage ranks for Most used
            // ride alongside so the first paint is not gated on them. The
            // new-limit reads are bounded (top 4 wall candidates) and land
            // here for the same reason.
            let rows = deckRows
            async let activity = AppSignpost.measure("DeckListActivity") {
                await self.buildHeroAndHeatmap(rows: rows)
            }
            async let ranks = usageRanks(neededFor: lastSortOrder, rows: rows)
            async let limits = newPerDayLimits(for: rows)
            let (hero, heatmap) = await activity
            usageRanks = await ranks
            newPerDayLimits = await limits
            guard !Task.isCancelled else { return }
            publishLoaded(hero: hero, heatmap: heatmap)
            ensureBackgroundRanks(rows: rows)
            Task { await refineRowIcons() }
        } catch {
            Log.decks.error("Error loading decks: \(error)")
            // NOT .empty — that is the genuine no-decks state, and rendering a
            // failure as it told users with a full collection they had none.
            state = .failed(error.localizedDescription)
        }
    }

    /// Semantic suggestions stream in per row after first paint.
    func refineRowIcons() async {
        guard case .loaded(let rows, let hero, let heatmap, _) = state else { return }
        var updated = rows
        var changed = false
        for index in updated.indices {
            let row = updated[index]
            let resolved = await DeckIconOverrides.resolvedIcon(
                deckId: row.id,
                name: row.name,
                fullName: row.fullName
            )
            guard resolved != row.iconName else { continue }
            updated[index] = row.updatingIconName(resolved)
            changed = true
        }
        if changed {
            // Triage rows carry the same `DeckRowViewData` values, so the
            // refined icons must flow through — recompute over the updated
            // rows rather than carrying a stale payload.
            state = .loaded(
                rows: updated,
                hero: hero,
                heatmap: heatmap,
                triage: classifiedTriage(for: updated)
            )
        }
    }

    func delete(_ id: DeckID) async {
        do {
            let changes = try await deckClient.delete(id)
            store.apply(changes)   // generation bump → the view's .task(id:) reloads
        } catch {
            Log.decks.error("Delete failed: \(error)")
            await load()           // error path: no invalidation happened, reload manually
        }
    }

    /// First loaded deck that has cards waiting, projected to a `DeckInfo`
    /// for navigation. Nil while loading/empty or when nothing is due.
    func firstReviewableDeck() -> DeckInfo? {
        guard !deckRows.isEmpty else { return nil }
        let sorted = DeckSorting.libraryRows(deckRows, order: lastSortOrder, ranks: usageRanks)
        return sorted.first(where: {
            $0.counts.total > 0 && !archivedDeckIDs.contains($0.id)
        })?.asDeckInfo
    }

    private func publishLoaded(hero: HeroData, heatmap: HeatmapCardData?) {
        let existingIcons: [Int64: String?] = {
            guard case .loaded(let rows, _, _, _) = state else { return [:] }
            return Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.iconName) })
        }()
        let sorted = DeckSorting.libraryRows(deckRows, order: lastSortOrder, ranks: usageRanks)
        let viewRows = sorted.map { row in
            var viewData = row.viewData(isArchived: archivedDeckIDs.contains(row.id))
            if let existing = existingIcons[row.id.rawValue] {
                viewData.iconName = existing
            } else {
                viewData.iconName = DeckIconOverrides.initialIcon(
                    deckId: row.id.rawValue,
                    name: row.name,
                    fullName: row.fullName
                )
            }
            return viewData
        }
        state = .loaded(
            rows: viewRows,
            hero: hero,
            heatmap: heatmap,
            triage: classifiedTriage(for: viewRows)
        )
    }

    /// Single source for the card payload: phase one, phase two, `resort`,
    /// and icon refinement all classify from the same stored inputs.
    private func classifiedTriage(for viewRows: [DeckRowViewData]) -> DeckTriageData {
        DeckTriage.data(
            rows: viewRows,
            ranks: usageRanks,
            archived: archivedDeckIDs,
            newPerDay: newPerDayLimits
        )
    }

    private func republishLoaded() {
        guard case .loaded(_, let hero, let heatmap, _) = state else { return }
        publishLoaded(hero: hero, heatmap: heatmap)
    }

    private func usageRanks(
        neededFor sortOrder: DeckSortOrder,
        rows: [DeckListRow]
    ) async -> [Int64: DeckUsageRank] {
        guard sortOrder == .mostUsed else { return usageRanks }
        return await fetchUsageRanks(for: rows)
    }

    private func fetchUsageRanks(for rows: [DeckListRow]) async -> [Int64: DeckUsageRank] {
        await DeckUsageRanking.ranks(
            for: rows.map { (id: $0.id, fullName: $0.fullName) },
            statsClient: statsClient
        )
    }

    /// Daily new limits for the new-wall signal. Only decks that already
    /// pass the count pre-filter are worth a backend round trip, biggest
    /// first, capped — the bound is the whole point (see the perf guard).
    /// Best-effort: a failure leaves the limit unknown and the deck simply
    /// doesn't qualify, rather than inventing a projection.
    private func newPerDayLimits(for rows: [DeckListRow]) async -> [DeckID: Int] {
        let limits = DeckTriage.Limits()
        let candidates = rows
            .filter {
                !$0.isFiltered
                    && !archivedDeckIDs.contains($0.id)
                    && $0.counts.newCount >= limits.newWallMinimum
            }
            .sorted { $0.counts.newCount > $1.counts.newCount }
            .prefix(limits.maxVisibleItems)
        let deckClient = self.deckClient
        return await withTaskGroup(of: (DeckID, Int?).self) { group in
            for row in candidates {
                group.addTask {
                    let perDay = try? await deckClient.getDeckConfig(row.id)
                    return (row.id, perDay?.config.newPerDay)
                }
            }
            var out: [DeckID: Int] = [:]
            for await (id, perDay) in group {
                if let perDay { out[id] = perDay }
            }
            return out
        }
    }

    /// Fills ranks for rows that lack them without gating any paint. Under
    /// a non-default sort the phase-two fetch is skipped, which would leave
    /// the triage card permanently degraded; this backfills in the
    /// background instead of paying N extra calls on the load path.
    /// Self-limiting: once every row has a rank there is nothing to do.
    private func ensureBackgroundRanks(rows: [DeckListRow]) {
        guard !backgroundRankFetchInFlight else { return }
        let missing = rows.filter { usageRanks[$0.id.rawValue] == nil }
        guard !missing.isEmpty else { return }
        backgroundRankFetchInFlight = true
        Task {
            let fetched = await fetchUsageRanks(for: missing)
            for (key, rank) in fetched { usageRanks[key] = rank }
            backgroundRankFetchInFlight = false
            republishLoaded()
        }
    }

    static func buildHeatmap(
        reviews: [Int: ReviewCountsAndTimes.Reviews]
    ) -> HeatmapCardData {
        var counts: [Int: Int] = [:]
        var maxCount = 1
        for (offset, rev) in reviews where offset >= -364 && offset <= 0 {
            let total = rev.learn + rev.relearn + rev.young + rev.mature + rev.filtered
            if total > 0 {
                counts[offset] = total
                if total > maxCount { maxCount = total }
            }
        }
        return HeatmapCardData(counts: counts, maxCount: maxCount)
    }
}

private extension DeckListModel {
    var reviewableDeckCount: Int {
        deckRows.reduce(0) { $0 + (archivedDeckIDs.contains($1.id) ? 0 : 1) }
    }

    func fetchArchivedDeckIDs(for rows: [DeckListRow]) async -> Set<DeckID> {
        await DeckArchiving.archivedIDs(
            in: rows.map {
                DeckArchiving.Item(
                    id: $0.id,
                    fullName: $0.fullName,
                    isFiltered: $0.isFiltered,
                    dueCount: $0.counts.total
                )
            },
            using: cardClient
        )
    }

    func buildHeroAndHeatmap(rows: [DeckListRow]) async -> (HeroData, HeatmapCardData) {
        let totalDue = rows.reduce(0) { $0 + $1.counts.total }
        let deckCount = reviewableDeckCount
        // Window the streak over the same range we fetch, or the default
        // 28 silently caps a year's worth of data at 28 days.
        let graphDays = 365
        guard let graphs = try? await statsClient.fetchGraphs("", graphDays) else {
            return (
                HeroData(
                    totalDue: totalDue,
                    deckCount: deckCount,
                    streak: 0,
                    recentDayTotals: Array(repeating: 0, count: HeroData.sparklineCapacity)
                ),
                HeatmapCardData.empty
            )
        }
        let reviewCounts = graphs.reviews.count
        let today = graphs.today
        let trueRetention = graphs.trueRetention.today
        let hero = HeroData(
            totalDue: totalDue,
            deckCount: deckCount,
            streak: StreakCalculator.streak(reviews: reviewCounts, window: graphDays),
            recentDayTotals: StreakCalculator.lastNDaysTotals(reviews: reviewCounts, days: HeroData.sparklineCapacity),
            today: HeroTodayStats(
                studied: today.answerCount,
                timeMillis: today.answerMillis,
                retentionPassed: trueRetention.youngPassed + trueRetention.maturePassed,
                retentionTotal: trueRetention.youngPassed + trueRetention.youngFailed
                    + trueRetention.maturePassed + trueRetention.matureFailed
            )
        )
        return (hero, Self.buildHeatmap(reviews: reviewCounts))
    }
}

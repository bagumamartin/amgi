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

    @ObservationIgnored @Dependency(\.deckClient) private var deckClient
    @ObservationIgnored @Dependency(\.statsClient) private var statsClient
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
        guard !deckRows.isEmpty, case .loaded(_, let hero, let heatmap) = state else { return }
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
        let carried: (hero: HeroData, heatmap: HeatmapCardData?)?
        if case .loaded(_, let hero, let heatmap) = state {
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
                state = .empty
                return
            }
            deckRows = tree.map(DeckListRow.init(node:))
            let totalDue = deckRows.reduce(0) { $0 + $1.counts.total }
            publishLoaded(
                hero: HeroData(
                    totalDue: totalDue,
                    deckCount: deckRows.count,
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
            // ride alongside so the first paint is not gated on them.
            let rows = deckRows
            async let activity = AppSignpost.measure("DeckListActivity") {
                await self.buildHeroAndHeatmap(rows: rows)
            }
            async let ranks = usageRanks(neededFor: lastSortOrder, rows: rows)
            let (hero, heatmap) = await activity
            usageRanks = await ranks
            guard !Task.isCancelled else { return }
            publishLoaded(hero: hero, heatmap: heatmap)
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
        guard case .loaded(let rows, let hero, let heatmap) = state else { return }
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
            state = .loaded(rows: updated, hero: hero, heatmap: heatmap)
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
        return sorted.first(where: { $0.counts.total > 0 })?.asDeckInfo
    }

    private func publishLoaded(hero: HeroData, heatmap: HeatmapCardData?) {
        let existingIcons: [Int64: String?] = {
            guard case .loaded(let rows, _, _) = state else { return [:] }
            return Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.iconName) })
        }()
        let sorted = DeckSorting.libraryRows(deckRows, order: lastSortOrder, ranks: usageRanks)
        state = .loaded(
            rows: sorted.map { row in
                var viewData = row.viewData
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
            },
            hero: hero,
            heatmap: heatmap
        )
    }

    private func republishLoaded() {
        guard case .loaded(_, let hero, let heatmap) = state else { return }
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
    func buildHeroAndHeatmap(rows: [DeckListRow]) async -> (HeroData, HeatmapCardData) {
        let totalDue = rows.reduce(0) { $0 + $1.counts.total }
        let deckCount = rows.count
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
        let hero = HeroData(
            totalDue: totalDue,
            deckCount: deckCount,
            streak: StreakCalculator.streak(reviews: reviewCounts, window: graphDays),
            recentDayTotals: StreakCalculator.lastNDaysTotals(reviews: reviewCounts, days: HeroData.sparklineCapacity)
        )
        return (hero, Self.buildHeatmap(reviews: reviewCounts))
    }
}

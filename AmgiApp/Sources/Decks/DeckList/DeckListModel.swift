import AmgiUI
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

    private var deckRows: [DeckListRow] = []
    private var heroData: HeroData = .zero
    private var heatmapData: HeatmapCardData = .empty
    private var lastSortOrder: DeckSortOrder = .mostUsed
    private var usageRanks: [Int64: DeckUsageRank] = [:]

    @ObservationIgnored @Dependency(\.deckClient) private var deckClient
    @ObservationIgnored @Dependency(\.statsClient) private var statsClient
    @ObservationIgnored @Dependency(\.collectionStore) private var store

    func load(sortOrder: DeckSortOrder) async {
        lastSortOrder = sortOrder
        // Fresh conf pull so row tiles reflect any icon writes/syncs that
        // happened since this generation was last loaded.
        await DeckIconOverrides.refresh()
        do {
            let tree = try await store.tree()
            if tree.isEmpty {
                deckRows = []
                state = .empty
                return
            }
            deckRows = tree.map(DeckListRow.init(node:))
            async let heroHeatmap = buildHeroAndHeatmap(rows: deckRows)
            async let ranks = usageRanks(neededFor: sortOrder, rows: deckRows)
            let (hero, heatmap) = await heroHeatmap
            heroData = hero
            heatmapData = heatmap
            usageRanks = await ranks
            publishLoaded(sortOrder: sortOrder)
            // Icons resolve asynchronously after first paint: manual picks
            // are instant (dictionary lookup), semantic suggestions stream
            // in per row and republish.
            Task { await refineRowIcons() }
            // Keep the installed widget aligned with the Library projection
            // the user is currently seeing, including top-level deck totals.
            // Cross-platform: both the iOS and macOS widget extensions read
            // from the same App Group snapshot files.
            Task { await writeWidgetSnapshot() }
        } catch {
            print("[DeckListModel] Error loading decks: \(error)")
            state = .empty
        }
    }

    func resort(sortOrder: DeckSortOrder) {
        lastSortOrder = sortOrder
        guard !deckRows.isEmpty else { return }
        if sortOrder == .mostUsed && usageRanks.isEmpty {
            Task {
                usageRanks = await fetchUsageRanks(for: deckRows)
                guard lastSortOrder == .mostUsed else { return }
                publishLoaded(sortOrder: .mostUsed)
            }
        }
        publishLoaded(sortOrder: sortOrder)
    }

    /// Fills in each row's tile icon asynchronously after first paint:
    /// manual overrides are already in place from `publishLoaded`, semantic
    /// suggestions stream in per row and republish.
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
            print("[DeckListModel] Delete failed: \(error)")
            await load(sortOrder: lastSortOrder)
        }
    }

    /// First loaded deck that has cards waiting, projected to a `DeckInfo`
    /// for navigation. Nil while loading/empty or when nothing is due.
    func firstReviewableDeck(sortOrder: DeckSortOrder) -> DeckInfo? {
        guard !deckRows.isEmpty else { return nil }
        let sorted = DeckSorting.libraryRows(deckRows, order: sortOrder, ranks: usageRanks)
        return sorted.first(where: { $0.counts.total > 0 })?.asDeckInfo
    }

    private func publishLoaded(sortOrder: DeckSortOrder) {
        let sorted = DeckSorting.libraryRows(deckRows, order: sortOrder, ranks: usageRanks)
        state = .loaded(
            rows: sorted.map { row in
                var viewData = row.viewData
                // Manual overrides and cached suggestions paint instantly;
                // uncached suggestions arrive via refineRowIcons().
                viewData.iconName = DeckIconOverrides.initialIcon(
                    deckId: row.id.rawValue,
                    name: row.name,
                    fullName: row.fullName
                )
                return viewData
            },
            hero: heroData,
            heatmap: heatmapData
        )
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
        guard let graphs = try? await statsClient.fetchGraphs("", 365) else {
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
            streak: StreakCalculator.streak(reviews: reviewCounts),
            recentDayTotals: StreakCalculator.lastNDaysTotals(
                reviews: reviewCounts,
                days: HeroData.sparklineCapacity
            )
        )
        return (hero, Self.buildHeatmap(reviews: reviewCounts))
    }
}

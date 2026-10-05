import OSLog
import AmgiUI
import AmgiAppCore
import AmgiAppShared
import AnkiClients
import AnkiBackend
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
    /// Best-effort enrichment off the critical path, with four concurrent
    /// reads. Absent means unknown, never zero.
    private var newPerDayLimits: [DeckID: Int] = [:]
    /// Top-level decks whose every card is suspended. Default and filtered
    /// decks are never included, even when parked.
    private var archivedDeckIDs: Set<DeckID> = []

    private var decisionMetadata = DeckDecisionMetadata()
    private var decisionScope: DeckDecisionScope?
    private var triageReadiness: DeckTriageData.Readiness = .loading
    private var focusedDecisionID: Int64?
    private var loadIdentity = UUID()
    private var resolvedPausedIDs: Set<Int64> = []
    private struct FailedDecision {
        let item: DeckTriageItem
        let error: String
        let needsRecovery: Bool
    }
    private var failedDecision: FailedDecision?
    var decisionBusyID: Int64?
    var decisionError: String?
    @ObservationIgnored @Dependency(\.deckDecisionClient) private var decisionClient

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
            let identity = loadIdentity
            let rows = deckRows
            Task {
                let fetched = await fetchUsageRanks(for: rows)
                guard identity == loadIdentity, lastSortOrder == .mostUsed else { return }
                usageRanks = fetched
                republishLoaded()
            }
        }
        publishLoaded(hero: hero, heatmap: heatmap)
    }

    private func loadBody() async {
        let identity = UUID()
        loadIdentity = identity
        let profile = AccountStore.shared.selectedContext
        decisionScope = decisionClient.scope()
        triageReadiness = .loading
        // Carry the previous activity data through a refresh rather than
        // flashing placeholders over numbers that are still on screen.
        // Decisions stay non-interactive until this load's inventory,
        // history, and persisted choices have been reconciled.
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
            guard identity == loadIdentity, profile.isCurrent(AccountStore.shared.selectedContext), !Task.isCancelled else { return }
            if tree.isEmpty {
                deckRows = []
                usageRanks = [:]
                archivedDeckIDs = []
                state = .empty
                return
            }
            guard identity == loadIdentity, profile.isCurrent(AccountStore.shared.selectedContext), !Task.isCancelled else { return }
            deckRows = tree.map(DeckListRow.init(node:))
            archivedDeckIDs.formIntersection(Set(deckRows.map(\.id)))
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
            // settings reads use bounded concurrency and land here for
            // the same reason; the queue itself has no result cap.
            let rows = deckRows
            async let activity = AppSignpost.measure("DeckListActivity") {
                await self.buildHeroAndHeatmap(rows: rows)
            }
            async let ranks = fetchUsageRanks(for: rows)
            async let limits = newPerDayLimits(for: rows)
            async let archived = fetchArchivedDeckIDs(for: rows)
            async let metadata = readDecisionMetadata()
            let (hero, heatmap) = await activity
            let fetchedRanks = await ranks
            let fetchedLimits = await limits
            let fetchedArchived = await archived
            let fetchedMetadata = await metadata
            guard identity == loadIdentity, profile.isCurrent(AccountStore.shared.selectedContext), !Task.isCancelled else { return }
            usageRanks = fetchedRanks
            newPerDayLimits = fetchedLimits
            archivedDeckIDs = fetchedArchived
            if let fetchedMetadata, let scope = decisionScope {
                decisionMetadata = fetchedMetadata
                let viewRows = rows.map { $0.viewData(isArchived: fetchedArchived.contains($0.id)) }
                let observations = DeckTriage.observations(rows: viewRows, ranks: fetchedRanks,
                    newPerDay: fetchedLimits, metadata: fetchedMetadata)
                do {
                    let result = try await decisionClient.mutate(scope, .observe(observations,
                        existingIDs: Set(tree.flatMap { [$0.id.rawValue] + $0.flattened().map { $0.id.rawValue } }), now: Date()))
                    guard identity == loadIdentity, profile.isCurrent(AccountStore.shared.selectedContext) else { return }
                    decisionMetadata = result.metadata
                    if result.metadataChanged { store.markLocalMutation() }
                } catch {
                    Log.decks.error("Decision observation failed: \(error)")
                }
                guard identity == loadIdentity, profile.isCurrent(AccountStore.shared.selectedContext), !Task.isCancelled else { return }
                triageReadiness = .ready
            } else {
                triageReadiness = .unavailable
            }
            publishLoaded(hero: hero, heatmap: heatmap)
            Task { await refineRowIcons() }
        } catch {
            guard identity == loadIdentity, profile.isCurrent(AccountStore.shared.selectedContext), !Task.isCancelled else { return }
            Log.decks.error("Error loading decks: \(error)")
            // NOT .empty — that is the genuine no-decks state, and rendering a
            // failure as it told users with a full collection they had none.
            state = .failed(error.localizedDescription)
        }
    }

    /// Semantic suggestions stream in per row after first paint.
    func refineRowIcons() async {
        let identity = loadIdentity
        let profile = AccountStore.shared.selectedContext
        let activationID = decisionScope?.activationID
        guard case .loaded(let rows, let hero, let heatmap, _) = state else { return }
        var updated = rows
        var changed = false
        for index in updated.indices {
            let row = updated[index]
            let resolved = await AnkiBackend.$requiredCollectionActivationID.withValue(activationID) {
                await DeckIconOverrides.resolvedIcon(deckId: row.id, name: row.name, fullName: row.fullName)
            }
            guard identity == loadIdentity, profile.isCurrent(AccountStore.shared.selectedContext), !Task.isCancelled else { return }
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
        let triage = classifiedTriage(for: viewRows)
        focusedDecisionID = triage.focusedItem?.id
        state = .loaded(
            rows: viewRows,
            hero: hero,
            heatmap: heatmap,
            triage: DeckTriageData(items: triage.items, readiness: triage.readiness,
                focusedID: focusedDecisionID, busyID: decisionBusyID, errorMessage: triage.errorMessage,
                manualReviewCount: triage.manualReviewCount)
        )
    }

    /// Single source for the card payload: phase one, phase two, `resort`,
    /// and icon refinement all classify from the same stored inputs.
    private func classifiedTriage(for viewRows: [DeckRowViewData]) -> DeckTriageData {
        let classified = DeckTriage.data(
            rows: viewRows,
            ranks: usageRanks,
            archived: archivedDeckIDs,
            newPerDay: newPerDayLimits,
            metadata: decisionMetadata,
            readiness: triageReadiness,
            focusedID: focusedDecisionID,
            busyID: decisionBusyID,
            errorMessage: decisionError
        )
        let items = retainingFailure(in: classified.items, rows: viewRows, paused: false)
        let manualReviewCount = viewRows.filter {
            $0.isArchived && !decisionMetadata.isSuppressed(id: $0.id, issue: "paused", now: Date())
        }.count
        return DeckTriageData(items: items, readiness: classified.readiness, focusedID: focusedDecisionID,
            busyID: decisionBusyID, errorMessage: decisionError ?? failedDecision?.error,
            manualReviewCount: manualReviewCount)
    }

    /// An incomplete mutation remains reviewable even when its partial
    /// effect changes the classifier. Recovery uses Browse rather than
    /// repeating an uncertain suspension/restore operation.
    private func retainingFailure(in items: [DeckTriageItem], rows: [DeckRowViewData], paused: Bool) -> [DeckTriageItem] {
        guard let failure = failedDecision, (failure.item.issue == .parked) == paused,
              let row = rows.first(where: { $0.id == failure.item.id }),
              !decisionMetadata.isSuppressed(id: row.id, issue: failure.item.issue.key, now: Date()) else { return items }
        var result = items
        let retained = failure.needsRecovery
            ? DeckTriageItem(row: row, issue: failure.item.issue, question: failure.item.question,
                evidence: L10n.text("Review the affected cards in Browse."), actions: [.chooseCards, .viewDeck])
            : failure.item
        if let index = result.firstIndex(where: { $0.id == row.id }) { result[index] = retained }
        else { result.insert(retained, at: 0) }
        return result
    }

    private func republishLoaded() {
        guard case .loaded(_, let hero, let heatmap, _) = state else { return }
        publishLoaded(hero: hero, heatmap: heatmap)
    }

    private func fetchUsageRanks(for rows: [DeckListRow]) async -> [Int64: DeckUsageRank] {
        await DeckUsageRanking.ranks(
            for: rows.map { (id: $0.id, fullName: $0.fullName) },
            statsClient: statsClient
        )
    }

    /// Only actual large backlogs need settings enrichment. Fetch all of
    /// them with bounded concurrency so Review all never loses candidates.
    /// Best-effort: a failure leaves the limit unknown and the deck simply
    /// doesn't qualify, rather than inventing a projection.
    private func newPerDayLimits(for rows: [DeckListRow]) async -> [DeckID: Int] {
        let limits = DeckTriage.Limits()
        let candidates = rows
            .filter {
                !$0.isFiltered
                    && ($0.uncappedCounts?.newCount ?? 0) >= limits.newWallMinimum
            }
            .sorted { ($0.uncappedCounts?.newCount ?? 0) > ($1.uncappedCounts?.newCount ?? 0) }
        let deckClient = self.deckClient
        return await withTaskGroup(of: (DeckID, Int?).self) { group in
            var iterator = candidates.makeIterator()
            func enqueue() {
                guard let row = iterator.next() else { return }
                group.addTask {
                    let perDay = try? await deckClient.getDeckConfig(row.id)
                    return (row.id, perDay?.config.newPerDay)
                }
            }
            for _ in 0..<min(limits.maxConcurrentReads, candidates.count) { enqueue() }
            var out: [DeckID: Int] = [:]
            for await (id, perDay) in group {
                if let perDay { out[id] = perDay }
                enqueue()
            }
            return out
        }
    }

    private func readDecisionMetadata() async -> DeckDecisionMetadata? {
        guard let scope = decisionScope else { return nil }
        return try? await decisionClient.read(scope)
    }

    func beginDecisionReview() { resolvedPausedIDs = [] }

    func decisionData(paused: Bool, focusedID: Int64? = nil, skipped: Set<Int64> = []) -> DeckTriageData {
        guard case .loaded(let rows, _, _, let triage) = state else { return .unresolved }
        let items: [DeckTriageItem]
        if paused {
            let pausedItems = rows.filter { $0.isArchived && !resolvedPausedIDs.contains($0.id)
                    && !decisionMetadata.isSuppressed(id: $0.id, issue: "paused", now: Date()) }
                .map { DeckTriage.item(row: $0, issue: .parked, canResume: triageReadiness == .ready && decisionMetadata.canResume(id: $0.id)) }
            items = retainingFailure(in: pausedItems, rows: rows, paused: true)
        } else {
            items = triage.items
        }
        return DeckTriageData(items: items.filter { !skipped.contains($0.id) }, readiness: paused && triage.readiness == .unavailable ? .ready : triage.readiness,
            focusedID: focusedID, busyID: decisionBusyID, errorMessage: decisionError ?? failedDecision?.error)
    }

    func freshDecisionTarget(_ item: DeckTriageItem) async -> DecisionTarget? {
        guard decisionBusyID == nil, let scope = decisionScope else { return nil }
        let profile = AccountStore.shared.selectedContext
        decisionBusyID = item.id
        decisionError = nil
        republishLoaded()
        defer { decisionBusyID = nil; republishLoaded() }
        do {
            let target = try await decisionClient.target(scope, DeckID(item.id))
            guard profile.isCurrent(AccountStore.shared.selectedContext), decisionClient.scope() == scope,
                  !Task.isCancelled else { return nil }
            return DecisionTarget(deck: target, profile: profile, scope: scope)
        } catch {
            if error is CancellationError { return nil }
            if profile.isCurrent(AccountStore.shared.selectedContext) { decisionError = error.localizedDescription }
            return nil
        }
    }

    /// false is also the safe Resume fallback: the presenter then opens
    /// suspended-card selection rather than enabling an untracked deck.
    @discardableResult
    func decide(_ item: DeckTriageItem, action: DeckTriageAction) async -> Bool {
        guard decisionBusyID == nil else { return false }
        if action == .keepPaused {
            resolvedPausedIDs.insert(item.id)
            if failedDecision?.item.id == item.id { failedDecision = nil }
            decisionError = nil
            return true
        }
        let mutation: DeckDecisionMutation
        switch action {
        case .deferDecision:
            mutation = .suppress(DeckID(item.id), issue: item.issue.key, until: Date().addingTimeInterval(7 * 86_400))
        case .keepPace:
            mutation = .suppress(DeckID(item.id), issue: item.issue.key, until: Date().addingTimeInterval(90 * 86_400))
        case .pause: mutation = .pause(DeckID(item.id))
        case .resume: mutation = .resume(DeckID(item.id))
        default: return false
        }
        return await performDecision(mutation, id: item.id, item: item)
    }

    func acknowledgeSavedSettings(_ item: DeckTriageItem, target: DecisionTarget? = nil) async {
        if let target {
            guard target.profile.isCurrent(AccountStore.shared.selectedContext),
                  decisionClient.scope() == target.scope else { return }
        }
        _ = await performDecision(.suppress(DeckID(item.id), issue: item.issue.key,
            until: Date().addingTimeInterval(90 * 86_400)), id: item.id, requiredScope: target?.scope, item: item)
    }

    func acknowledgeChosenCards(_ item: DeckTriageItem, target: DecisionTarget) async {
        guard target.profile.isCurrent(AccountStore.shared.selectedContext),
              decisionClient.scope() == target.scope else { return }
        _ = await performDecision(.suppress(DeckID(item.id), issue: item.issue.key,
            until: Date().addingTimeInterval(7 * 86_400)), id: item.id, requiredScope: target.scope, item: item)
        if item.issue == .parked {
            _ = await performDecision(.suppress(DeckID(item.id), issue: "inactive",
                until: Date().addingTimeInterval(7 * 86_400)), id: item.id, requiredScope: target.scope)
        }
    }

    func deleteDecision(_ deletion: Deletion) async {
        guard deletion.profile.isCurrent(AccountStore.shared.selectedContext), let count = deletion.deck.cardCount else { return }
        _ = await performDecision(.delete(deletion.id, expectedName: deletion.deck.fullName,
            expectedCardCount: count, expectedDescendantIDs: deletion.deck.flattened().map(\.id)),
            id: deletion.id.rawValue, requiredScope: deletion.scope)
    }

    private func performDecision(_ mutation: DeckDecisionMutation, id: Int64,
                                 requiredScope: DeckDecisionScope? = nil, item: DeckTriageItem? = nil) async -> Bool {
        guard decisionBusyID == nil, let scope = decisionScope else { return false }
        guard requiredScope == nil || requiredScope == scope else { return false }
        let profile = AccountStore.shared.selectedContext
        decisionBusyID = id
        decisionError = nil
        republishLoaded()
        defer { decisionBusyID = nil; republishLoaded() }
        do {
            let result = try await decisionClient.mutate(scope, mutation)
            guard profile.isCurrent(AccountStore.shared.selectedContext) else { return false }
            decisionMetadata = result.metadata
            if result.chooseCards { return false }
            if failedDecision?.item.id == id { failedDecision = nil }
            if case .resume = mutation { resolvedPausedIDs.insert(id) }
            focusedDecisionID = nil
            if result.collectionChanged {
                store.apply(CollectionChanges(card: true, deck: true, studyQueues: true))
                await load()
            } else if result.metadataChanged {
                store.markLocalMutation()
            }
            return true
        } catch {
            guard profile.isCurrent(AccountStore.shared.selectedContext) else { return false }
            if error is CancellationError { return false }
            decisionError = error.localizedDescription
            if let item {
                failedDecision = FailedDecision(item: item, error: error.localizedDescription,
                    needsRecovery: (error as? DeckDecisionFailure)?.collectionChanged == true)
            }
            if let failure = error as? DeckDecisionFailure, failure.collectionChanged {
                store.apply(CollectionChanges(card: true, deck: true, studyQueues: true))
                await load()
            }
            return false
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

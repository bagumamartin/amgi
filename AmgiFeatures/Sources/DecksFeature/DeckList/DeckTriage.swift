import AmgiAppCore
import AmgiUI
import AnkiKit
import Foundation
import OSLog

/// Collection triage for the Library "Needs a decision" card: which decks
/// have a structural problem only the Library can state. Pure function over
/// the already-loaded rows + ranks — no I/O, so unit-testable without the
/// engine. The card renders the resulting `DeckTriageData`.
///
/// Every signal deliberately excludes archived decks (the Archived section
/// owns them) and filtered decks (temporary study decks would read as
/// "neglected" by construction).
enum DeckTriage {
    struct Limits: Equatable, Sendable {
        /// A deck with cards due and no review this long needs a decision.
        var neglectThresholdDays = 30
        /// A parked (fully suspended) deck untouched this long needs one.
        /// Deliberately longer than neglect: parking is a decision already,
        /// this asks whether it is still the right one.
        var parkedThresholdDays = 90
        /// Unseen backlog at or above this many new cards is wall-sized.
        var newWallMinimum = 100
        /// …when it exceeds this many days of the deck's own new limit.
        var newWallHorizonDays = 14
        /// Visible rows; further matches fold into the overflow count.
        var maxVisibleItems = 4
    }

    /// Assembles the card payload. Unresolved (placeholder) until at least
    /// one rank exists — without review history every rank-dependent signal
    /// is unknowable. Rows that individually lack a rank still contribute
    /// the rank-independent new-wall signal when their limit is known.
    static func data(
        rows: [DeckRowViewData],
        ranks: [Int64: DeckUsageRank],
        archived: Set<DeckID>,
        newPerDay: [DeckID: Int],
        limits: Limits = Limits()
    ) -> DeckTriageData {
        guard !ranks.isEmpty else {
            Log.decks.info("Triage unresolved: \(rows.count) rows, ranks not loaded yet")
            return .unresolved
        }
        let (visible, overflow) = items(
            rows: rows, ranks: ranks, archived: archived, newPerDay: newPerDay, limits: limits
        )
        // One line per load: enough to tell "healthy collection" (all
        // none) apart from "signals swallowed" (rows excluded or rankless)
        // when the card's absence is reported.
        let detail = rows.map { verdict(for: $0, ranks: ranks, archived: archived, newPerDay: newPerDay, limits: limits) }
            .joined(separator: "; ")
        Log.decks.info("Triage resolved: \(visible.count) shown, \(overflow) overflow — \(detail)")
        return DeckTriageData(items: visible, isResolved: true, overflowCount: overflow)
    }

    /// Classified rows plus the overflow count. Sorted by severity, then
    /// magnitude; capped at `limits.maxVisibleItems`.
    static func items(
        rows: [DeckRowViewData],
        ranks: [Int64: DeckUsageRank],
        archived: Set<DeckID>,
        newPerDay: [DeckID: Int],
        limits: Limits = Limits()
    ) -> (items: [DeckTriageItem], overflow: Int) {
        var classified: [(item: DeckTriageItem, severity: Int, magnitude: Int)] = []
        for row in rows {
            guard let issue = issue(
                for: row,
                rank: ranks[row.id],
                newPerDay: newPerDay[DeckID(row.id)],
                limits: limits,
                isArchived: archived.contains(DeckID(row.id))
            ) else { continue }
            let item = DeckTriageItem(row: row, issue: issue)
            classified.append((item, severity(of: issue), magnitude(of: issue)))
        }
        classified.sort {
            if $0.severity != $1.severity { return $0.severity < $1.severity }
            if $0.magnitude != $1.magnitude { return $0.magnitude > $1.magnitude }
            return $0.item.id < $1.item.id
        }
        let visible = classified.prefix(limits.maxVisibleItems).map(\.item)
        return (Array(visible), max(0, classified.count - visible.count))
    }

    /// Precedence: neglected → never started → new backlog → empty.
    /// Parked decks get exactly one signal of their own and never the
    /// active-deck ones; filtered decks get none (temporary study decks
    /// would read as "neglected" by construction). A deck matches at most
    /// one — the first whose condition holds. The guards live here (not in
    /// the caller) so the resolution log's verdict and the real path share
    /// them and cannot disagree.
    private static func issue(
        for row: DeckRowViewData,
        rank: DeckUsageRank?,
        newPerDay: Int?,
        limits: Limits,
        isArchived: Bool
    ) -> DeckTriageIssue? {
        guard !row.isFiltered else { return nil }
        if isArchived {
            // Parked decks have nothing due by construction, so none of
            // the active signals fit. The only question is whether the
            // parking itself is stale: resume or delete. A missing rank
            // means the history hasn't loaded for this row — unknowable,
            // not parked.
            guard let rank else { return nil }
            if rank.lastActiveOffset == .min {
                return .parked(daysAgo: nil)
            }
            let daysAgo = -rank.lastActiveOffset
            return daysAgo >= limits.parkedThresholdDays ? .parked(daysAgo: daysAgo) : nil
        }
        // Due cards and stale history. No rank entry at all means the
        // history hasn't loaded for this row — unknowable, not neglected.
        // A `.min` offset means no reviews inside the rank window (a year).
        if row.totalCount > 0, let rank {
            if rank.lastActiveOffset == .min {
                // No history in a year. Genuinely-new decks (untouched new
                // cards) read as never started below; anything else due is
                // a returner — over a year away, not 30 days.
                if row.newCount > 0 && rank.reviewTotal == 0 {
                    return .neverStarted
                }
                return .neglected(daysAgo: nil)
            }
            let daysAgo = -rank.lastActiveOffset
            if daysAgo >= limits.neglectThresholdDays {
                return .neglected(daysAgo: daysAgo)
            }
        }
        // Unseen wall: big backlog at the deck's own pace. `newPerDay == 0`
        // is Anki for "no limit" — no wall exists, so no signal either.
        // Unknown limit (config fetch failed) drops the row rather than
        // inventing a projection.
        if row.newCount >= limits.newWallMinimum, let perDay = newPerDay, perDay > 0,
           row.newCount >= perDay * limits.newWallHorizonDays
        {
            let daysToClear = Int(ceil(Double(row.newCount) / Double(perDay)))
            return .newBacklog(perDay: perDay, daysToClear: daysToClear)
        }
        // Nothing due, never reviewed — a deletion candidate.
        if row.totalCount == 0, let rank, rank.reviewTotal == 0, rank.lastActiveOffset == .min {
            return .empty
        }
        return nil
    }

    private static func severity(of issue: DeckTriageIssue) -> Int {
        switch issue {
        case .neglected: return 0
        case .neverStarted: return 1
        case .newBacklog: return 2
        case .empty: return 3
        case .parked: return 4
        }
    }

    /// One-line per-deck verdict for the resolution log: what the
    /// classifier saw and what it decided. Ranks print as total/lastActive
    /// (`none` = no history in the window, `–` = row has no rank yet).
    private static func verdict(
        for row: DeckRowViewData,
        ranks: [Int64: DeckUsageRank],
        archived: Set<DeckID>,
        newPerDay: [DeckID: Int],
        limits: Limits
    ) -> String {
        let rankText: String = {
            guard let rank = ranks[row.id] else { return "rank=–" }
            let last = rank.lastActiveOffset == .min ? "none" : "\(rank.lastActiveOffset)"
            return "rank=\(rank.reviewTotal)/\(last)"
        }()
        let flags = [
            row.isFiltered ? "filtered" : nil,
            archived.contains(DeckID(row.id)) ? "archived" : nil,
            newPerDay[DeckID(row.id)].map { "limit=\($0)" },
        ].compactMap { $0 }.joined(separator: ",")
        let decided = issue(
            for: row,
            rank: ranks[row.id],
            newPerDay: newPerDay[DeckID(row.id)],
            limits: limits,
            isArchived: archived.contains(DeckID(row.id))
        ).map { "\($0)" } ?? "none"
        return "'\(row.name)' due=\(row.totalCount) new=\(row.newCount) \(rankText)\(flags.isEmpty ? "" : " \(flags)") → \(decided)"
    }

    private static func magnitude(of issue: DeckTriageIssue) -> Int {
        switch issue {
        // Over-a-year staleness (nil) outranks any known count — it is at
        // least the full rank window old.
        case .neglected(let daysAgo): return daysAgo ?? .max
        case .neverStarted: return 0
        case .newBacklog(_, let daysToClear): return daysToClear
        case .empty: return 0
        case .parked(let daysAgo): return daysAgo ?? .max
        }
    }
}

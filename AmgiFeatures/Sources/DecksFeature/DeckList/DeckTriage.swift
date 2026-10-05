import AmgiAppCore
import AmgiUI
import AnkiKit
import Foundation

/// Pure classification over inventory, successful history reads, and the
/// user's recorded decisions. Today’s limited queue is only used to decide
/// whether a Study button can actually launch a session.
enum DeckTriage {
    struct Limits: Equatable, Sendable {
        var neglectThresholdDays = 30
        var newWallMinimum = 100
        var newWallHorizonDays = 14
        var maxConcurrentReads = 4
    }

    static func data(rows: [DeckRowViewData], ranks: [Int64: DeckUsageRank],
                     archived: Set<DeckID>, newPerDay: [DeckID: Int],
                     metadata: DeckDecisionMetadata = .init(), now: Date = Date(),
                     readiness: DeckTriageData.Readiness = .ready, focusedID: Int64? = nil,
                     busyID: Int64? = nil, errorMessage: String? = nil) -> DeckTriageData {
        let items = items(rows: rows, ranks: ranks, archived: archived, newPerDay: newPerDay,
                          metadata: metadata, now: now)
        return DeckTriageData(items: items, readiness: readiness,
                              focusedID: focusedID, busyID: busyID, errorMessage: errorMessage)
    }

    static func items(rows: [DeckRowViewData], ranks: [Int64: DeckUsageRank],
                      archived: Set<DeckID>, newPerDay: [DeckID: Int],
                      metadata: DeckDecisionMetadata = .init(), now: Date = Date(),
                      limits: Limits = Limits()) -> [DeckTriageItem] {
        rows.compactMap { row -> DeckTriageItem? in
            guard !archived.contains(DeckID(row.id)),
                  let issue = issue(for: row, rank: ranks[row.id], newPerDay: newPerDay[DeckID(row.id)], limits: limits),
                  !metadata.isSuppressed(id: row.id, issue: issue.key, now: now) else { return nil }
            if issue == .neverStarted || issue == .empty {
                guard metadata.pastGrace(id: row.id, issue: issue.key, now: now) else { return nil }
            }
            return item(row: row, issue: issue)
        }.sorted {
            if severity($0.issue) != severity($1.issue) { return severity($0.issue) < severity($1.issue) }
            if magnitude($0.issue) != magnitude($1.issue) { return magnitude($0.issue) > magnitude($1.issue) }
            return $0.id < $1.id
        }
    }

    /// nil history stays unknown; it cannot establish an unused or inactive
    /// deck. Actual zero inventory establishes emptiness without any revlog.
    static func issue(for row: DeckRowViewData, rank: DeckUsageRank?, newPerDay: Int?,
                      limits: Limits = Limits()) -> DeckTriageIssue? {
        guard !row.isFiltered, !row.isArchived, let cards = row.cardCount else { return nil }
        if cards == 0 { return row.id == 1 ? nil : .empty }
        if let rank, let waiting = row.waitingCount, waiting > 0 {
            if rank.lastActiveOffset == .min {
                if row.availableNewCount == cards, rank.reviewTotal == 0 { return .neverStarted }
                return .neglected(daysAgo: nil)
            }
            let days = max(0, -rank.lastActiveOffset)
            if days >= limits.neglectThresholdDays { return .neglected(daysAgo: days) }
        }
        if let new = row.availableNewCount, new >= limits.newWallMinimum,
           let perDay = newPerDay, perDay > 0,
           Double(new) / Double(perDay) >= Double(limits.newWallHorizonDays) {
            return .newBacklog(perDay: perDay, daysToClear: Int(ceil(Double(new) / Double(perDay))))
        }
        return nil
    }

    static func observations(rows: [DeckRowViewData], ranks: [Int64: DeckUsageRank],
                             newPerDay: [DeckID: Int], metadata: DeckDecisionMetadata = .init()) -> [Int64: String] {
        var observations: [Int64: String] = [:]
        for row in rows {
            // Only clear a grace period when there is enough evidence to say
            // the condition ended. A failed history read must not reset it.
            guard row.cardCount != nil else { continue }
            // Inventory alone can disprove a previous empty/all-new
            // condition even when the history request is unavailable.
            let previous = metadata.entries[String(row.id)]?.observedIssue
            if ranks[row.id] == nil, !row.isArchived, !row.isFiltered, row.cardCount != 0 {
                if previous == "empty" || (previous == "unused" && row.availableNewCount != nil && row.availableNewCount != row.cardCount) {
                    observations[row.id] = ""
                }
                continue
            }
            guard
                  row.isArchived || row.isFiltered || row.cardCount == 0 || ranks[row.id] != nil else { continue }
            observations[row.id] = issue(for: row, rank: ranks[row.id], newPerDay: newPerDay[DeckID(row.id)])?.key ?? ""
        }
        return observations
    }

    static func item(row: DeckRowViewData, issue: DeckTriageIssue, canResume: Bool = false) -> DeckTriageItem {
        let question: String
        let evidence: String
        switch issue {
        case .neglected(let days):
            question = L10n.format("Still want to study %@?", [row.name])
            let activity = days.map { L10n.format("Last studied %lld days ago", [Int64($0)]) }
                ?? L10n.text("No study activity in the past year")
            evidence = activity + " · " + L10n.format("%lld cards waiting", [Int64(row.waitingCount ?? 0)])
        case .neverStarted:
            question = L10n.text("Ready to start this deck?")
            evidence = L10n.format("%lld new cards waiting", [Int64(row.availableNewCount ?? 0)])
        case .newBacklog(let perDay, let days):
            question = L10n.text("Does this study pace still suit you?")
            evidence = L10n.format("%lld new cards · about %lld days to introduce at %lld/day",
                [Int64(row.availableNewCount ?? 0), Int64(days), Int64(perDay)])
        case .empty:
            question = L10n.text("What would you like to do with this deck?")
            evidence = L10n.text("No cards, including subdecks")
        case .parked:
            question = L10n.text("Ready to bring this deck back?")
            evidence = L10n.text("All cards suspended")
        }
        let study: DeckTriageAction = row.totalCount > 0 ? .study : .pace
        let actions: [DeckTriageAction]
        switch issue {
        case .neglected, .neverStarted: actions = row.id == 1 ? [study] : [study, .pause]
        case .newBacklog: actions = [.pace, .keepPace]
        case .empty: actions = row.id == 1 ? [.addCards] : [.addCards, .delete]
        case .parked: actions = [canResume ? .resume : .chooseCards, .keepPaused]
        }
        return DeckTriageItem(row: row, issue: issue, question: question, evidence: evidence,
            canResumeDirectly: canResume, actions: actions)
    }

    private static func severity(_ issue: DeckTriageIssue) -> Int {
        switch issue {
        case .neglected: 0
        case .neverStarted: 1
        case .newBacklog: 2
        case .empty: 3
        case .parked: 4
        }
    }
    private static func magnitude(_ issue: DeckTriageIssue) -> Int {
        switch issue {
        case .neglected(let days): days ?? .max
        case .newBacklog(_, let days): days
        default: 0
        }
    }
}

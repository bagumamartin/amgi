import AmgiUI
import AnkiKit
import Testing
@testable import DecksFeature

@Suite struct DeckTriageTests {
    // MARK: - Fixtures

    private func row(
        id: Int64,
        name: String = "Deck",
        new: Int = 0,
        learn: Int = 0,
        review: Int = 0,
        isFiltered: Bool = false
    ) -> DeckRowViewData {
        DeckRowViewData(
            id: id, name: name, fullName: name,
            newCount: new, learnCount: learn, reviewCount: review,
            isFiltered: isFiltered, subdeckCount: 0
        )
    }

    private func rank(total: Int = 0, lastActive: Int = .min) -> DeckUsageRank {
        DeckUsageRank(reviewTotal: total, lastActiveOffset: lastActive, weightedScore: 0)
    }

    private func classified(
        rows: [DeckRowViewData],
        ranks: [Int64: DeckUsageRank],
        archived: Set<DeckID> = [],
        newPerDay: [DeckID: Int] = [:]
    ) -> (items: [DeckTriageItem], overflow: Int) {
        DeckTriage.items(rows: rows, ranks: ranks, archived: archived, newPerDay: newPerDay)
    }

    // MARK: - Neglected

    @Test func neglectedWithStaleHistory() {
        let rows = [row(id: 1, new: 12, learn: 8, review: 42)]
        let (items, overflow) = classified(rows: rows, ranks: [1: rank(total: 900, lastActive: -47)])
        #expect(items.count == 1)
        #expect(items[0].issue == .neglected(daysAgo: 47))
        #expect(items[0].subtitle == "Not studied in 47 days · 62 due")
        #expect(overflow == 0)
    }

    @Test func neglectThresholdIsInclusive() {
        let rows = [row(id: 1, review: 10)]
        let atThreshold = classified(rows: rows, ranks: [1: rank(total: 50, lastActive: -30)])
        #expect(atThreshold.items.count == 1)
        let justUnder = classified(rows: rows, ranks: [1: rank(total: 50, lastActive: -29)])
        #expect(justUnder.items.isEmpty)
    }

    @Test func neglectedBeyondRankWindowReadsOverAYear() {
        // Reviewed long ago — outside the 365-day rank window — with cards
        // due again. No history on record, but not a new deck either.
        let rows = [row(id: 1, review: 200)]
        let (items, _) = classified(rows: rows, ranks: [1: rank()])
        #expect(items.count == 1)
        #expect(items[0].issue == .neglected(daysAgo: nil))
        #expect(items[0].subtitle == "Not studied in over a year · 200 due")
    }

    @Test func recentlyActiveDeckIsNotNeglected() {
        let rows = [row(id: 1, new: 10, review: 40)]
        let (items, _) = classified(rows: rows, ranks: [1: rank(total: 500, lastActive: -5)])
        #expect(items.isEmpty)
    }

    // MARK: - Never started

    @Test func untouchedNewDeckIsNeverStarted() {
        let rows = [row(id: 1, name: "TOPIK", new: 340)]
        let (items, _) = classified(rows: rows, ranks: [1: rank()])
        #expect(items.count == 1)
        #expect(items[0].issue == .neverStarted)
        #expect(items[0].subtitle == "Never started · 340 new")
    }

    @Test func neverStartedBeatsNeglectedForNewDecks() {
        // Due new cards and zero history is a new deck, not a neglected one.
        let rows = [row(id: 1, new: 340, review: 10)]
        let (items, _) = classified(rows: rows, ranks: [1: rank()])
        #expect(items.count == 1)
        #expect(items[0].issue == .neverStarted)
    }

    // MARK: - New backlog

    @Test func wallSizedBacklogProjectsWeeks() {
        let rows = [row(id: 1, name: "Anatomy", new: 412, review: 30)]
        let (items, _) = classified(
            rows: rows,
            ranks: [1: rank(total: 2000, lastActive: -1)],
            newPerDay: [DeckID(1): 20]
        )
        #expect(items.count == 1)
        #expect(items[0].issue == .newBacklog(perDay: 20, daysToClear: 21))
        #expect(items[0].subtitle == "412 new · about 3 weeks at 20/day")
    }

    @Test func daysToClearRoundsUp() {
        let rows = [row(id: 1, new: 401)]
        let (items, _) = classified(
            rows: rows,
            ranks: [1: rank(total: 100, lastActive: -2)],
            newPerDay: [DeckID(1): 20]
        )
        #expect(items[0].issue == .newBacklog(perDay: 20, daysToClear: 21))
    }

    @Test func backlogBelowHorizonIsNotAWall() {
        // 100 new at 20/day clears in 5 days — a queue, not a wall.
        let rows = [row(id: 1, new: 100)]
        let (items, _) = classified(
            rows: rows,
            ranks: [1: rank(total: 100, lastActive: -2)],
            newPerDay: [DeckID(1): 20]
        )
        #expect(items.isEmpty)
    }

    @Test func backlogBelowMinimumIsNotAWall() {
        let rows = [row(id: 1, new: 60)]
        let (items, _) = classified(
            rows: rows,
            ranks: [1: rank(total: 100, lastActive: -2)],
            newPerDay: [DeckID(1): 1]
        )
        #expect(items.isEmpty)
    }

    @Test func unlimitedNewLimitHasNoWall() {
        // `newPerDay == 0` is Anki for "no limit" — nothing to project.
        let rows = [row(id: 1, new: 500)]
        let (items, _) = classified(
            rows: rows,
            ranks: [1: rank(total: 100, lastActive: -2)],
            newPerDay: [DeckID(1): 0]
        )
        #expect(items.isEmpty)
    }

    @Test func unknownLimitDropsTheRow() {
        // Config fetch failed: no projection is invented.
        let rows = [row(id: 1, new: 500)]
        let (items, _) = classified(rows: rows, ranks: [1: rank(total: 100, lastActive: -2)])
        #expect(items.isEmpty)
    }

    // MARK: - Empty

    @Test func neverReviewedAndNothingDueIsEmpty() {
        let rows = [row(id: 1, name: "Stale")]
        let (items, _) = classified(rows: rows, ranks: [1: rank()])
        #expect(items.count == 1)
        #expect(items[0].issue == .empty)
        #expect(items[0].subtitle == "Nothing due · never reviewed")
    }

    @Test func reviewedAndCaughtUpIsNotEmpty() {
        let rows = [row(id: 1, name: "Done")]
        let (items, _) = classified(rows: rows, ranks: [1: rank(total: 300, lastActive: -1)])
        #expect(items.isEmpty)
    }

    // MARK: - Exclusions

    @Test func archivedDecksAreExcluded() {
        let rows = [row(id: 1, review: 60)]
        let (items, _) = classified(
            rows: rows,
            ranks: [1: rank(total: 900, lastActive: -47)],
            archived: [DeckID(1)]
        )
        #expect(items.isEmpty)
    }

    @Test func filteredDecksAreExcluded() {
        let rows = [row(id: 1, review: 24, isFiltered: true)]
        let (items, _) = classified(rows: rows, ranks: [1: rank(total: 900, lastActive: -47)])
        #expect(items.isEmpty)
    }

    // MARK: - Parked

    @Test func staleParkedDeckAsksResumeOrDelete() {
        let rows = [row(id: 1, name: "Pharmacognosy")]
        let (items, _) = classified(
            rows: rows,
            ranks: [1: rank(total: 913, lastActive: -129)],
            archived: [DeckID(1)]
        )
        #expect(items.count == 1)
        #expect(items[0].issue == .parked(daysAgo: 129))
        #expect(items[0].subtitle == "Parked 129 days ago · all cards suspended")
    }

    @Test func parkedThresholdIsInclusive() {
        let rows = [row(id: 1)]
        let atThreshold = classified(
            rows: rows,
            ranks: [1: rank(total: 600, lastActive: -90)],
            archived: [DeckID(1)]
        )
        #expect(atThreshold.items.count == 1)
        let justUnder = classified(
            rows: rows,
            ranks: [1: rank(total: 600, lastActive: -89)],
            archived: [DeckID(1)]
        )
        #expect(justUnder.items.isEmpty)
    }

    @Test func recentlyParkedDeckIsNotFlagged() {
        let rows = [row(id: 1, name: "Pathophysiology Final Exam")]
        let (items, _) = classified(
            rows: rows,
            ranks: [1: rank(total: 1100, lastActive: -16)],
            archived: [DeckID(1)]
        )
        #expect(items.isEmpty)
    }

    @Test func parkedWithoutHistoryHasUnknownAge() {
        let rows = [row(id: 1)]
        let (items, _) = classified(
            rows: rows,
            ranks: [1: rank()],
            archived: [DeckID(1)]
        )
        #expect(items.count == 1)
        #expect(items[0].issue == .parked(daysAgo: nil))
        #expect(items[0].subtitle == "Parked · all cards suspended")
    }

    @Test func parkedBeatsEmptyForArchivedDecks() {
        // Archived with untouched cards and no history is parked, not empty.
        let rows = [row(id: 1, new: 340)]
        let (items, _) = classified(
            rows: rows,
            ranks: [1: rank()],
            archived: [DeckID(1)]
        )
        #expect(items.count == 1)
        #expect(items[0].issue == .parked(daysAgo: nil))
    }

    @Test func ranklessArchivedRowsStaySilent() {
        let rows = [row(id: 1, name: "Active"), row(id: 2, name: "Parked")]
        let (items, _) = classified(
            rows: rows,
            ranks: [1: rank(total: 50, lastActive: -3)],
            archived: [DeckID(2)]
        )
        #expect(items.isEmpty)
    }

    @Test func filteredDecksNeverPark() {
        let rows = [row(id: 1, isFiltered: true)]
        let (items, _) = classified(
            rows: rows,
            ranks: [1: rank(total: 900, lastActive: -200)],
            archived: [DeckID(1)]
        )
        #expect(items.isEmpty)
    }

    @Test func parkedSortsAfterEmpty() {
        let rows = [row(id: 1), row(id: 2, name: "Parked")]
        let (items, _) = classified(
            rows: rows,
            ranks: [1: rank(), 2: rank(total: 900, lastActive: -200)],
            archived: [DeckID(2)]
        )
        #expect(items.map(\.id) == [1, 2])
    }

    // MARK: - Missing ranks

    @Test func ranklessRowsSkipRankSignals() {
        // History hasn't loaded for deck 2 (e.g. added under a non-default
        // sort). Its neglect is unknowable — but must not read as "never
        // reviewed" either.
        let rows = [row(id: 1, review: 10), row(id: 2, review: 60)]
        let (items, _) = classified(
            rows: rows,
            ranks: [1: rank(total: 50, lastActive: -3)]
        )
        #expect(items.isEmpty)
    }

    @Test func ranklessRowsStillYieldNewBacklog() {
        let rows = [row(id: 1, review: 10), row(id: 2, new: 412)]
        let (items, _) = classified(
            rows: rows,
            ranks: [1: rank(total: 50, lastActive: -3)],
            newPerDay: [DeckID(2): 20]
        )
        #expect(items.count == 1)
        #expect(items[0].id == 2)
        #expect(items[0].issue == .newBacklog(perDay: 20, daysToClear: 21))
    }

    // MARK: - Ordering, cap, resolution

    @Test func ordersBySeverityThenMagnitude() {
        let rows = [
            row(id: 1, review: 50),              // neglected, 60 days
            row(id: 2, review: 10),              // neglected, 47 days
            row(id: 3, new: 340),                // never started
            row(id: 4, new: 412),                // new backlog
            row(id: 5),                          // empty
        ]
        let (items, overflow) = classified(
            rows: rows,
            ranks: [
                1: rank(total: 900, lastActive: -60),
                2: rank(total: 900, lastActive: -47),
                3: rank(),
                4: rank(total: 2000, lastActive: -1),
                5: rank(),
            ],
            newPerDay: [DeckID(4): 20]
        )
        #expect(items.map(\.id) == [1, 2, 3, 4])
        #expect(overflow == 1)
    }

    @Test func capsVisibleItemsWithOverflow() {
        let rows = (1...6).map { row(id: Int64($0), review: 10 * $0) }
        let ranks = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, rank(total: 900, lastActive: -60)) })
        let (items, overflow) = classified(rows: rows, ranks: ranks)
        #expect(items.count == 4)
        #expect(overflow == 2)
    }

    @Test func unresolvedUntilRanksExist() {
        let data = DeckTriage.data(rows: [row(id: 1, review: 60)], ranks: [:], archived: [], newPerDay: [:])
        #expect(data == .unresolved)
        #expect(!data.isHidden)
    }

    @Test func resolvedEmptyHides() {
        let data = DeckTriage.data(
            rows: [row(id: 1, name: "Done")],
            ranks: [1: rank(total: 300, lastActive: -1)],
            archived: [],
            newPerDay: [:]
        )
        #expect(data.isResolved)
        #expect(data.isHidden)
    }
}

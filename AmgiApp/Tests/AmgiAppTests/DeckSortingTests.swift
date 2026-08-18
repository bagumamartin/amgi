import Testing
import AmgiUI
import AnkiKit
@testable import AmgiApp

@Suite struct DeckSortingTests {
    private func rows(_ names: [String]) -> [DeckListRow] {
        names.enumerated().map { index, name in
            DeckListRow(
                id: DeckID(Int64(index + 1)),
                name: name,
                fullName: name,
                counts: DeckCounts(newCount: index, learnCount: 0, reviewCount: 0),
                isFiltered: false,
                subdeckCount: 0
            )
        }
    }

    @Test func collectionOrderPreservesInput() {
        let input = rows(["Zed", "Alpha", "Mid"])
        let sorted = DeckSorting.libraryRows(input, order: .collectionOrder)
        #expect(sorted.map(\.name) == ["Zed", "Alpha", "Mid"])
    }

    @Test func alphabeticalSortsByName() {
        let input = rows(["Zed", "Alpha", "Mid"])
        let sorted = DeckSorting.libraryRows(input, order: .alphabetical)
        #expect(sorted.map(\.name) == ["Alpha", "Mid", "Zed"])
    }

    @Test func mostDuePutsHighestDueFirst() {
        let input = rows(["Low", "High", "Mid"])
        let sorted = DeckSorting.libraryRows(input, order: .mostDue)
        #expect(sorted.map(\.name) == ["Mid", "High", "Low"])
    }

    @Test func mostUsedRanksBySyncedReviewVolume() {
        let input = rows(["A", "B", "C"])
        let ranks: [Int64: DeckUsageRank] = [
            1: DeckUsageRank(reviewTotal: 2, lastActiveOffset: 0),
            2: DeckUsageRank(reviewTotal: 40, lastActiveOffset: -3),
            3: DeckUsageRank(reviewTotal: 40, lastActiveOffset: 0),
        ]
        let sorted = DeckSorting.libraryRows(input, order: .mostUsed, ranks: ranks)
        // B and C tied on volume; C reviewed more recently. A least studied.
        #expect(sorted.map(\.name) == ["C", "B", "A"])
    }
}

@Suite struct DeckUsageRankingTests {
    @Test func deckSearchQuotesAndEscapes() {
        #expect(DeckUsageRanking.deckSearch(fullName: "Korean") == "deck:\"Korean\"")
        #expect(DeckUsageRanking.deckSearch(fullName: "A \"quoted\" deck") == "deck:\"A \\\"quoted\\\" deck\"")
    }

    @Test func rankSumsReviewTypesAndTracksMostRecentDay() {
        var graphs = GraphsSnapshot()
        graphs.reviews.count = [
            -2: .init(learn: 1, relearn: 0, young: 0, mature: 0, filtered: 0),
            0: .init(learn: 0, relearn: 0, young: 2, mature: 3, filtered: 0),
        ]
        let rank = DeckUsageRanking.rank(from: graphs)
        #expect(rank.reviewTotal == 6)
        #expect(rank.lastActiveOffset == 0)
    }
}

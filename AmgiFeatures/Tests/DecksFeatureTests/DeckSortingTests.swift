import Testing
import AmgiUI
import AnkiKit
@testable import DecksFeature

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

    @Test func mostUsedRanksByWeightedRecency() {
        let input = rows(["A", "B", "C"])
        let ranks: [Int64: DeckUsageRank] = [
            1: DeckUsageRank(reviewTotal: 500, lastActiveOffset: 0, weightedScore: 5),
            2: DeckUsageRank(reviewTotal: 60, lastActiveOffset: -1, weightedScore: 60),
            3: DeckUsageRank(reviewTotal: 30, lastActiveOffset: -1, weightedScore: 60),
        ]
        let sorted = DeckSorting.libraryRows(input, order: .mostUsed, ranks: ranks)
        // Weighted recency is primary: B and C beat A despite A's huge total.
        // B and C tie on weighted score and recency, so total volume breaks the tie.
        #expect(sorted.map(\.name) == ["B", "C", "A"])
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

    @Test func recencyWeightingFavorsRecentReviews() {
        var recent = GraphsSnapshot()
        recent.reviews.count = [0: .init(learn: 10, relearn: 0, young: 0, mature: 0, filtered: 0)]
        var older = GraphsSnapshot()
        older.reviews.count = [-30: .init(learn: 10, relearn: 0, young: 0, mature: 0, filtered: 0)]

        let recentRank = DeckUsageRanking.rank(from: recent)
        let olderRank = DeckUsageRanking.rank(from: older)

        #expect(recentRank.reviewTotal == olderRank.reviewTotal)
        #expect(recentRank.weightedScore > olderRank.weightedScore)
    }
}

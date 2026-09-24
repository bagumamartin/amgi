import Testing
@testable import AnkiKit

@Suite("Future due graph")
struct GraphsSnapshotTests {
    @Test("backlog count sums only negative day buckets")
    func backlogCount() {
        let series = FutureDueSeries(futureDue: [-1: 4, -7: 6, 0: 2, 1: 10])
        #expect(series.backlogCount == 10)
    }

    @Test("an empty or future-only series has no backlog")
    func noBacklog() {
        #expect(FutureDueSeries().backlogCount == 0)
        #expect(FutureDueSeries(futureDue: [0: 3, 1: 8, 2: 5]).backlogCount == 0)
    }
}

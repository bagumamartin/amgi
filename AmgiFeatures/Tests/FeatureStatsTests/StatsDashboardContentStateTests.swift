import Testing
import AnkiKit
@testable import FeatureStats

@Suite("StatsDashboardContent.State projection")
struct StatsDashboardContentStateTests {

    @Test("loading wins while a load is in flight")
    func loadingWins() {
        let state = StatsDashboardContent.State(
            isLoading: true, errorMessage: nil, graphs: nil
        )
        #expect(state.isLoadingCase)
    }

    @Test("an error surfaces even when stale graphs are still held")
    func errorBeatsStaleGraphs() {
        let state = StatsDashboardContent.State(
            isLoading: false, errorMessage: "boom", graphs: .sample
        )
        #expect(state.failureMessage == "boom")
    }

    @Test("graphs render when there is no error and no load in flight")
    func loadedRendersGraphs() {
        let state = StatsDashboardContent.State(
            isLoading: false, errorMessage: nil, graphs: .sample
        )
        #expect(state.loadedGraphs != nil)
    }

    @Test("no graphs and no error is still loading, never a blank screen")
    func emptyIsLoading() {
        let state = StatsDashboardContent.State(
            isLoading: false, errorMessage: nil, graphs: nil
        )
        #expect(state.isLoadingCase)
    }

    @Test("an error still wins while a refresh is in flight")
    func errorBeatsInFlightReload() {
        let state = StatsDashboardContent.State(
            isLoading: true, errorMessage: "boom", graphs: nil
        )
        #expect(state.failureMessage == "boom")
    }
}

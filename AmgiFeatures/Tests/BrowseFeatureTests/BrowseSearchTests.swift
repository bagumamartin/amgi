import AnkiClients
import AnkiKit
import AnkiServices
import Dependencies
import Testing
import Foundation
@testable import BrowseFeature

/// `performSearch` is driven from `.task(id: model.searchQuery)`, so it gets
/// cancelled and restarted on every keystroke. These tests pin the two
/// cancellation points that make that safe — without them, typing issued one
/// racing backend search per character and the list showed whichever returned
/// last rather than the one the user typed.
@Suite("BrowseModel search")
@MainActor
struct BrowseSearchTests {

    private nonisolated static func note(_ id: Int64, sfld: String, mod: Int64 = 100) -> NoteRecord {
        NoteRecord(
            id: NoteID(id),
            guid: "g\(id)",
            mid: NotetypeID(1),
            mod: mod,
            tags: "",
            flds: "",
            sfld: sfld,
            csum: 0
        )
    }

    /// Counts backend hits across concurrent callers.
    private final class CallLog: @unchecked Sendable {
        private let lock = NSLock()
        private var queries: [String] = []

        func record(_ query: String) {
            lock.lock()
            defer { lock.unlock() }
            queries.append(query)
        }

        var all: [String] {
            lock.lock()
            defer { lock.unlock() }
            return queries
        }
    }

    // MARK: searchQuery

    @Test("buildQuery folds text, deck, and tag into one key")
    func searchQueryFoldsAllFilters() {
        let model = BrowseModel()
        #expect(model.buildQuery() == "deck:*")

        model.searchText = "kanji"
        #expect(model.buildQuery() == "kanji")

        model.source = .tag("verb")
        #expect(model.buildQuery() == "tag:\"verb\" kanji")
    }

    // MARK: Debounce

    @Test("a search cancelled during the debounce never reaches the backend")
    func cancelledDuringDebounceNeverSearches() async {
        let log = CallLog()
        await withDependencies {
            $0.noteClient.searchIds = { query, _ in
                log.record(query)
                return []
            }
            $0.cardClient.searchIds = { _, _ in [] }
        } operation: {
            let model = BrowseModel()
            model.searchText = "abc"

            // Nonzero debounce so the cancellation lands inside the sleep,
            // before any backend call is issued.
            let task = Task { await model.performSearch(debounce: .seconds(5)) }
            task.cancel()
            await task.value

            #expect(log.all.isEmpty, "cancelled before the debounce elapsed, so no query should have been issued")
        }
    }

    @Test("with the debounce waived the search runs immediately")
    func waivedDebounceSearchesImmediately() async {
        let log = CallLog()
        await withDependencies {
            $0.noteClient.searchIds = { query, _ in
                log.record(query)
                return [NoteID(1)]
            }
            $0.noteClient.fetch = { _ in Self.note(1, sfld: "hit") }
            $0.cardClient.searchIds = { _, _ in [] }
        } operation: {
            let model = BrowseModel()
            model.searchText = "abc"
            await model.performSearch(debounce: .zero)

            #expect(log.all == ["abc"])
            #expect(model.ids.compactMap { model.noteRecords[$0]?.sfld } == ["hit"])
            #expect(!model.isLoading)
        }
    }

    // MARK: Stale results

    @Test("a search cancelled mid-flight does not write its results")
    func cancelledMidFlightDoesNotWriteResults() async {
        let calls = CallLog()
        await withDependencies {
            $0.noteClient.searchIds = { query, _ in
                calls.record(query)
                if calls.all.count == 1 {
                    // Seed run: instant, populates the current list.
                    return [NoteID(1)]
                }
                // Long enough that the cancellation below lands while this is
                // still in flight. Cancellation is not observed here, so the
                // call returns normally and only the post-await guard can stop
                // the write.
                try? await Task.sleep(for: .milliseconds(200))
                return [NoteID(99)]
            }
            $0.noteClient.fetch = { nid in
                Self.note(nid.rawValue, sfld: nid.rawValue == 1 ? "current" : "stale")
            }
            $0.cardClient.searchIds = { _, _ in [] }
        } operation: {
            let model = BrowseModel()
            model.searchText = "seed"
            await model.performSearch(debounce: .zero)
            #expect(model.ids.compactMap { model.noteRecords[$0]?.sfld } == ["current"])

            model.searchText = "abc"
            let task = Task { await model.performSearch(debounce: .zero) }
            try? await Task.sleep(for: .milliseconds(50))
            task.cancel()
            await task.value

            #expect(
                model.ids.compactMap { model.noteRecords[$0]?.sfld } == ["current"],
                "a superseded search must not overwrite the list"
            )
        }
    }

    // MARK: Failure surfacing

    // NOTE (2026-09): the model no longer surfaces backend failures —
    // performSearch's failure branch clears the results silently (dedicated
    // inline error UI is parked per the validateCurrentQuery comment). These
    // tests pin the current contract: failure empties, success repopulates.

    @Test("a failed search empties the list without raising searchError")
    func failedSearchIsDistinguishable() async {
        struct Boom: Error {}

        await withDependencies {
            $0.noteClient.searchIds = { _, _ in throw Boom() }
            $0.cardClient.searchIds = { _, _ in [] }
        } operation: {
            let model = BrowseModel()
            await model.performSearch(debounce: .zero)

            #expect(model.ids.isEmpty)
            #expect(model.searchError == nil)
        }

        await withDependencies {
            $0.noteClient.searchIds = { _, _ in [] }
            $0.cardClient.searchIds = { _, _ in [] }
        } operation: {
            let model = BrowseModel()
            await model.performSearch(debounce: .zero)

            #expect(model.ids.isEmpty)
            #expect(model.searchError == nil, "an empty result set is not a failure")
        }
    }

    @Test("a successful search after a failure repopulates the list")
    func successClearsPreviousFailure() async {
        struct Boom: Error {}

        let shouldThrow = CallLog()
        await withDependencies {
            $0.noteClient.searchIds = { query, _ in
                shouldThrow.record(query)
                if shouldThrow.all.count == 1 { throw Boom() }
                return [NoteID(1)]
            }
            $0.noteClient.fetch = { _ in Self.note(1, sfld: "ok") }
            $0.cardClient.searchIds = { _, _ in [] }
        } operation: {
            let model = BrowseModel()
            await model.performSearch(debounce: .zero)
            #expect(model.ids.isEmpty)

            await model.performSearch(debounce: .zero)
            #expect(model.searchError == nil)
            #expect(model.ids.compactMap { model.noteRecords[$0]?.sfld } == ["ok"])
        }
    }

    // MARK: Initial load

    @Test("loadInitial does not search — the keyed task owns that")
    func loadInitialDoesNotSearch() async {
        let log = CallLog()
        await withDependencies {
            $0.noteClient.search = { query, _ in
                log.record(query)
                return []
            }
            $0.deckClient.fetchAll = { [] }
            $0.tagClient.getAllTags = { [] }
            $0.notetypesService.getNotetypeNames = { [] }
        } operation: {
            let model = BrowseModel()
            await model.loadInitial()

            #expect(log.all.isEmpty, "searching here too would issue the first query twice")
        }
    }
}

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

    /// `performSearch` validates grammar before `searchIds`. Tests that
    /// never exercise invalid queries pass the string through.
    private func passthroughValidate(_ values: inout DependencyValues) {
        values.noteClient.validateQuery = { $0 }
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

        model.source = .flag(3)
        #expect(model.buildQuery() == "flag:3 kanji")

        model.source = .cardState(.suspended)
        #expect(model.buildQuery() == "is:suspended kanji")

        model.source = .untagged
        #expect(model.buildQuery() == "tag:none kanji")

        model.source = .notetype("Cloze")
        #expect(model.buildQuery() == "note:\"Cloze\" kanji")

        model.source = .today("prop:due=0")
        #expect(model.buildQuery() == "prop:due=0 kanji")
    }

    @Test("query fragments quote tags and note types")
    func sourceQueryFragmentsQuoteValues() {
        #expect(BrowseSource.tag("verb").queryFragment() == "tag:\"verb\"")
        #expect(BrowseSource.tag("a\"b").queryFragment() == "tag:\"a\\\"b\"")
        #expect(BrowseSource.notetype("Cloze").queryFragment() == "note:\"Cloze\"")
        #expect(BrowseSource.untagged.queryFragment() == "tag:none")
        #expect(BrowseSource.flag(3).queryFragment() == "flag:3")
        #expect(BrowseSource.cardState(.suspended).queryFragment() == "is:suspended")
        #expect(BrowseSource.tagDragPrefix == "amgi-tag:")
    }

    @Test("sidebar titles match the selected source")
    func sourceTitles() {
        let model = BrowseModel()
        #expect(model.title(for: .allDecks) == "All Decks")
        #expect(model.title(for: .untagged) == "Untagged")
        #expect(model.title(for: .flag(0)) == "No flag")
        #expect(model.title(for: .flag(1)) == "Red")
        #expect(model.title(for: .cardState(.newState)) == "New")
        #expect(model.title(for: .today("prop:due=0")) == "Due today")
        #expect(model.title(for: .tag("jp::verb")) == "verb")
    }

    @Test("AND composition keeps the current source")
    func andCompositionKeepsSource() async {
        let model = BrowseModel()
        let deck = DeckInfo(id: DeckID(1), name: "French")
        model.allDecks = [deck]
        model.source = .deck(deck.id)
        let node = FilterNode(
            title: "Red", systemImage: "flag.fill", fragment: "flag:1", role: .flag(1)
        )
        await model.composeSidebarNode(node, composition: .andWithExisting)
        #expect(model.source == .deck(deck.id))
        #expect(model.searchText == "flag:1")
        #expect(model.buildQuery() == "deck:\"French\" flag:1")
    }

    @Test("OR composition flattens the current source into the search field")
    func orCompositionFlattensSource() async {
        await withDependencies {
            $0.noteClient.composeQuery = { existing, additional, _ in
                "(\(existing)) OR (\(additional))"
            }
        } operation: {
            let model = BrowseModel()
            let deck = DeckInfo(id: DeckID(1), name: "French")
            model.allDecks = [deck]
            model.source = .deck(deck.id)
            let node = FilterNode(
                title: "Red", systemImage: "flag.fill", fragment: "flag:1", role: .flag(1)
            )
            await model.composeSidebarNode(node, composition: .orWithExisting)
            #expect(model.source == .allDecks)
            #expect(model.searchText == "(deck:\"French\") OR (flag:1)")
        }
    }

    @Test("exclude composition keeps the current source")
    func excludeCompositionKeepsSource() async {
        let model = BrowseModel()
        let deck = DeckInfo(id: DeckID(1), name: "French")
        model.allDecks = [deck]
        model.source = .deck(deck.id)
        let node = FilterNode(
            title: "Red", systemImage: "flag.fill", fragment: "flag:1", role: .flag(1)
        )
        await model.composeSidebarNode(node, composition: .negateAndAdd)
        #expect(model.source == .deck(deck.id))
        #expect(model.searchText == "( not ( flag:1 ) )")
        #expect(model.buildQuery() == "deck:\"French\" ( not ( flag:1 ) )")
    }

    @Test("scope query for a deck includes subdecks unless asked not to")
    func deckScopeQueryIncludesSubdecks() {
        let model = BrowseModel()
        let parent = DeckInfo(id: DeckID(1), name: "French")
        model.allDecks = [parent]
        #expect(model.query(for: .deck(parent.id)) == "deck:\"French\"")
        #expect(
            model.query(for: .deck(parent.id), includeSubdecks: false)
                == "deck:\"French\" -deck:\"French::*\""
        )
    }

    @Test("deck sheet scope survives loading and source changes")
    func deckSheetScopeIsPersistent() {
        let root = DeckInfo(id: DeckID(10), name: "Parent::Child")
        let model = BrowseModel(rootDeck: root)
        #expect(model.buildQuery() == "deck:\"Parent::Child\"")
        #expect(model.activeDeck == root)

        model.source = .allDecks
        model.searchText = "front OR back"
        #expect(model.buildQuery() == "deck:\"Parent::Child\" ( front OR back )")
        model.source = .tag("verb")
        #expect(model.buildQuery() == "deck:\"Parent::Child\" ( tag:\"verb\" ) ( front OR back )")
        #expect(!model.searchTextIsPlainFreeText)
    }

    @Test("deck sheet excludes ancestors, siblings, and similarly named decks")
    func deckSheetAvailableDecks() {
        let root = DeckInfo(id: DeckID(10), name: "Parent::Child")
        let child = DeckInfo(id: DeckID(11), name: "Parent::Child::Nested")
        let model = BrowseModel(rootDeck: root)
        model.allDecks = [
            DeckInfo(id: DeckID(1), name: "Parent"), root, child,
            DeckInfo(id: DeckID(12), name: "Parent::Sibling"),
            DeckInfo(id: DeckID(13), name: "Parent::Childish"),
        ]
        #expect(model.availableDecks == [root, child])
        model.source = .deck(child.id)
        #expect(model.buildQuery() == "deck:\"Parent::Child\" ( deck:\"Parent::Child::Nested\" )")
        model.source = .deck(DeckID(1))
        #expect(model.buildQuery() == "deck:\"Parent::Child\"")
    }

    @Test("notes and cards backend searches keep the sheet scope")
    func scopedBackendQueries() async {
        let log = CallLog()
        await withDependencies {
            passthroughValidate(&$0)
            $0.noteClient.searchIds = { query, _ in log.record(query); return [] }
            $0.cardClient.searchIds = { query, _ in log.record(query); return [] }
        } operation: {
            let model = BrowseModel(rootDeck: DeckInfo(id: DeckID(10), name: "Parent::Child"))
            model.source = .allDecks
            model.searchText = "front OR back"
            await model.performSearch(debounce: .zero)
            model.mode = .cards
            await model.performSearch(debounce: .zero)
            let scoped = "deck:\"Parent::Child\" ( front OR back )"
            #expect(log.all.filter { $0 == scoped }.count == 2)
        }
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
            passthroughValidate(&$0)
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
            passthroughValidate(&$0)
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

    // Grammar errors set `searchError` from `validateQuery`. A thrown
    // `searchIds` also lands there so the list can show why it emptied.

    @Test("a failed search empties the list and records searchError")
    func failedSearchIsDistinguishable() async {
        struct Boom: Error {}

        await withDependencies {
            passthroughValidate(&$0)
            $0.noteClient.searchIds = { _, _ in throw Boom() }
            $0.cardClient.searchIds = { _, _ in [] }
        } operation: {
            let model = BrowseModel()
            await model.performSearch(debounce: .zero)

            #expect(model.ids.isEmpty)
            #expect(model.searchError != nil)
        }

        await withDependencies {
            passthroughValidate(&$0)
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
            passthroughValidate(&$0)
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
            $0.tagClient.tagTree = {
                TagTreeNodeData(name: "", fullPath: "", level: 0, collapsed: false, children: [])
            }
            $0.notetypesService.getNotetypeNames = { [] }
            $0.notetypesClient.listAll = { [] }
        } operation: {
            let model = BrowseModel()
            await model.loadInitial()

            #expect(log.all.isEmpty, "searching here too would issue the first query twice")
        }
    }
}

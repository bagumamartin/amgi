import AmgiAppCore
import AmgiAppShared
import AnkiBackend
import AnkiProtoBridge
import AnkiClients
import AnkiKit
import AnkiServices
import Dependencies
import Foundation
import os

/// Data state + load/search/mutation logic for the Browse screen (spec §4.4,
/// phase 2). The View owns navigation/sheets/toolbar; this model owns I/O.
///
/// Architecture vs. v1:
/// - Ids come back ENGINE-SORTED (`searchIds` order builtin) — there is no
///   client-side sort anywhere (D3 bans page-window sorting).
/// - No hard result cap: ids are cheap; *records* hydrate in chunks as the
///   visible window approaches them (`loadMoreIfNeeded` from row onAppear).
/// - Cards↔Notes modes share one id pipeline; hydration fans per mode.
/// - Every mutation rides a single engine RPC so undo produces one entry,
///   and mutation results refresh via `CollectionStore` generation instead
///   of a manual re-search (matches deck-icons behavior).
@Observable
@MainActor
final class BrowseModel {
    enum Mode: String, CaseIterable, Identifiable {
        case notes, cards

        var id: String { rawValue }

        var title: String {
            switch self {
            case .notes: "Notes"
            case .cards: "Cards"
            }
        }
    }

    /// Sort options map 1:1 to engine column keys (probed set in
    /// BrowseEngineProbesTests; rslib browser_table.rs serializations).
    /// Direction is independent state (`sortReverseOverride`): the case
    /// names the column, the override flips desktop's default per column.
    enum SortOrder: String, CaseIterable, Identifiable {
        case due = "cardDue"
        case createdDesc = "noteCrt"
        case modifiedDesc = "noteMod"
        case cardModifiedDesc = "cardMod"
        case sortFieldAsc = "noteFld"
        case notetypeAsc = "note"
        case tagsAsc = "noteTags"
        case intervalDesc = "cardIvl"
        case easeDesc = "cardEase"
        case repsDesc = "cardReps"
        case lapsesDesc = "cardLapses"

        var id: String { rawValue }

        var label: String {
            switch self {
            case .due: "Due date"
            case .createdDesc: "Date created"
            case .modifiedDesc: "Date edited"
            case .cardModifiedDesc: "Card modified"
            case .sortFieldAsc: "Sort field"
            case .notetypeAsc: "Note type"
            case .tagsAsc: "Tags"
            case .intervalDesc: "Interval"
            case .easeDesc: "Ease"
            case .repsDesc: "Reviews"
            case .lapsesDesc: "Lapses"
            }
        }

        var defaultReverse: Bool {
            switch self {
            case .due: false
            case .createdDesc, .modifiedDesc, .cardModifiedDesc,
                 .intervalDesc, .easeDesc, .repsDesc, .lapsesDesc: true
            case .sortFieldAsc, .notetypeAsc, .tagsAsc: false
            }
        }

        /// Back-compat: default direction for callers that predate the
        /// independent toggle.
        var reverse: Bool { defaultReverse }

        /// Flips direction while staying on the same column. The view
        /// persists the flip via `sortReverseOverride`, not by switching cases.
        var toggledDirection: SortOrder { self }
    }

    // MARK: View-facing state

    let rootDeck: DeckInfo?

    init(rootDeck: DeckInfo? = nil) {
        self.rootDeck = rootDeck
        if let rootDeck {
            source = .deck(rootDeck.id)
        }
    }

    var availableDecks: [DeckInfo] {
        guard let rootDeck else { return allDecks }
        let root = allDecks.first { $0.id == rootDeck.id } ?? rootDeck
        return [root] + allDecks.filter {
            $0.id != root.id && $0.name.hasPrefix(root.name + "::")
        }
    }

    var searchText = ""
    /// Engine-ordered raw item ids (cards or notes per mode). Cheap; never capped.
    private(set) var ids: [Int64] = []
    /// Hydrated records so far, keyed by id for O(1) row updates.
    private(set) var noteRecords: [Int64: NoteRecord] = [:]
    private(set) var cardRecords: [Int64: CardRecord] = [:]
    /// Rows surfaced to the list so far (ids[0..<windowEnd]).
    private(set) var windowEnd = 0
    var allDecks: [DeckInfo] = []
    var allTags: [String] = []
    /// The single sidebar selection. Replaces the old
    /// `parentDeck`/`activeDeck`/`activeTag` triple, which let the deck
    /// list and the tag list disagree about what was active (tags never even
    /// highlighted, because they bypassed the List selection binding).
    var source: BrowseSource = .allDecks
    var isLoading = false
    var hasMorePages = false
    var notetypeNames: [NotetypeID: String] = [:]
    var mode: Mode = .notes
    var sortOrder: SortOrder = .modifiedDesc
    /// Independent direction override (nil = column default). Persisted per
    /// mode so ascending/descending survives relaunches, desktop-style.
    var sortReverseOverride: Bool?

    /// Effective engine direction for the active sort.
    var effectiveSortReverse: Bool {
        sortReverseOverride ?? sortOrder.defaultReverse
    }

    func toggleSortDirection() {
        sortReverseOverride = !effectiveSortReverse
        persistViewPrefs()
    }

    /// Deck backing the current source, when it is a deck.
    var activeDeck: DeckInfo? {
        guard case .deck(let id) = source else { return nil }
        return availableDecks.first { $0.id == id }
    }

    /// Tag backing the current source, when it is a tag.
    var activeTag: String? {
        guard case .tag(let tag) = source else { return nil }
        return tag
    }

    /// Engine undo stack, for the Browse overflow item (not a toolbar glyph).
    private(set) var undoStatus: UndoStatusInfo?

    var canUndo: Bool { undoStatus?.canUndo ?? false }
    var canRedo: Bool { undoStatus?.canRedo ?? false }

    var undoMenuTitle: String {
        let text = undoStatus?.undoText.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !canUndo || text.isEmpty { return "Undo" }
        if text.lowercased().hasPrefix("undo") { return text }
        return "Undo \(text)"
    }

    var redoMenuTitle: String {
        let text = undoStatus?.redoText.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !canRedo || text.isEmpty { return "Redo" }
        if text.lowercased().hasPrefix("redo") { return text }
        return "Redo \(text)"
    }

    /// Engine-rendered browser rows keyed by result id. Cell order follows
    /// the active column set; populated lazily alongside record hydration.
    private(set) var browserRows: [Int64: BrowserRowData] = [:]
    /// Catalog of engine columns (`AllBrowserColumns`) for the column picker.
    private(set) var browserColumns: [BrowserColumnSpec] = []
    /// Persisted per-mode columns/sort (profile-scoped). Nil until loaded.
    var viewPrefs = BrowseViewPrefs()
    /// Hierarchical tag tree for the sidebar (desktop parity).
    private(set) var tagTree: TagTreeNodeData?
    /// Last Set Due Date input (desktop remembers the browser value).
    var lastSetDueExpression = "1"

    /// Select-mode plumbing stays view-owned via BrowseSelectionState.

    // Phase 3+ surface
    let savedSearches = SavedSearchStore()
    var searchError: String?
    /// Surfaced when a batch mutation partially or wholly fails.
    var errorMessage: String?
    /// Recent queries for search suggestions (max 30, per profile).
    private(set) var recentQueries: [String] = []
    /// Semantic fallback banner text; nil hides it.
    private(set) var semanticNotice: String?

    /// Row driving the detail column. Held as whole records rather than ids
    /// into `noteRecords`/`cardRecords`, because `performSearch` prunes those
    /// dictionaries to the current result set — and in Cards mode the note (or
    /// in Notes mode the card) is not in the result id space at all.
    private(set) var focusedNote: NoteRecord?
    private(set) var focusedCard: CardRecord?

    var focusedNoteID: Int64? { focusedNote?.id.rawValue }
    var focusedCardID: CardID? { focusedCard?.id }

    /// Drives `.task(id:)` on `BrowseView` so text, source, mode, and sort
    /// all restart one search — SwiftUI cancels the previous run.
    var searchIdentity: String {
        "\(buildQuery())|\(mode.rawValue)|\(sortOrder.rawValue)|\(effectiveSortReverse)"
    }

    /// First card of each note, resolved lazily by the row context menu.
    /// `@ObservationIgnored` so one row's lookup does not invalidate every
    /// other row's menu button.
    @ObservationIgnored private var firstCardIDs: [NoteID: CardID] = [:]

    /// Profile-scoped history: the shared key leaked queries across profiles.
    private static var historyKey: String {
        "browse.searchHistory.\(AccountStore.shared.current.id)"
    }
    /// Query recorded for history when this committed run started.
    private var lastCommittedQuery = ""

    private let windowSize = 100
    private let hydrateChunkSize = 50
    private var searchTask: Task<Void, Never>?

    @ObservationIgnored @Dependency(\.noteClient) private var noteClient
    @ObservationIgnored @Dependency(\.cardClient) private var cardClient
    @ObservationIgnored @Dependency(\.deckClient) private var deckClient
    @ObservationIgnored @Dependency(\.tagClient) private var tagClient
    @ObservationIgnored @Dependency(\.notetypesService) private var notetypesService
    @ObservationIgnored @Dependency(\.collectionStore) private var collectionStore

    // MARK: - Derived

    /// Count of ids surfaced to the list window.
    var loadedCount: Int {
        min(ids.count, windowEnd)
    }

    func note(at id: Int64) -> NoteRecord? { noteRecords[id] }
    func card(at id: Int64) -> CardRecord? { cardRecords[id] }

    // MARK: - Detail focus

    /// Notes-mode row activation: the note is the subject, and its first card
    /// supplies Preview rendering and the per-card Info facts.
    func focus(noteID: Int64) async {
        if let cached = noteRecords[noteID] {
            focusedNote = cached
        } else {
            focusedNote = try? await noteClient.fetch(NoteID(noteID))
        }
        guard let cid = (try? await cardClient.searchIds("nid:\(noteID)", nil))?.first else {
            focusedCard = nil
            return
        }
        if let cached = cardRecords[cid.rawValue] {
            focusedCard = cached
        } else {
            focusedCard = try? await cardClient.getCard(cid)
        }
    }

    /// Cards-mode row activation: the card is the subject, and its note backs
    /// the Edit tab. Without this the detail column stayed empty in Cards mode.
    func focus(cardID: Int64) async {
        if let cached = cardRecords[cardID] {
            focusedCard = cached
        } else {
            focusedCard = try? await cardClient.getCard(CardID(cardID))
        }
        guard let nid = focusedCard?.nid else {
            focusedNote = nil
            return
        }
        if let cached = noteRecords[nid.rawValue] {
            focusedNote = cached
        } else {
            focusedNote = try? await noteClient.fetch(nid)
        }
    }

    func clearFocus() {
        focusedNote = nil
        focusedCard = nil
    }

    // MARK: - Search pipeline

    /// Debounced entry point kept for call sites that already mutated
    /// `searchText` / `source`. The view's `.task(id: searchIdentity)`
    /// is the real driver; this just runs an immediate search when the
    /// identity would not change (e.g. a refresh of the same query).
    func scheduleSearch(immediate: Bool = false) {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            if !immediate {
                try? await Task.sleep(for: .milliseconds(250))
                if Task.isCancelled { return }
            }
            await self?.performSearch()
        }
    }

    /// History records EXPLICIT commits only — Return in the field or
    /// picking a suggestion. Per-keystroke debounced runs are browsing,
    /// not queries worth remembering.
    func commitSearchHistory() {
        let candidate = searchText.trimmingCharacters(in: .whitespaces)
        guard !candidate.isEmpty, candidate != lastCommittedQuery else { return }
        lastCommittedQuery = candidate
        recordHistory(candidate)
    }

    /// Empties in-memory history and the persisted `"browse.searchHistory"`
    /// key.
    func clearSearchHistory() {
        UserDefaults.standard.removeObject(forKey: Self.historyKey)
        recentQueries = []
        lastCommittedQuery = ""
    }

    func performSearch(debounce: Duration = .zero) async {
        if debounce > .zero {
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
        }
        isLoading = true
        defer { isLoading = false }
        let query = buildQuery()
        let order = order()
        // Validate first so grammar errors surface inline instead of
        // masquerading as legitimate zero-result searches.
        do {
            _ = try await noteClient.validateQuery(query)
            await MainActor.run { self.searchError = nil }
        } catch is CancellationError {
            return
        } catch {
            await MainActor.run {
                self.searchError = error.localizedDescription
                self.ids = []
                self.noteRecords.removeAll()
                self.cardRecords.removeAll()
                self.windowEnd = 0
                self.hasMorePages = false
                self.resultDeckIDs = []
            }
            return
        }
        do {
            let newIDs: [Int64]
            switch mode {
            case .notes:
                newIDs = try await noteClient.searchIds(query, order).map(\.rawValue)
            case .cards:
                newIDs = try await cardClient.searchIds(query, order).map(\.rawValue)
            }
            guard !Task.isCancelled else { return }
            // Desktop invalidates row data after every query: cached records
            // for surviving ids are stale the moment any mutation landed, so
            // drop everything and re-hydrate the visible window fresh.
            // (Filtering to `newIDs.contains` kept pre-edit field text on screen.)
            noteRecords.removeAll()
            cardRecords.removeAll()
            browserRows.removeAll()
            ids = newIDs
            if windowEnd == 0 || windowEnd > ids.count {
                windowEnd = min(ids.count, windowSize)
            } else {
                windowEnd = min(ids.count, max(windowSize, windowEnd))
            }
            hasMorePages = windowEnd < ids.count
            await hydrateWindow()
            resolveResultDecks()
        } catch is CancellationError {
        } catch {
            ids = []
            noteRecords.removeAll()
            cardRecords.removeAll()
            browserRows.removeAll()
            windowEnd = 0
            hasMorePages = false
            resultDeckIDs = []
            searchError = error.localizedDescription
        }
    }

    /// Deck ids whose cards match the current query — drives the macOS
    /// source column's "decks with matching cards" filter. Notes carry no
    /// deck, so this resolves dids from a bounded sample of matching cards
    /// (batched off-main like hydration) and rolls them up to ancestors.
    private(set) var resultDeckIDs: Set<Int64> = []
    private var resultDeckTask: Task<Void, Never>?

    private func resolveResultDecks() {
        resultDeckTask?.cancel()
        // Keyed off the TYPED text, not the composed query: the composed query
        // is never empty now (an unscoped browse is "deck:*"), and sampling
        // 240 cards to highlight "decks containing matches" is only meaningful
        // while the user is actually searching for something.
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            resultDeckIDs = []
            return
        }
        let sampleCap = 240
        resultDeckTask = Task { [cardClient] in
            guard let cardIds = try? await cardClient.searchIds(trimmed, nil) else { return }
            var dids: Set<Int64> = []
            for start in stride(from: 0, to: min(cardIds.count, sampleCap), by: 6) {
                if Task.isCancelled { return }
                let batch = cardIds[start..<min(start + 6, cardIds.count)]
                await withTaskGroup(of: Int64?.self) { group in
                    for cid in batch {
                        group.addTask { (try? await cardClient.getCard(cid))?.did.rawValue }
                    }
                    for await did in group where did != nil {
                        dids.insert(did!)
                    }
                }
            }
            guard !Task.isCancelled else { return }
            let decks = await MainActor.run { self.allDecks }
            // Roll each hit up to its ancestor chain ("A::B::C" → A, A::B).
            let byName = Dictionary(uniqueKeysWithValues: decks.map { ($0.name, $0.id.rawValue) })
            for deck in decks where dids.contains(deck.id.rawValue) {
                var parts = deck.name.split(separator: "::").map(String.init)
                parts.removeLast()
                var ancestor = ""
                for part in parts {
                    ancestor = ancestor.isEmpty ? part : ancestor + "::" + part
                    if let id = byName[ancestor] { dids.insert(id) }
                }
            }
            await MainActor.run { self.resultDeckIDs = dids }
        }
    }

    private func order() -> SearchOrder {
        SearchOrder(.builtin(column: sortOrder.rawValue, reverse: effectiveSortReverse))
    }

    func loadDecks() async {
        allDecks = (try? await deckClient.fetchAll()) ?? []
    }

    func loadInitial() async {
        loadViewPrefs()
        applyDefaultSearchIfEmpty()
        await loadDecks()
        allTags = ((try? await tagClient.getAllTags()) ?? []).sorted()
        if let tree = try? await tagClient.tagTree() {
            tagTree = tree
        }
        // Nothing loaded saved searches at startup, so the sidebar section and
        // the tools menu stayed empty until the user saved or deleted one.
        savedSearches.refresh()
        // Same for history: `recentQueries` only ever grew in-session, so the
        // search field offered no suggestions on a fresh launch.
        loadHistory()
        await loadBrowserColumns()
        Task { await loadNotetypeChildren() }
        let notetypes = notetypesService
        if let pairs = try? await backendOffload({ try notetypes.getNotetypeNames() }) {
            notetypeNames = Dictionary(uniqueKeysWithValues: pairs.map { ($0.id, $0.name) })
        }
        // The embedding corpus must build in the background for the
        // semantic fallback ("Search meaning of…") to ever be offered —
        // without this kickoff it was dead code and near-miss spellings
        // ("Levelling" vs "leveling") dead-ended at zero results.
        kickOffSemanticIndexBuild()
        // Search itself is driven by BrowseView `.task(id: searchIdentity)`.
    }

    /// Row onAppear hook: extend the visible window toward the user.
    func loadMoreIfNeeded(index: Int) async {
        guard index >= windowEnd - 10, windowEnd < ids.count else {
            hasMorePages = windowEnd < ids.count
            return
        }
        windowEnd = min(ids.count, windowEnd + windowSize)
        hasMorePages = windowEnd < ids.count
        await hydrateWindow()
    }

    func hydrateWindow() async {
        switch mode {
        case .notes:
            let missing = Array(ids.prefix(windowEnd).filter { noteRecords[$0] == nil })
            await hydrateInBatches(missing) { [noteClient] nidRaw in
                let nid = NoteID(nidRaw)
                if let note = try? await noteClient.fetch(nid) ?? nil {
                    await MainActor.run { self.noteRecords[nidRaw] = note }
                }
            }
        case .cards:
            let missing = Array(ids.prefix(windowEnd).filter { cardRecords[$0] == nil })
            await hydrateInBatches(missing) { [cardClient, noteClient] cidRaw in
                let cid = CardID(cidRaw)
                if let card = try? await cardClient.getCard(cid) {
                    await MainActor.run { self.cardRecords[cidRaw] = card }
                    let noteID = card.nid
                    let needsNote = await MainActor.run { self.noteRecords[noteID.rawValue] == nil }
                    if needsNote, let note = try? await noteClient.fetch(noteID) ?? nil {
                        await MainActor.run { self.noteRecords[noteID.rawValue] = note }
                    }
                }
            }
        }
    }

    func parentNoteTitle(for card: CardRecord) -> String? {
        guard let note = noteRecords[card.nid.rawValue] else { return nil }
        return browsePlainTextTitle(for: note, fallback: notetypeNames[note.mid])
    }

    /// Runs fetches through a small worker pool. Each RPC blocks an FFI
    /// thread under the hood; dozens of concurrent calls saturate the Swift
    /// cooperative pool and hydration never completes (Cards mode hung on
    /// "Loading…" rows indefinitely). Batching keeps at most `batchSize`
    /// engine calls in flight.
    private func hydrateInBatches(
        _ ids: [Int64], batchSize: Int = 6,
        _ fetch: @escaping @Sendable (Int64) async -> Void
    ) async {
        var start = ids.startIndex
        while start < ids.endIndex {
            let end = min(ids.endIndex, start + batchSize)
            let batch = ids[start..<end]
            await withTaskGroup(of: Void.self) { group in
                for idRaw in batch {
                    group.addTask { await fetch(idRaw) }
                }
            }
            start = end
        }
    }

    /// Resolves (once) the first card of a note, for the row context menu.
    func firstCardID(for noteId: NoteID) async -> CardID? {
        if let cached = firstCardIDs[noteId] { return cached }
        guard let cardId = (try? await cardClient.fetchByNote(noteId))?.first?.id else {
            return nil
        }
        firstCardIDs[noteId] = cardId
        return cardId
    }

    // MARK: - Mutations (batch, undo-friendly)

    func delete(_ id: NoteID) async {
        await run("delete") { try await self.noteClient.deleteBatch([id]) }
    }

    // MARK: Card-scope resolution (P1A)
    //
    // Upstream card mode operates on selected CARD ids; note mode expands
    // selected notes to all their cards. Every batch entry point therefore
    // takes explicit card ids plus note ids and prefers the card set when
    // non-empty, so one template's card never drags its siblings along.

    /// Cards of the given notes via ONE comma-form `nid:` search.
    private func cardsOfNotes(_ noteIds: [NoteID]) async -> [CardID] {
        guard !noteIds.isEmpty else { return [] }
        guard let query = BrowseSearchGrammar.noteIDs(noteIds) else { return [] }
        return (try? await cardClient.searchIds(query, nil)) ?? []
    }

    /// Notes backing the given cards (for tag/mark/delete paths).
    func noteIDsOfCards(_ cardIds: [CardID]) async -> [NoteID] {
        var seen = Set<NoteID>()
        var ordered: [NoteID] = []
        for cid in cardIds {
            let nid: NoteID?
            if let cached = cardRecords[cid.rawValue]?.nid {
                nid = cached
            } else {
                nid = (try? await cardClient.getCard(cid))?.nid
            }
            if let nid, seen.insert(nid).inserted { ordered.append(nid) }
        }
        return ordered
    }

    /// Resolve the effective card set: explicit cards win; otherwise expand notes.
    func resolveTargetCards(cardIDs: [CardID], noteIDs: [NoteID]) async -> [CardID] {
        if !cardIDs.isEmpty { return cardIDs }
        return await cardsOfNotes(noteIDs)
    }

    /// Resolve the effective note set: explicit notes win; otherwise derive
    /// from cards (tag/mark/delete operate on notes).
    func resolveTargetNotes(cardIDs: [CardID], noteIDs: [NoteID]) async -> [NoteID] {
        if !noteIDs.isEmpty { return Array(noteIDs) }
        return await noteIDsOfCards(cardIDs)
    }

    func suspendSelected(_ noteIDs: Set<NoteID>, cardIDs: [CardID] = []) async {
        let cards = await resolveTargetCards(cardIDs: cardIDs, noteIDs: Array(noteIDs))
        await run("suspend") { try await self.cardClient.suspendCards(cards, []) }
    }

    func unSuspendSelected(_ noteIDs: Set<NoteID>, cardIDs: [CardID]) async {
        // Card scope when present; note expansion otherwise (never both —
        // passing both would double-cover siblings).
        let cards: [CardID]
        if !cardIDs.isEmpty {
            cards = cardIDs
        } else {
            cards = await cardsOfNotes(Array(noteIDs))
        }
        await run("unsuspend") { try await self.cardClient.restoreBuriedAndSuspended(cards) }
    }

    func burySelected(_ noteIDs: Set<NoteID>, cardIDs: [CardID] = []) async {
        let cards = await resolveTargetCards(cardIDs: cardIDs, noteIDs: Array(noteIDs))
        await run("bury") { try await self.cardClient.buryUserCards(cards, []) }
    }

    func flagSelected(_ noteIDs: Set<NoteID>, cardIDs: [CardID] = [], value: UInt32) async {
        let cards = await resolveTargetCards(cardIDs: cardIDs, noteIDs: Array(noteIDs))
        // One setFlag RPC → one undo entry (per-card loop broke undo grouping).
        await run("flag") { try await self.cardClient.setFlags(cards, value) }
    }

    /// Bulk forget with desktop options (restore position / reset counts).
    func forgetSelected(_ noteIDs: Set<NoteID>, cardIDs: [CardID] = [], restorePosition: Bool, resetCounts: Bool) async {
        let cards = await resolveTargetCards(cardIDs: cardIDs, noteIDs: Array(noteIDs))
        await run("forget") {
            try await self.cardClient.forgetCards(cards, restorePosition, resetCounts)
        }
    }

    func deleteSelected(_ noteIDs: Set<NoteID>) async {
        // One removeNotes transaction → one engine undo entry (D6).
        await run("delete") { try await self.noteClient.deleteBatch(Array(noteIDs)) }
    }

    func changeDeckSelected(_ cardIDs: [CardID], deckId: DeckID) async {
        await run("move") { _ = try await self.cardClient.changeDeck(cardIDs, deckId) }
    }

    func addTag(_ tag: String, to noteIDs: Set<NoteID>) async {
        await run("tag") { try await self.tagClient.addTagToNotes(tag, Array(noteIDs)) }
    }

    func removeTag(_ tag: String, from noteIDs: Set<NoteID>) async {
        await run("untag") { try await self.tagClient.removeTagFromNotes(tag, Array(noteIDs)) }
    }

    func gradeNowSelected(_ cardIDs: [CardID], rating: Rating) async {
        await run("grade") { try await self.cardClient.gradeNow(cardIDs, rating) }
    }

    func repositionSelected(_ cardIDs: [CardID], start: UInt32, step: UInt32) async {
        await run("reposition") { _ = try await self.cardClient.repositionCards(cardIDs, start, step, false, false) }
    }

    private func run(_ verb: String, _ work: () async throws -> Void) async {
        do {
            try await work()
        } catch {
            errorMessage = "Couldn't \(verb): \(error.localizedDescription)"
            Log.browse.error("Browse \(verb) failed: \(error)")
        }
        await refreshAfterMutation()
    }

    private func runBatch<ID>(
        _ verb: String,
        over ids: [ID],
        _ work: (ID) async throws -> Void
    ) async {
        var failures = 0
        var firstError: String?
        for id in ids {
            do {
                try await work(id)
            } catch {
                failures += 1
                if firstError == nil { firstError = error.localizedDescription }
                Log.browse.error("Batch \(verb) failed for one item: \(error)")
            }
        }
        if failures > 0 {
            errorMessage = failures == ids.count
                ? "Couldn't \(verb) \(failures == 1 ? "that item" : "those \(failures) items"): \(firstError ?? "unknown error")"
                : "\(failures) of \(ids.count) items couldn't be \(verb)d: \(firstError ?? "unknown error")"
        }
        await refreshAfterMutation()
    }

    func refreshUndoStatus() async {
        undoStatus = try? await cardClient.undoStatus()
    }

    func undoLast() async {
        guard canUndo else { return }
        do {
            try await cardClient.undoLast()
        } catch {
            errorMessage = "Couldn't undo: \(error.localizedDescription)"
        }
        await refreshAfterMutation()
    }

    func redoLast() async {
        guard canRedo else { return }
        do {
            try await cardClient.redoLast()
        } catch {
            errorMessage = "Couldn't redo: \(error.localizedDescription)"
        }
        await refreshAfterMutation()
    }

    /// After any engine op the CollectionStore generation bumps itself via
    /// OpChanges observation (same rails as deck icons); we re-run the
    /// search against fresh data here. Focused row/inspector records are
    /// re-fetched so Preview/Info never show pre-mutation field text.
    func refreshAfterMutation() async {
        collectionStore.invalidateAll(origin: .localUser)
        // Drop focused records — performSearch clears the caches, and the
        // ids below re-resolve against the post-mutation collection.
        let noteID = focusedNote?.id
        let cardID = focusedCard?.id
        await performSearch()
        if let noteID {
            focusedNote = try? await noteClient.fetch(noteID)
        }
        if let cardID {
            focusedCard = try? await cardClient.getCard(cardID)
        } else if let noteID, focusedCard == nil {
            if let cid = (try? await cardClient.searchIds("nid:\(noteID.rawValue)", nil))?.first {
                focusedCard = try? await cardClient.getCard(cid)
            }
        }
        await refreshUndoStatus()
    }


    // MARK: - Sidebar search composition (desktop modifier-click)

    enum RailComposition {
        case replace            // plain tap
        case andWithExisting    // ⌃-click analog
        case orWithExisting     // ⇧-click analog
        case negateAndAdd       // ⌥-click analog
    }

    /// AND keeps the current sidebar source and adds the fragment to the
    /// search field. OR flattens `buildQuery()` into the search field so the
    /// source is not silently ANDed. Exclude is AND-not against the field.
    func composeSidebarNode(_ node: FilterNode, composition: RailComposition) async {
        switch composition {
        case .replace:
            searchText = node.fragment
            source = .allDecks
        case .andWithExisting:
            await applyFilterNode(node, composition: .andWithExisting)
        case .orWithExisting:
            let existing = buildQuery()
            source = .allDecks
            if existing == "deck:*" || existing.trimmingCharacters(in: .whitespaces).isEmpty {
                searchText = node.fragment
            } else {
                searchText = existing
                await applyFilterNode(node, composition: .orWithExisting)
            }
        case .negateAndAdd:
            await applyFilterNode(node, composition: .negateAndAdd)
        }
    }

    /// Applies a node to the typed search field with desktop composition
    /// semantics, always canonicalized by the engine so the string stays
    /// valid grammar even when hand-built fragments nest oddly.
    func applyFilterNode(_ node: FilterNode, composition: RailComposition) async {
        switch composition {
        case .replace:
            searchText = node.fragment
        case .negateAndAdd:
            applyComposed(existing: activeBaseQuery(), additional: node.fragment) { fragment in
                "( not ( \(fragment) ) )"
            }
        case .andWithExisting:
            if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                searchText = node.fragment
            } else {
                await composeViaEngine(additional: node.fragment, joiner: .and)
            }
        case .orWithExisting:
            if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                searchText = node.fragment
            } else {
                await composeViaEngine(additional: node.fragment, joiner: .or)
            }
        }
    }

    /// Desktop "replace existing search nodes of the same type" (e.g. picking
    /// a different card state swaps the old `is:` node instead of AND-ing).
    func replaceNodeOfSameType(with fragment: String) async {
        let existing = searchText
        guard !existing.trimmingCharacters(in: .whitespaces).isEmpty else {
            searchText = fragment
            return
        }
        if let replaced = try? await ankiBackend.invoke(
            .replaceSearchNode(previous: existing, replacement: fragment)
        ) {
            searchText = replaced
        } else {
            searchText = fragment
        }
    }

    private func activeBaseQuery() -> String { searchText }

    /// Synchronous textual composition — engine AND is a space join;
    /// negation wraps the fragment. Used on replace/negate paths where
    /// waiting on an RPC before re-search adds latency without value.
    private func applyComposed(existing: String, additional: String, transform: (String) -> String) {
        let base = existing.trimmingCharacters(in: .whitespaces)
        let combined = base.isEmpty ? transform(additional) : base + " " + transform(additional)
        searchText = combined
    }

    /// Engine-canonical join for AND/OR (async path).
    private func composeViaEngine(additional: String, joiner: SearchJoiner) async {
        let existing = searchText
        if let composed = try? await noteClient.composeQuery(
            existing: existing, additional: additional, joiner: joiner
        ) {
            searchText = composed
        } else {
            switch joiner {
            case .and:
                searchText = existing + " " + additional
            case .or:
                searchText = "(\(existing)) OR (\(additional))"
            }
        }
    }

    func validateCurrentQuery() {
        let candidate = buildQuery()
        guard !candidate.isEmpty else { searchError = nil; return }
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.noteClient.validateQuery(candidate)
                await MainActor.run { self.searchError = nil }
            } catch is CancellationError {
            } catch {
                await MainActor.run { self.searchError = error.localizedDescription }
            }
        }
    }

    // Saved searches --------------------------------------------------------

    func saveCurrentQuery(as name: String) {
        let query = buildQuery()
        guard !query.isEmpty else { return }
        savedSearches.save(name: name, query: query)
        collectionStore.invalidateAll(origin: .localUser)
    }

    func deleteSavedSearch(named name: String) {
        savedSearches.delete(name: name)
        if case .saved(let current) = source, current == name {
            source = .allDecks
        }
        collectionStore.invalidateAll(origin: .localUser)
    }

    // MARK: - Search history (spec §6)

    private func loadHistory() {
        recentQueries = UserDefaults.standard.stringArray(forKey: Self.historyKey) ?? []
    }

    private func recordHistory(_ query: String) {
        var history = UserDefaults.standard.stringArray(forKey: Self.historyKey) ?? []
        history.removeAll { $0 == query }
        history.insert(query, at: 0)
        history = Array(history.prefix(30))
        UserDefaults.standard.set(history, forKey: Self.historyKey)
        recentQueries = history
    }

    // MARK: - Semantic fallback (spec D4)

    private var semanticKickoffStarted = false

    /// Builds/refreshes the embedding corpus once per session, bounded,
    /// fully off-main-thread work inside TextEmbedder's actor.
    private func kickOffSemanticIndexBuild() {
        guard !semanticKickoffStarted else { return }
        semanticKickoffStarted = true
        Task { [weak self] in
            guard let self else { return }
            // Extracted as a function value: some Xcode 26.5 whole-module
            // plans mislabel this closure call otherwise.
            let searchAll = self.noteClient.searchAll
            let limit: Int? = SemanticNoteIndex.corpusCap
            guard let records = try? await searchAll("deck:*", limit),
                  !records.isEmpty else { return }
            await SemanticNoteIndex.shared.updateCorpus(with: records)
        }
    }

    /// Replaces current results with semantic nearest neighbors of the
    /// free-text query. Only offered when the grammar path came up empty
    /// and no structured filters are pinned.
    func runSemanticFallback() async {
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        guard rootDeck == nil, mode == .notes, !trimmed.isEmpty else { return }
        guard let matches = await SemanticNoteIndex.shared.search(trimmed, topK: 50) else {
            semanticNotice = "Semantic index still building…"
            return
        }
        guard !matches.isEmpty else {
            semanticNotice = "No semantically similar notes found."
            return
        }
        noteRecords.removeAll()
        cardRecords.removeAll()
        // The neighbor ids have to land in `ids` — a local binding shadowed it
        // here, so the fallback used to re-hydrate the previous (empty) result
        // window and silently show nothing.
        ids = matches
        windowEnd = min(ids.count, windowSize)
        hasMorePages = false
        semanticNotice = "Meaning-based matches for “\(trimmed)”"
        await hydrateWindow()
    }

    func clearSemanticNotice() { semanticNotice = nil }

    // MARK: - Power-tool plumbing (selection-scope resolution)

    /// Card IDs for the given notes via one comma-form `nid:` search.
    /// Legacy helper kept for single-scope callers; prefer the
    /// card-scope `resolveTargetCards` pair above for batch actions.
    func resolveCardIds(for noteIds: [NoteID]) async -> [CardID] {
        await cardsOfNotes(noteIds)
    }

    func changeDeckSelected(_ noteIDs: Set<NoteID>, cardIDs: [CardID] = [], deckId: DeckID) async {
        let cards = await resolveTargetCards(cardIDs: cardIDs, noteIDs: Array(noteIDs))
        await run("move") { _ = try await self.cardClient.changeDeck(cards, deckId) }
    }

    func setDueDateSelected(_ noteIDs: Set<NoteID>, cardIDs: [CardID] = [], expression: String) async {
        let cards = await resolveTargetCards(cardIDs: cardIDs, noteIDs: Array(noteIDs))
        lastSetDueExpression = expression
        await run("set due date") { try await self.cardClient.setDueDate(cards, expression) }
    }

    func gradeNowSelectedNotes(_ noteIDs: Set<NoteID>, cardIDs: [CardID] = [], rating: Rating) async {
        let cards = await resolveTargetCards(cardIDs: cardIDs, noteIDs: Array(noteIDs))
        await run("grade") { try await self.cardClient.gradeNow(cards, rating) }
    }

    func repositionSelectedNotes(_ noteIDs: Set<NoteID>, cardIDs: [CardID] = [], start: UInt32, step: UInt32, randomize: Bool, shift: Bool) async {
        let cards = await resolveTargetCards(cardIDs: cardIDs, noteIDs: Array(noteIDs))
        await run("reposition") { _ = try await self.cardClient.repositionCards(cards, start, step, randomize, shift) }
    }

    func toggleMarkSelected(_ noteIDs: Set<NoteID>, cardIDs: [CardID] = []) async {
        let notes = await resolveTargetNotes(cardIDs: cardIDs, noteIDs: Array(noteIDs))
        guard !notes.isEmpty else { return }
        let anyMarked = notes.contains { id in
            noteRecords[id.rawValue]?.tags.split(separator: " ")
                .contains { $0.caseInsensitiveCompare("marked") == .orderedSame } == true
        }
        if anyMarked {
            await run("unmark") { try await self.tagClient.removeTagFromNotes("marked", notes) }
        } else {
            await run("mark") { try await self.tagClient.addTagToNotes("marked", notes) }
        }
    }

    /// Find & Replace.
    ///
    /// - Selection present → that scope (cards resolve to their notes).
    /// - No selection → **every** result id (not just the loaded window),
    ///   with Cards mode resolving through card records + fallback fetches.
    /// - `tagsTarget` routes to the tag engine op (desktop "Tags" picker row).
    /// - Empty scope (no selection AND no results) with `selectedScopeOnly ==
    ///   false` means collection-wide, matching desktop's unchecked box.
    func findAndReplace(
        search: String, replacement: String, regex: Bool, matchCase: Bool,
        fieldName: String?, tagsTarget: Bool = false,
        scopeNoteIds: [NoteID]? = nil, scopeCardIds: [CardID]? = nil,
        selectedScopeOnly: Bool = true
    ) async -> Int {
        let scopeNotes = scopeNoteIds ?? []
        let scopeCards = scopeCardIds ?? []
        let targets: [NoteID]
        if !scopeNotes.isEmpty {
            targets = scopeNotes
        } else if !scopeCards.isEmpty {
            targets = await noteIDsOfCards(scopeCards)
        } else if mode == .notes {
            targets = ids.map { NoteID($0) }
        } else {
            // Cards mode, no selection: resolve ALL result cards to notes.
            var seen = Set<NoteID>()
            var ordered: [NoteID] = []
            for cidRaw in ids {
                let nid: NoteID?
                if let cached = cardRecords[cidRaw]?.nid {
                    nid = cached
                } else {
                    nid = (try? await cardClient.getCard(CardID(cidRaw)))?.nid
                }
                if let nid, seen.insert(nid).inserted { ordered.append(nid) }
            }
            targets = ordered
        }
        // Desktop: unchecked "selected notes" with an empty scope = all notes.
        let effectiveTargets = targets
        let collectionWide = effectiveTargets.isEmpty && !selectedScopeOnly
        guard !effectiveTargets.isEmpty || collectionWide else { return 0 }
        do {
            let count: Int
            if tagsTarget {
                try await tagClient.findAndReplaceTag(
                    effectiveTargets, search, replacement, regex, matchCase
                )
                // Tag op returns OpChangesWithCount; count surfaces via refresh.
                count = effectiveTargets.isEmpty ? 0 : effectiveTargets.count
            } else {
                count = try await noteClient.findAndReplace(
                    noteIds: effectiveTargets, search: search, replacement: replacement,
                    regex: regex, matchCase: matchCase, fieldName: fieldName
                )
            }
            await refreshAfterMutation()
            return count
        } catch {
            errorMessage = "Couldn't find & replace: \(error.localizedDescription)"
            return 0
        }
    }

    /// Union of field names across the effective scope (desktop picker source).
    func fieldNamesForScope(noteIDs: [NoteID], cardIDs: [CardID]) async -> [String] {
        var notes = noteIDs
        if notes.isEmpty, !cardIDs.isEmpty {
            notes = await noteIDsOfCards(cardIDs)
        }
        if notes.isEmpty {
            notes = ids.prefix(200).map { mode == .notes ? NoteID($0) : nil }.compactMap { $0 }
            if notes.isEmpty, mode == .cards {
                notes = await noteIDsOfCards(ids.prefix(200).map { CardID($0) })
            }
        }
        guard !notes.isEmpty else { return [] }
        return (try? await noteClient.fieldNames(Array(notes.prefix(200)))) ?? []
    }

    // MARK: - Duplicates data (spec §5.9)

    @ObservationIgnored @Dependency(\.ankiBackend) private var ankiBackend

    /// Exact groups straight from the rslib aux service.
    func exactDuplicateGroups(field: String, searchText text: String) async -> FindDuplicatesResult? {
        try? await ankiBackend.invoke(.findDuplicatesExact(search: text, fieldName: field))
    }

    /// Fuzzy clusters over currently loaded notes (scope-limited O(n²)).
    func nearDuplicateGroupsInScope() -> [[Int64]] {
        SemanticNoteIndex.shared.nearDuplicateGroups(scope: Array(ids.prefix(windowEnd)))
    }

    /// True when the user's text is pure free-text (no pinned grammar
    /// fragments) — gates the semantic fallback suggestion so scoped or
    /// structural searches never get "search meaning of…" noise.
    var searchTextIsPlainFreeText: Bool {
        guard rootDeck == nil else { return false }
        return BrowseSearchGrammar.isPlainFreeText(searchText)
    }

    // MARK: - Query assembly (phase 3 replaces chips with tokens)

    func buildQuery() -> String {
        var parts: [String] = []
        switch source {
        case .allDecks:
            break
        case .deck(let id):
            if let deck = availableDecks.first(where: { $0.id == id }), deck.id != rootDeck?.id {
                parts.append(DeckSearch.term(deck.name))
            }
        case .tag, .untagged, .flag, .cardState, .today, .notetype:
            if let fragment = source.queryFragment() {
                parts.append(fragment)
            }
        case .saved(let name):
            if let query = savedSearches.searches.first(where: { $0.name == name })?.query {
                parts.append("( \(query) )")
            }
        }
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            parts.append(trimmed)
        }
        if let rootDeck {
            let root = availableDecks.first { $0.id == rootDeck.id } ?? rootDeck
            // Keep every mutable filter inside the immutable sheet scope, including OR searches.
            return ([DeckSearch.term(root.name)] + parts.map { "( \($0) )" })
                .joined(separator: " ")
        }
        // An unscoped browse with no text used to compose the empty string,
        // which left the list column showing a placeholder instead of the
        // collection. "deck:*" is the whole collection and is the same
        // fragment the semantic corpus build already relies on.
        guard !parts.isEmpty else { return "deck:*" }
        return parts.joined(separator: " ")
    }

    /// Standalone query for a sidebar row, independent of the typed search
    /// field — used to resolve mass-action targets.
    func query(
        for source: BrowseSource,
        includeSubdecks: Bool = true
    ) -> String {
        switch source {
        case .deck(let id):
            guard let deck = availableDecks.first(where: { $0.id == id }) else {
                return "deck:*"
            }
            let term = DeckSearch.term(deck.name)
            guard includeSubdecks else {
                return "\(term) -\(DeckSearch.term(deck.name + "::*"))"
            }
            return term
        case .saved(let name):
            return savedSearches.searches.first(where: { $0.name == name })?.query
                ?? "deck:*"
        default:
            return source.queryFragment() ?? "deck:*"
        }
    }

    func title(for source: BrowseSource) -> String {
        switch source {
        case .allDecks:
            return "All Decks"
        case .deck(let id):
            guard let deck = availableDecks.first(where: { $0.id == id }) else { return "Deck" }
            return deck.name.split(separator: "::").last.map(String.init) ?? deck.name
        case .tag(let tag):
            return tag.split(separator: "::").last.map(String.init) ?? tag
        case .untagged:
            return "Untagged"
        case .saved(let name):
            return name
        case .flag(let value):
            if value == 0 { return "No flag" }
            return FlagLabelStore.defaults[String(value)] ?? "Flag \(value)"
        case .cardState(let state):
            return state.title
        case .today(let fragment):
            return BrowseFilterSections.today().first { $0.fragment == fragment }?.title
                ?? "Today"
        case .notetype(let name):
            return name
        }
    }

    /// Search the engine for every note and card matching a sidebar scope.
    func searchScope(
        _ source: BrowseSource,
        includeSubdecks: Bool = true
    ) async -> (notes: [NoteID], cards: [CardID]) {
        let query = query(for: source, includeSubdecks: includeSubdecks)
        async let notes = (try? await noteClient.searchIds(query, nil)) ?? []
        async let cards = (try? await cardClient.searchIds(query, nil)) ?? []
        return await (notes, cards)
    }

    func filterNode(for source: BrowseSource) -> FilterNode? {
        switch source {
        case .allDecks:
            return FilterNode(title: "All decks", systemImage: "square.stack.3d.up.fill",
                              fragment: "deck:*", role: nil)
        case .deck(let id):
            guard let deck = availableDecks.first(where: { $0.id == id }) else { return nil }
            return FilterNode(
                title: title(for: source),
                systemImage: "books.vertical",
                fragment: DeckSearch.term(deck.name),
                role: nil
            )
        case .tag(let tag):
            return FilterNode(title: tag, systemImage: "tag",
                              fragment: BrowseSource.tag(tag).queryFragment() ?? "", role: nil)
        case .untagged:
            return FilterNode(title: "Untagged", systemImage: "tag.slash",
                              fragment: "tag:none", role: nil)
        case .saved(let name):
            guard let query = savedSearches.searches.first(where: { $0.name == name })?.query else {
                return nil
            }
            return FilterNode(title: name, systemImage: "heart", fragment: query, role: nil)
        case .flag(let value):
            if value == 0 {
                return BrowseFilterSections.flags().first { $0.fragment == "flag:0" }
            }
            return BrowseFilterSections.flags().first {
                if case .flag(let n) = $0.role { return n == value }
                return false
            }
        case .cardState(let state):
            return BrowseFilterSections.cardStates().first {
                if case .state(let s) = $0.role { return s == state }
                return false
            }
        case .today(let fragment):
            return BrowseFilterSections.today().first { $0.fragment == fragment }
        case .notetype(let name):
            return FilterNode(
                title: name,
                systemImage: "doc.text",
                fragment: BrowseSource.notetype(name).queryFragment() ?? "",
                role: nil
            )
        }
    }

    /// Synchronous note resolution for sheet presentation (cached records
    /// only — async `resolveTargetNotes` runs at apply time for the rest).
    func cachedNotesForSelection(noteIDs: Set<NoteID>, cardIDs: Set<CardID>) -> Set<NoteID> {
        if !noteIDs.isEmpty { return noteIDs }
        let derived = cardIDs.compactMap { cardRecords[$0.rawValue]?.nid }
        return Set(derived)
    }

    // MARK: - Selection commands (P2)

    /// All result ids in the active mode (not just the loaded window).
    var allResultNoteIDs: [NoteID] { mode == .notes ? ids.map { NoteID($0) } : [] }
    var allResultCardIDs: [CardID] { mode == .cards ? ids.map { CardID($0) } : [] }

    /// Sibling cards of the given notes (reveal-siblings / select-notes).
    func siblingCards(of noteIDs: [NoteID]) async -> [CardID] {
        await cardsOfNotes(noteIDs)
    }

    // MARK: - Saved searches CRUD (P4)

    /// Returns false when `name` collides and `allowOverwrite` is false.
    @discardableResult
    func saveCurrentQuery(as name: String, allowOverwrite: Bool) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if !allowOverwrite, savedSearches.searches.contains(where: { $0.name == trimmed }) {
            return false
        }
        saveCurrentQuery(as: trimmed)
        return true
    }

    func renameSavedSearch(from oldName: String, to newName: String) -> Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != oldName else { return false }
        guard !savedSearches.searches.contains(where: { $0.name == trimmed }) else { return false }
        savedSearches.rename(from: oldName, to: trimmed)
        if case .saved(let current) = source, current == oldName {
            source = .saved(trimmed)
        }
        collectionStore.invalidateAll(origin: .localUser)
        return true
    }

    func updateSavedSearch(named name: String) {
        let query = buildQuery()
        guard !query.isEmpty else { return }
        savedSearches.save(name: name, query: query)
        collectionStore.invalidateAll(origin: .localUser)
    }

    // MARK: - Default search + current-deck shortcut (P4 search QoL)

    private var defaultSearchKey: String {
        "browse.defaultSearch.\(AccountStore.shared.current.id)"
    }

    var defaultSearch: String {
        UserDefaults.standard.string(forKey: defaultSearchKey) ?? ""
    }

    func setDefaultSearch(_ query: String) {
        UserDefaults.standard.set(query, forKey: defaultSearchKey)
    }

    func applyDefaultSearchIfEmpty() {
        guard searchText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let d = defaultSearch.trimmingCharacters(in: .whitespaces)
        guard !d.isEmpty else { return }
        searchText = d
    }

    /// `deck:current` shortcut — the engine resolves the reviewer's current
    /// deck server-side (`SearchNode(deck: "current")` writes this exact
    /// fragment on desktop too).
    func applyCurrentDeckShortcut() {
        searchText = "deck:current"
    }

    // MARK: - View prefs persistence (P4)

    private var viewPrefsKey: String {
        "browse.viewPrefs.\(AccountStore.shared.current.id)"
    }

    func loadViewPrefs() {
        guard let data = UserDefaults.standard.data(forKey: viewPrefsKey),
              let prefs = try? JSONDecoder().decode(BrowseViewPrefs.self, from: data)
        else { return }
        viewPrefs = prefs
        // Adopt persisted per-mode sort on launch.
        if mode == .notes {
            if let match = SortOrder(rawValue: prefs.notesSortColumn) {
                sortOrder = match
            }
            sortReverseOverride = prefs.notesSortReverse
        } else {
            if let match = SortOrder(rawValue: prefs.cardsSortColumn) {
                sortOrder = match
            }
            sortReverseOverride = prefs.cardsSortReverse
        }
    }

    func persistViewPrefs() {
        var prefs = viewPrefs
        switch mode {
        case .notes:
            prefs.notesSortColumn = sortOrder.rawValue
            prefs.notesSortReverse = effectiveSortReverse
        case .cards:
            prefs.cardsSortColumn = sortOrder.rawValue
            prefs.cardsSortReverse = effectiveSortReverse
        }
        viewPrefs = prefs
        if let data = try? JSONEncoder().encode(prefs) {
            UserDefaults.standard.set(data, forKey: viewPrefsKey)
        }
    }

    // MARK: - Engine columns / rows (P2)

    func loadBrowserColumns() async {
        if let cols = try? await ankiBackend.invoke(.allBrowserColumns()) {
            browserColumns = cols
        }
    }

    func browserRow(for id: Int64) async -> BrowserRowData? {
        if let cached = browserRows[id] { return cached }
        guard let row = try? await ankiBackend.invoke(.browserRowForId(id: id)) else { return nil }
        browserRows[id] = row
        return row
    }

    func setActiveColumns(_ keys: [String]) async {
        try? await ankiBackend.invoke(.setActiveBrowserColumns(keys))
        browserRows.removeAll()
        var prefs = viewPrefs
        switch mode {
        case .notes: prefs.notesColumns = keys
        case .cards: prefs.cardsColumns = keys
        }
        viewPrefs = prefs
        persistViewPrefs()
    }

    // MARK: - Sidebar management (P4)

    func renameSidebarTag(from old: String, to new: String) async {
        let trimmed = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != old else { return }
        await run("rename tag") { try await self.tagClient.renameTag(old, trimmed) }
        allTags = ((try? await tagClient.getAllTags()) ?? []).sorted()
        if let tree = try? await tagClient.tagTree() { tagTree = tree }
    }

    /// Applies a sidebar tag to the current batch selection (card-scope
    /// aware: cards resolve to their notes async).
    func addSidebarTagToSelection(_ tag: String, noteIDs: Set<NoteID>, cardIDs: Set<CardID>) async {
        let notes = await resolveTargetNotes(cardIDs: Array(cardIDs), noteIDs: Array(noteIDs))
        guard !notes.isEmpty else {
            errorMessage = "Select notes or cards first, then apply the tag."
            return
        }
        await run("tag") { try await self.tagClient.addTagToNotes(tag, notes) }
    }

    func removeSidebarTagFromSelection(_ tag: String, noteIDs: Set<NoteID>, cardIDs: Set<CardID>) async {
        let notes = await resolveTargetNotes(cardIDs: Array(cardIDs), noteIDs: Array(noteIDs))
        guard !notes.isEmpty else {
            errorMessage = "Select notes or cards first, then remove the tag."
            return
        }
        await run("untag") { try await self.tagClient.removeTagFromNotes(tag, notes) }
    }

    /// Moves tags under a new parent (`""` = top level). Desktop drag/drop
    /// parity via prompt instead of drag gesture (touch-first).
    func reparentTag(_ tag: String, under newParent: String) async {
        let parent = newParent.trimmingCharacters(in: .whitespacesAndNewlines)
        await run("move tag") { try await self.tagClient.reparentTags([tag], parent) }
        allTags = ((try? await tagClient.getAllTags()) ?? []).sorted()
        if let tree = try? await tagClient.tagTree() { tagTree = tree }
    }

    /// Moves a deck under a new parent by renaming to `<parent>::<leaf>`.
    /// Empty parent moves it to the top level.
    func reparentDeck(id: DeckID, under newParent: String) async {
        guard let deck = availableDecks.first(where: { $0.id == id }) else { return }
        let leaf = BrowseDeckTree.leafName(deck.name)
        let parent = newParent.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = parent.isEmpty ? leaf : parent + "::" + leaf
        guard target != deck.name else { return }
        await renameDeck(id: id, to: target)
    }

    /// Persists a sidebar tag parent's collapsed state engine-side
    /// (`SetTagCollapsed`, the same store desktop reads) and reloads the tree.
    func toggleTagCollapsed(_ path: String) async {
        func find(_ nodes: [TagTreeNodeData]) -> TagTreeNodeData? {
            for node in nodes {
                if node.fullPath == path { return node }
                if let hit = find(node.children) { return hit }
            }
            return nil
        }
        guard let node = find(tagTree?.children ?? []) else { return }
        try? await tagClient.setCollapsed(path, !node.collapsed)
        if let tree = try? await tagClient.tagTree() { tagTree = tree }
    }

    func deleteCollectionTag(_ tag: String) async {
        await run("delete tag") { try await self.tagClient.removeTag(tag) }
        allTags = ((try? await tagClient.getAllTags()) ?? []).sorted()
        if let tree = try? await tagClient.tagTree() { tagTree = tree }
    }

    func renameDeck(id: DeckID, to newName: String) async {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let service = decksService
        do {
            _ = try await backendOffload { try service.renameDeck(id, trimmed) }
        } catch {
            errorMessage = "Couldn't rename deck: \(error.localizedDescription)"
        }
        await loadDecks()
        await refreshAfterMutation()
    }

    @ObservationIgnored @Dependency(\.decksService) private var decksService
    @ObservationIgnored @Dependency(\.notetypesClient) private var notetypesClient

    /// Template/field children per notetype name for the sidebar
    /// (desktop notetype tree parity). Loaded once per session.
    private(set) var notetypeChildren: [String: (templates: [String], fields: [String])] = [:]

    func loadNotetypeChildren() async {
        guard notetypeChildren.isEmpty else { return }
        let client = notetypesClient
        guard let all = try? await client.listAll() else { return }
        for entry in all.prefix(50) {
            guard let nt = try? await client.get(entry.id) else { continue }
            notetypeChildren[nt.name] = (
                templates: nt.templates.map(\.name),
                fields: nt.fields.map(\.name)
            )
        }
    }

    // MARK: - Copy note / export / change notetype / filtered deck (P3)

    /// Prefilled add-note template from an existing note (Create Copy).
    func copyTemplate(of noteID: NoteID) async -> NewNoteTemplate? {
        guard let note = (try? await noteClient.fetch(noteID)) ?? nil else { return nil }
        let fields = note.flds.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
        var template = NewNoteTemplate(notetypeId: note.mid, fields: fields)
        template.tags = note.tags.split(separator: " ").map(String.init)
        return template
    }

    /// Tag every duplicate group (desktop Find Duplicates "Tag Duplicates").
    func tagDuplicateGroups(_ groups: [[NoteID]], tag: String = "duplicate") async {
        for group in groups where !group.isEmpty {
            try? await tagClient.addTagToNotes(tag, group)
        }
        await refreshAfterMutation()
    }

    // MARK: - Due formatting (P1D interim, scheduler-aware)
    //
    // Engine `BrowserRow` cells carry the authoritative due text. This local
    // formatter is the fallback for rows/records rendered without engine
    // columns: it distinguishes new-position vs. learning-epoch vs. review
    // day-index instead of the old coarse `due/86400` arithmetic.

    /// Scheduler-aware due label for a card record. Nil = undue (suspended/
    /// buried) where desktop shows no due date.
    func dueLabel(for card: CardRecord) -> String? {
        // Suspended / buried have no due date.
        if card.queue == -1 || card.queue < -1 { return nil }
        switch card.type {
        case 0:
            // New: due is the queue position.
            return "#\(card.due)"
        case 1, 3:
            // Learning / relearning: due is a unix-epoch second.
            let date = Date(timeIntervalSince1970: TimeInterval(card.due))
            let cal = Calendar.current
            if cal.isDateInToday(date) { return "Today" }
            if cal.isDateInTomorrow(date) { return "Tomorrow" }
            let fmt = DateFormatter()
            fmt.dateStyle = .medium
            fmt.timeStyle = .none
            return fmt.string(from: date)
        default:
            // Review: due is a scheduler day index. Without the collection
            // day-origin we cannot render a calendar date locally, so report
            // the desktop-relative form and let engine rows supply exact dates.
            if card.due <= 0 { return "Today" }
            return "In \(card.due)d"
        }
    }
}

#if DEBUG
extension BrowseModel {
    /// SwiftUI #Preview seeding — bypasses private(set) pipeline state.
    func seedPreview(ids noteIds: [Int64], records: [Int64: NoteRecord]) {
        ids = noteIds
        noteRecords = records
        windowEnd = noteIds.count
    }
}
#endif

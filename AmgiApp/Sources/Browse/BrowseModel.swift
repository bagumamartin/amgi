import AnkiProtoBridge
import AnkiClients
import AnkiKit
import AnkiServices
import Dependencies
import Foundation

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
    enum SortOrder: String, CaseIterable, Identifiable {
        case due = "cardDue"
        case createdDesc = "noteCrt"
        case modifiedDesc = "noteMod"
        case sortFieldAsc = "noteFld"
        case notetypeAsc = "note"
        case tagsAsc = "noteTags"

        var id: String { rawValue }

        var label: String {
            switch self {
            case .due: "Due date"
            case .createdDesc: "Date created"
            case .modifiedDesc: "Date edited"
            case .sortFieldAsc: "Sort field"
            case .notetypeAsc: "Note type"
            case .tagsAsc: "Tags"
            }
        }

        var reverse: Bool {
            switch self {
            case .due: false
            case .createdDesc, .modifiedDesc: true
            case .sortFieldAsc, .notetypeAsc, .tagsAsc: false
            }
        }
    }

    // MARK: View-facing state

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
    var parentDeck: DeckInfo?
    var activeDeck: DeckInfo?
    var activeTag: String?
    var isLoading = false
    var hasMorePages = false
    var notetypeNames: [NotetypeID: String] = [:]
    var mode: Mode = .notes {
        didSet { guard oldValue != mode else { return }; scheduleSearch(immediate: true) }
    }
    var sortOrder: SortOrder = .createdDesc {
        didSet { guard oldValue != sortOrder else { return }; scheduleSearch(immediate: true) }
    }

    /// Undo/redo chrome state ("Undo Delete Notes"), refreshed after ops.
    private(set) var undoStatus: UndoStatusInfo?
    /// Select-mode plumbing stays view-owned via BrowseSelectionState.

    // Phase 3+ surface
    let savedSearches = SavedSearchStore()
    var searchError: String?
    /// Recent queries for search suggestions (max 30, per profile).
    private(set) var recentQueries: [String] = []
    /// Semantic fallback banner text; nil hides it.
    private(set) var semanticNotice: String?
    /// Note currently driving the inspector detail pane.
    var focusedNoteID: Int64?

    private static let historyKey = "browse.searchHistory"
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

    var topLevelDecks: [DeckInfo] {
        allDecks.filter { !$0.name.contains("::") }
    }

    /// Direct children of the parent deck (shown as the second filter row).
    var childDecks: [DeckInfo] {
        guard let parent = parentDeck else { return [] }
        let prefix = parent.name + "::"
        return allDecks.filter { deck in
            guard deck.name.hasPrefix(prefix) else { return false }
            let remainder = deck.name.dropFirst(prefix.count)
            return !remainder.contains("::")
        }
    }

    func note(at id: Int64) -> NoteRecord? { noteRecords[id] }
    func card(at id: Int64) -> CardRecord? { cardRecords[id] }

    // MARK: - Search pipeline

    /// Debounced entry point for text-field edits.
    func scheduleSearch(immediate: Bool = false) {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            if !immediate {
                try? await Task.sleep(for: .milliseconds(250))
                if Task.isCancelled { return }
            }
            // Commit boundary: only queries that actually execute get
            // remembered (typing never spams history).
            if let self {
                let candidate = self.buildQuery().trimmingCharacters(in: .whitespaces)
                guard !candidate.isEmpty, candidate != self.lastCommittedQuery else { return }
                self.lastCommittedQuery = candidate
                self.recordHistory(candidate)
            }
            await self?.performSearch()
        }
    }

    func performSearch() async {
        isLoading = true
        defer { isLoading = false }
        let query = buildQuery()
        let order = order()
        do {
            let newIDs: [Int64]
            switch mode {
            case .notes:
                newIDs = try await noteClient.searchIds(query, order).map(\.rawValue)
            case .cards:
                newIDs = try await cardClient.searchIds(query, order).map(\.rawValue)
            }
            // Records for ids that remain in results stay valid; drop the
            // rest so stale rows can't outlive the query.
            noteRecords = noteRecords.filter { newIDs.contains($0.key) }
            cardRecords = cardRecords.filter { newIDs.contains($0.key) }
            ids = newIDs
            windowEnd = min(ids.count, max(windowSize, windowEnd))
            hasMorePages = windowEnd < ids.count
            await hydrateWindow()
        } catch is CancellationError {
        } catch {
            ids = []
            noteRecords.removeAll()
            cardRecords.removeAll()
            windowEnd = 0
            hasMorePages = false
        }
    }

    private func order() -> SearchOrder {
        SearchOrder(.builtin(column: sortOrder.rawValue, reverse: sortOrder.reverse))
    }

    func loadDecks() async {
        allDecks = (try? await deckClient.fetchAll()) ?? []
    }

    func loadInitial() async {
        await loadDecks()
        allTags = ((try? await tagClient.getAllTags()) ?? []).sorted()
        if let pairs = try? notetypesService.getNotetypeNames() {
            notetypeNames = Dictionary(uniqueKeysWithValues: pairs.map { ($0.id, $0.name) })
        }
        await performSearch()
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
            let missing = Array(ids.prefix(windowEnd).filter { noteRecords[$0] == nil }
                .prefix(hydrateChunkSize))
            await withTaskGroup(of: Void.self) { group in
                for nidRaw in missing {
                    let nid = NoteID(nidRaw)
                    group.addTask { [noteClient] in
                        if let note = try? await noteClient.fetch(nid) ?? nil {
                            await MainActor.run { self.noteRecords[nidRaw] = note }
                        }
                    }
                }
            }
        case .cards:
            let missing = Array(ids.prefix(windowEnd).filter { cardRecords[$0] == nil }
                .prefix(hydrateChunkSize))
            await withTaskGroup(of: Void.self) { group in
                for cidRaw in missing {
                    let cid = CardID(cidRaw)
                    group.addTask { [cardClient] in
                        if let card = try? await cardClient.getCard(cid) {
                            await MainActor.run { self.cardRecords[cidRaw] = card }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Mutations (batch, undo-friendly)

    func delete(_ id: NoteID) async {
        try? await noteClient.deleteBatch([id])
        await refreshAfterMutation()
    }

    func suspendSelected(_ noteIDs: Set<NoteID>) async {
        try? await cardClient.suspendCards([], Array(noteIDs))
        await refreshAfterMutation()
    }

    func unSuspendSelected(_ noteIDs: Set<NoteID>, cardIDs: [CardID]) async {
        try? await cardClient.restoreBuriedAndSuspended(cardIDs)
        await refreshAfterMutation()
    }

    func burySelected(_ noteIDs: Set<NoteID>) async {
        try? await cardClient.buryUserCards([], Array(noteIDs))
        await refreshAfterMutation()
    }

    func flagSelected(_ noteIDs: Set<NoteID>, value: UInt32) async {
        let cardIds = await cardsOfNotes(Array(noteIDs))
        for cid in cardIds {
            try? await cardClient.flag(cid, value)
        }
        await refreshAfterMutation()
    }

    /// Cards of selected notes — ONE engine search instead of N fetches.
    private func cardsOfNotes(_ noteIds: [NoteID]) async -> [CardID] {
        guard !noteIds.isEmpty else { return [] }
        let query = noteIds.map { "nid:\($0.rawValue)" }.joined(separator: " OR ")
        return (try? await cardClient.searchIds(query, nil)) ?? []
    }

    func deleteSelected(_ noteIDs: Set<NoteID>) async {
        // One removeNotes transaction → one engine undo entry (D6).
        try? await noteClient.deleteBatch(Array(noteIDs))
        await refreshAfterMutation()
    }

    func changeDeckSelected(_ cardIDs: [CardID], deckId: DeckID) async {
        _ = try? await cardClient.changeDeck(cardIDs, deckId)
        await refreshAfterMutation()
    }

    func addTag(_ tag: String, to noteIDs: Set<NoteID>) async {
        try? await tagClient.addTagToNotes(tag, Array(noteIDs))
        await refreshAfterMutation()
    }

    func removeTag(_ tag: String, from noteIDs: Set<NoteID>) async {
        try? await tagClient.removeTagFromNotes(tag, Array(noteIDs))
        await refreshAfterMutation()
    }

    func gradeNowSelected(_ cardIDs: [CardID], rating: Rating) async {
        try? await cardClient.gradeNow(cardIDs, rating)
        await refreshAfterMutation()
    }

    func repositionSelected(_ cardIDs: [CardID], start: UInt32, step: UInt32) async {
        _ = try? await cardClient.repositionCards(cardIDs, start, step, false, false)
        await refreshAfterMutation()
    }

    // Undo / redo ----------------------------------------------------------

    func refreshUndoStatus() async {
        undoStatus = try? await cardClient.undoStatus()
    }

    func undoLast() async {
        try? await cardClient.undoLast()
        await refreshAfterMutation()
    }

    func redoLast() async {
        try? await cardClient.redoLast()
        await refreshAfterMutation()
    }

    /// After any engine op the CollectionStore generation bumps itself via
    /// OpChanges observation (same rails as deck icons); we re-run the
    /// search against fresh data and refresh undo chrome here.
    func refreshAfterMutation() async {
        collectionStore.invalidateAll(origin: .localUser)
        await performSearch()
        await refreshUndoStatus()
    }


    // MARK: - Filter rail application (spec §5.5)

    enum RailComposition {
        case replace            // plain tap
        case andWithExisting    // ⌃-click analog
        case orWithExisting     // ⇧-click analog
        case negateAndAdd       // ⌥-click analog
    }

    /// Applies a rail node to the query with desktop's composition
    /// semantics, always canonicalized by the engine so the string stays
    /// valid grammar even when hand-built fragments nest oddly.
    func applyFilterNode(_ node: FilterNode, composition: RailComposition) async {
        defer { scheduleSearch(immediate: true) }
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
                composeViaEngine(additional: node.fragment, joiner: .and)
            }
        case .orWithExisting:
            if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                searchText = node.fragment
            } else {
                composeViaEngine(additional: node.fragment, joiner: .or)
            }
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
    private func composeViaEngine(additional: String, joiner: SearchJoiner) {
        let existing = searchText
        Task { [weak self] in
            guard let self else { return }
            if let composed = try? await noteClient.composeQuery(
                existing: existing, additional: additional, joiner: joiner
            ) {
                self.searchText = composed
                self.scheduleSearch(immediate: true)
            } else {
                // Engine rejected the pair — fall back to textual AND which
                // is definitionally correct.
                self.searchText = existing + " " + additional
                self.scheduleSearch(immediate: true)
            }
        }
    }

    func validateCurrentQuery() {
        let candidate = buildQuery()
        guard !candidate.isEmpty else { searchError = nil; return }
        Task { [weak self] in
            _ = try? await self?.noteClient.validateQuery(candidate)
            // Errors surface through performSearch's failure branch today;
            // dedicated inline error UI lands with engine-row columns.
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
        guard mode == .notes, !trimmed.isEmpty else { return }
        guard let ids = await SemanticNoteIndex.shared.search(trimmed, topK: 50) else {
            semanticNotice = "Semantic index still building…"
            return
        }
        guard !ids.isEmpty else {
            semanticNotice = "No semantically similar notes found."
            return
        }
        noteRecords.removeAll()
        cardRecords.removeAll()
        windowEnd = min(ids.count, windowSize)
        hasMorePages = false
        semanticNotice = "Meaning-based matches for “\(trimmed)”"
        await hydrateWindow()
    }

    func clearSemanticNotice() { semanticNotice = nil }

    // MARK: - Power-tool plumbing (selection-scope resolution)

    /// Card IDs for the given notes via one nid:(OR) search.
    func resolveCardIds(for noteIds: [NoteID]) async -> [CardID] {
        guard !noteIds.isEmpty else { return [] }
        let query = noteIds.map { "nid:\($0.rawValue)" }.joined(separator: " OR ")
        return (try? await cardClient.searchIds(query, nil)) ?? []
    }

    func changeDeckSelected(_ noteIDs: Set<NoteID>, deckId: DeckID) async {
        let cardIds = await resolveCardIds(for: Array(noteIDs))
        _ = try? await cardClient.changeDeck(cardIds, deckId)
        await refreshAfterMutation()
    }

    func setDueDateSelected(_ noteIDs: Set<NoteID>, expression: String) async {
        let cardIds = await resolveCardIds(for: Array(noteIDs))
        try? await cardClient.setDueDate(cardIds, expression)
        await refreshAfterMutation()
    }

    func gradeNowSelectedNotes(_ noteIDs: Set<NoteID>, rating: Rating) async {
        let cardIds = await resolveCardIds(for: Array(noteIDs))
        try? await cardClient.gradeNow(cardIds, rating)
        await refreshAfterMutation()
    }

    func repositionSelectedNotes(_ noteIDs: Set<NoteID>, start: UInt32, step: UInt32, randomize: Bool, shift: Bool) async {
        let cardIds = await resolveCardIds(for: Array(noteIDs))
        _ = try? await cardClient.repositionCards(cardIds, start, step, randomize, shift)
        await refreshAfterMutation()
    }

    func toggleMarkSelected(_ noteIDs: Set<NoteID>) async {
        let anyMarked = noteIDs.contains { id in
            noteRecords[id.rawValue]?.tags.split(separator: " ")
                .contains { $0.caseInsensitiveCompare("marked") == .orderedSame } == true
        }
        if anyMarked {
            try? await tagClient.removeTagFromNotes("marked", Array(noteIDs))
        } else {
            try? await tagClient.addTagToNotes("marked", Array(noteIDs))
        }
        await refreshAfterMutation()
    }

    /// Find & Replace scoped to selection when present, else to current results.
    func findAndReplace(search: String, replacement: String, regex: Bool, matchCase: Bool, fieldName: String?, scopeNoteIds: [NoteID]?) async -> Int {
        let targets: [NoteID]
        if let scopeNoteIds, !scopeNoteIds.isEmpty {
            targets = scopeNoteIds
        } else {
            targets = mode == .notes
                ? ids.prefix(loadedCount).map { NoteID($0) }
                : []
        }
        guard !targets.isEmpty else { return 0 }
        let count = (try? await noteClient.findAndReplace(
            noteIds: targets, search: search, replacement: replacement,
            regex: regex, matchCase: matchCase, fieldName: fieldName)) ?? 0
        await refreshAfterMutation()
        return count
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
        let prefixes = ["deck:", "tag:", "is:", "due:", "added:", "edited:",
                        "rated:", "prop:", "nid:", "note:", "flag:", "introduced:"]
        for word in searchText.split(separator: " ") {
            let lowered = word.lowercased()
            if prefixes.contains(where: { lowered.hasPrefix($0) }) { return false }
        }
        return true
    }

    // MARK: - Query assembly (phase 3 replaces chips with tokens)

    func buildQuery() -> String {
        var parts: [String] = []
        if let deck = activeDeck {
            parts.append("deck:\"\(deck.name)\"")
        }
        if let tag = activeTag {
            parts.append("tag:\"\(tag)\"")
        }
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            parts.append(trimmed)
        }
        return parts.joined(separator: " ")
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


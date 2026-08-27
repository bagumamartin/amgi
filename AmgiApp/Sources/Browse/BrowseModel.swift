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

package import SwiftUI
import AmgiAppShared
import AmgiUI
package import AnkiKit
import AnkiClients
import AnkiServices
import Dependencies
import AmgiTheme

/// Browse container. One three-column `NavigationSplitView` on every
/// idiom — sources, list, detail. Compact width collapses that split into
/// a stack (Mail); regular width shows the columns side by side.
///
/// It used to be mounted inside another `NavigationSplitView` (the root
/// sidebar) with a `NavigationStack` around each of its own columns. Four
/// nested columns in one window collapsed the list to a sliver and scattered
/// toolbar items above the wrong panes, so on macOS / iPad Browse now takes
/// the window over and `exit` is the way back. Settings pushes on the
/// list column so the source sidebar stays; wrapping this split in a
/// `NavigationStack` is what took the sidebar away.
///
/// Rendering is delegated to `BrowseSourceColumn` / `BrowseListColumn` /
/// `BrowseDetailTabs`; the model owns all I/O.
package struct BrowseView: View {
    @State private var model: BrowseModel
    @State private var selectionState = BrowseSelectionState()
    @State private var showAddNote = false
    @State private var showDrafts = false
    @State private var showAddImageOcclusion = false
    @State private var showTagSheet = false
    @State private var showTagsManager = false
    @State private var showDeleteConfirm = false
    @State private var pendingSwipeDelete: NoteRecord?

    // Power tools + batch destinations
    enum Sheet: Int, Hashable {
        case findDuplicates, findReplace, changeDeck, setDueDate, reposition
        case removeTags, forget, copyNote, export, changeNotetype, filteredDeck
        case columns, savedSearchManage, previewNav

        var id: Int { rawValue }
    }
    @State private var activeSheet: Sheet?
    @State private var notetypeFieldNames: [String] = []
    @State private var showSaveSearchPrompt = false
    @State private var saveSearchName = ""
    @State private var saveOverwritePending = false
    @State private var renameSearchFrom: String?
    @State private var renameSearchTo = ""
    #if os(iOS)
    @State private var preferredColumn: NavigationSplitViewColumn = .sidebar
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    #endif
    /// Settings from the sidebar footer when the source list is showing,
    /// or the combined list-column profile menu when that sidebar is hidden.
    @State private var accountDestination: AccountMenuDestination?
    @State private var batchScopeOverride: BatchScope?

    private struct BatchScope {
        var notes: Set<NoteID>
        var cards: Set<CardID>
    }

    @Dependency(\.notetypesService) private var notetypesService
    @Dependency(\.collectionStore) private var store
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss

    /// Present only on macOS, where Browse replaces the root sidebar.
    private let exit: BrowseExit?

    package init(exit: BrowseExit? = nil) {
        self.init(model: BrowseModel(), exit: exit)
    }

    /// Modal entry from deck detail. The deck source is installed before the
    /// first search, so the sheet never flashes collection-wide results.
    package init(deck: DeckInfo) {
        self.init(model: BrowseModel(rootDeck: deck), exit: nil)
    }

    init(model: BrowseModel, exit: BrowseExit? = nil) {
        _model = State(initialValue: model)
        self.exit = exit
        #if os(iOS)
        _preferredColumn = State(initialValue: model.rootDeck != nil ? .content : .sidebar)
        #endif
    }

    package var body: some View {
        dialogChrome
            .task { await appear() }
            // Identity includes text, source, mode, and sort. SwiftUI cancels
            // the previous run on change *and* when leaving Search, so a
            // stale result cannot land after the user has typed further or
            // switched tabs.
            .task(id: model.searchIdentity) {
                await model.performSearch(debounce: .milliseconds(250))
            }
            .task(id: store.generation) {
                await model.refreshUndoStatus()
            }
            #if os(iOS)
            // Select-mode batch actions live on the bottom bar. Hide the tab
            // bar so it cannot cover them (Mail hides its tab bar in Edit).
            .toolbarVisibility(
                selectionState.isSelectMode ? .hidden : .automatic,
                for: .tabBar
            )
            #endif
    }

    @ViewBuilder
    private var layout: some View {
        splitColumns
    }

    // MARK: - Split

    /// Compact iPhone shows one column at a time. Search attached to the
    /// split lands on the list/detail column, so the source tree has no
    /// field. Put it on the sidebar and list columns instead. Regular
    /// width keeps one field on the split (Mail).
    private var usesColumnSearch: Bool {
        #if os(iOS)
        horizontalSizeClass != .regular
        #else
        false
        #endif
    }

    /// iPad three-column: the source sidebar is gone, so the combined
    /// profile + Settings control moves to the notes column — same idea as
    /// the adaptable tab bar collapsing.
    private var isBrowseSidebarHidden: Bool {
        #if os(iOS)
        columnVisibility == .doubleColumn || columnVisibility == .detailOnly
        #else
        false
        #endif
    }

    @ViewBuilder
    private var splitColumns: some View {
        if usesColumnSearch {
            splitView.navigationSplitViewStyle(.balanced)
        } else {
            #if os(iOS)
            ZStack {
                if accountDestination == nil {
                    withBrowseSearch(splitView.navigationSplitViewStyle(.balanced))
                } else {
                    // Same three-column split as browse — swapping to a
                    // two-column split treats `.doubleColumn` as "show the
                    // sidebar" and forces it open.
                    splitView.navigationSplitViewStyle(.balanced)
                }
                if accountDestination != nil, isBrowseSidebarHidden {
                    NavigationStack {
                        BrowseAccountDestination(destination: $accountDestination)
                    }
                    .amgiScreenCanvas()
                }
            }
            #else
            withBrowseSearch(splitView.navigationSplitViewStyle(.balanced))
            #endif
        }
    }

    @ViewBuilder
    private var splitView: some View {
        #if os(iOS)
        NavigationSplitView(
            columnVisibility: $columnVisibility,
            preferredCompactColumn: $preferredColumn
        ) {
            sidebarPane
        } content: {
            if accountDestination != nil, !isBrowseSidebarHidden {
                NavigationStack {
                    BrowseAccountDestination(destination: $accountDestination)
                }
            } else {
                listPane
            }
        } detail: {
            if accountDestination == nil {
                detailPane
            }
        }
        #else
        NavigationSplitView {
            sidebarPane
        } content: {
            listPane
        } detail: {
            detailPane
        }
        #endif
    }

    @ViewBuilder
    private var sidebarPane: some View {
        let column = BrowseSourceColumn(
            model: model,
            exit: exit,
            selection: selectionState,
            onSelectSource: {
                #if os(iOS)
                preferredColumn = .content
                #endif
            },
            onPresentSheet: { sheet, notes, cards in
                batchScopeOverride = BatchScope(notes: notes, cards: cards)
                activeSheet = sheet
            },
            onPresentTagSheet: { notes, cards in
                batchScopeOverride = BatchScope(notes: notes, cards: cards)
                showTagSheet = true
            },
            collectionGeneration: store.generation
        )
        .appSidebarWidth()
        .navigationTitle("Browse")
        #if os(iOS)
        .toolbarRole(usesColumnSearch ? .automatic : .editor)
        #endif
        .toolbar { sidebarToolbar }
        #if os(macOS)
        column.accountSidebarFooter(open: $accountDestination)
        #else
        if usesColumnSearch {
            withBrowseSearch(column.accountMenu())
        } else if isBrowseSidebarHidden {
            column
        } else {
            column.accountSidebarFooter(open: $accountDestination)
        }
        #endif
    }

    @ViewBuilder
    private var listPane: some View {
        let pane = BrowseListColumn(
            model: model,
            selectionState: $selectionState,
            onSwipeDelete: { pendingSwipeDelete = $0 },
            onOpenDetail: {
                #if os(iOS)
                preferredColumn = .detail
                #endif
            }
        )
        .navigationSplitViewColumnWidth(min: 300, ideal: 400)
        .navigationTitle(sourceTitle)
        .navigationBarTitleDisplayMode(.inline)
        #if os(iOS)
        .toolbarRole(.editor)
        .navigationBarBackButtonHidden(selectionState.isSelectMode)
        .toolbarVisibility(
            selectionState.isSelectMode ? .hidden : .automatic,
            for: .tabBar
        )
        .toolbarVisibility(
            selectionState.isSelectMode ? .visible : .automatic,
            for: .bottomBar
        )
        #endif
        .toolbar { listToolbarContent }
        .dropDestination(for: String.self) { items, _ in
            dropTags(items)
        }
        if usesColumnSearch {
            withBrowseSearch(pane)
        } else {
            #if os(iOS)
            if isBrowseSidebarHidden, !selectionState.isSelectMode {
                pane.accountMenuControl(
                    open: $accountDestination,
                    showsName: false
                )
            } else {
                pane
            }
            #else
            pane
            #endif
        }
    }

    private var previewNav: BrowsePreviewNav? {
        let ids = Array(model.ids.prefix(max(model.loadedCount, model.windowEnd, 1)))
        guard !ids.isEmpty else { return nil }
        let current: Int64? = model.mode == .cards
            ? model.focusedCardID?.rawValue
            : model.focusedNoteID
        return BrowsePreviewNav(ids: ids, currentID: current) { next in
            if model.mode == .cards {
                await model.focus(cardID: next)
            } else {
                await model.focus(noteID: next)
            }
        }
    }

    private var detailPane: some View {
        Group {
            if model.focusedNote != nil || model.focusedCard != nil {
                BrowseDetailTabs(
                    note: model.focusedNote,
                    notetypeName: model.focusedNote.flatMap { model.notetypeNames[$0.mid] },
                    infoCard: model.focusedCard,
                    firstCardID: model.focusedCardID,
                    deckID: model.activeDeck?.id,
                    onSaved: { Task { await model.performSearch() } },
                    onClose: {
                        model.clearFocus()
                        #if os(iOS)
                        preferredColumn = .content
                        #endif
                    },
                    previewNav: previewNav
                )
                .id(model.focusedNote?.id ?? NoteID(0))
            } else {
                ContentUnavailableView(
                    "No Selection",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("Select a \(rowNoun) to view its details.")
                )
                .navigationTitle("Details")
                #if os(iOS)
                .toolbarRole(.editor)
                #endif
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Titles & search chrome

    private var rowNoun: String {
        model.mode == .notes ? "note" : "card"
    }

    /// Names what the list is scoped to, mirroring the sidebar selection.
    private var sourceTitle: String {
        model.title(for: model.source)
    }

    private var batchNotes: Set<NoteID> {
        batchScopeOverride?.notes ?? selectionState.selectedNoteIDs
    }

    private var batchCards: Set<CardID> {
        batchScopeOverride?.cards ?? selectionState.selectedCardIDs
    }

    private func dropTags(_ items: [String]) -> Bool {
        let tags = items.compactMap { item -> String? in
            guard item.hasPrefix(BrowseSource.tagDragPrefix) else { return nil }
            return String(item.dropFirst(BrowseSource.tagDragPrefix.count))
        }
        guard !tags.isEmpty else { return false }

        var notes = selectionState.selectedNoteIDs
        var cards = selectionState.selectedCardIDs
        if notes.isEmpty && cards.isEmpty {
            // Empty Select-mode is a no-op. A macOS peek (single click)
            // does not populate the batch sets, so fall back to the focused
            // row — that's the note the inspector is showing.
            if selectionState.isSelectMode { return false }
            if let nid = model.focusedNote?.id {
                notes = [nid]
            } else if let cid = model.focusedCardID {
                cards = [cid]
            } else {
                return false
            }
        }
        Task {
            for tag in tags {
                await model.addSidebarTagToSelection(tag, noteIDs: notes, cardIDs: cards)
            }
        }
        return true
    }

    private var searchPlacement: SearchFieldPlacement {
        #if os(macOS)
        return .toolbar
        #else
        return horizontalSizeClass == .compact
            ? .navigationBarDrawer(displayMode: .always)
            : .toolbar
        #endif
    }

    private var searchPrompt: String {
        switch model.source {
        case .allDecks:
            usesColumnSearch ? "Search decks and notes…" : "Search all \(rowNoun)s…"
        default:
            "Search in \(sourceTitle)…"
        }
    }

    private func withBrowseSearch<V: View>(_ view: V) -> some View {
        view
            .searchable(
                text: $model.searchText,
                placement: searchPlacement,
                prompt: searchPrompt
            )
            .onSubmit(of: .search) { model.commitSearchHistory() }
            .searchSuggestions {
                if canSuggestSemanticSearch {
                    if SemanticNoteIndex.shared.isReady {
                        Button {
                            model.commitSearchHistory()
                            Task { await model.runSemanticFallback() }
                        } label: {
                            Label(
                                "Search by meaning for “\(semanticSuggestionText)”",
                                systemImage: "sparkles"
                            )
                        }
                    } else if SemanticNoteIndex.shared.progressDescription != nil {
                        Label("Preparing meaning-based search…", systemImage: "sparkles")
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(model.recentQueries.prefix(8), id: \.self) { query in
                    Button {
                        model.searchText = query
                        model.commitSearchHistory()
                    } label: {
                        Label(query, systemImage: "clock.arrow.circlepath")
                    }
                    .searchCompletion(query)
                }
            }
    }

    private var semanticSuggestionText: String {
        model.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSuggestSemanticSearch: Bool {
        model.rootDeck == nil
            && model.mode == .notes
            && !semanticSuggestionText.isEmpty
            && model.searchTextIsPlainFreeText
    }

    // MARK: - Loading

    private func appear() async {
        await model.loadDecks()
        // Drill-in from a deck detail screen or an amgi://browse deep link.
        if model.rootDeck == nil, let seed = BrowseLauncher.shared.consume(), !seed.isEmpty {
            if seed.hasPrefix("deck:"), let name = seed.dropFirst(5).trimmedQuoted,
               let deck = model.allDecks.first(where: { $0.name == name }) {
                model.source = .deck(deck.id)
            } else {
                model.searchText = seed
            }
        }
        await model.loadInitial()
        await model.refreshUndoStatus()
        await refreshNotetypeFields()
        #if os(iOS)
        // Compact NavigationSplitView follows List selection into the notes
        // column. Keep the source tree first unless this session is already
        // scoped (deck-detail sheet, deep link).
        if model.rootDeck != nil || model.source != .allDecks {
            preferredColumn = .content
        } else {
            preferredColumn = .sidebar
        }
        #endif
    }

    /// Union of field names across the effective scope (desktop Find &
    /// Replace / Find Duplicates picker source) — never just the first
    /// hydrated note's fields.
    private func refreshNotetypeFields() async {
        let names = await model.fieldNamesForScope(
            noteIDs: Array(selectionState.selectedNoteIDs),
            cardIDs: Array(selectionState.selectedCardIDs)
        )
        notetypeFieldNames = names
    }

    // MARK: - Dialogs & sheets
    //
    // Layered into small computed views on purpose: one chained expression
    // blows past the Swift type-checker's time budget. These wrap `layout`
    // so both compact (collapsed split) and regular (side-by-side) raise
    // the same sheets.

    private var dialogChrome: some View {
        sheetChrome
            .confirmationDialog(
                "Delete this note?",
                isPresented: Binding(
                    get: { pendingSwipeDelete != nil },
                    set: { if !$0 { pendingSwipeDelete = nil } }
                ),
                presenting: pendingSwipeDelete
            ) { note in
                Button("Delete", role: .destructive) {
                    Task {
                        await model.delete(note.id)
                        pendingSwipeDelete = nil
                    }
                }
                Button("Cancel", role: .cancel) {
                    pendingSwipeDelete = nil
                }
            } message: { _ in
                Text("You can undo this from More.")
            }
            .confirmationDialog(
                "Delete \(selectionState.count) note\(selectionState.count == 1 ? "" : "s")?",
                isPresented: $showDeleteConfirm
            ) {
                Button("Delete", role: .destructive) {
                    deleteSelected()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You can undo this from More.")
            }
            .alert("Save current search", isPresented: $showSaveSearchPrompt) {
                TextField("Name", text: $saveSearchName)
                Button("Save") {
                    let name = saveSearchName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty,
                       model.savedSearches.searches.contains(where: { $0.name == name }) {
                        // Collision: confirm overwrite explicitly (desktop parity).
                        saveOverwritePending = true
                    } else {
                        model.saveCurrentQuery(as: name)
                        saveSearchName = ""
                    }
                }
                Button("Cancel", role: .cancel) { saveSearchName = "" }
            } message: {
                Text("Saved searches sync to every device via your collection config — desktop Anki sees them too.")
            }
            .confirmationDialog(
                "“\(saveSearchName)” already exists. Overwrite it?",
                isPresented: $saveOverwritePending,
                titleVisibility: .visible
            ) {
                Button("Overwrite", role: .destructive) {
                    model.saveCurrentQuery(as: saveSearchName)
                    saveSearchName = ""
                    saveOverwritePending = false
                }
                Button("Cancel", role: .cancel) { saveOverwritePending = false }
            }
            .alert(
                "Couldn't finish that",
                isPresented: Binding(
                    get: { model.errorMessage != nil },
                    set: { if !$0 { model.errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { model.errorMessage = nil }
            } message: {
                Text(model.errorMessage ?? "")
            }
    }

    private var sheetChrome: some View {
        layout
        .sheet(isPresented: $showAddNote) {
            AddNoteView {
                Task { await model.performSearch() }
            }
        }
        .sheet(isPresented: $showDrafts) {
            NoteDraftsView(deckIDs: model.activeDeck.map { [$0.id.rawValue] })
        }
        .sheet(isPresented: $showAddImageOcclusion) {
            AddImageOcclusionNoteView { Task { await model.performSearch() } }
        }
        .sheet(isPresented: $showTagSheet) {
            BatchTagSheet(
                noteIDs: model.cachedNotesForSelection(
                    noteIDs: batchNotes,
                    cardIDs: batchCards
                ),
                cardIDs: batchCards,
                browseModel: model
            ) {
                Task {
                    if batchScopeOverride == nil {
                        selectionState.exitSelectMode()
                    }
                    batchScopeOverride = nil
                    await model.performSearch()
                }
            }
        }
        .sheet(isPresented: $showTagsManager) {
            NavigationStack {
                TagsView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showTagsManager = false }
                        }
                    }
            }
        }
        .sheet(item: Binding<Sheet?>(
            get: { activeSheet },
            set: { activeSheet = $0 }
        )) { sheet in
            sheetBody(sheet)
        }
    }

    @ViewBuilder
    private func sheetBody(_ sheet: Sheet) -> some View {
        switch sheet {
        case .findDuplicates:
            FindDuplicatesView(
                notetypeFields: notetypeFieldNames,
                runExactScan: { field, text in
                    await model.exactDuplicateGroups(field: field, searchText: text)
                },
                runNearScan: {
                    model.nearDuplicateGroupsInScope()
                },
                openGroup: { ids in openDuplicateGroup(ids.map { NoteID($0) }) },
                onTagDuplicates: { noteIDs in
                    guard !noteIDs.isEmpty else { return }
                    await model.tagDuplicateGroups([noteIDs], tag: "duplicate")
                }
            )
        case .findReplace:
            FindReplaceSheet(
                fieldNames: notetypeFieldNames,
                selectionCount: batchNotes.count + (batchNotes.isEmpty ? batchCards.count : 0),
                resultCount: model.ids.count,
                onApply: { search, replacement, regex, matchCase, fieldName, tagsTarget, selectedOnly in
                    await model.findAndReplace(
                        search: search, replacement: replacement, regex: regex,
                        matchCase: matchCase, fieldName: fieldName, tagsTarget: tagsTarget,
                        scopeNoteIds: Array(batchNotes),
                        scopeCardIds: Array(batchCards),
                        selectedScopeOnly: selectedOnly
                    )
                }
            )
        case .changeDeck:
            ChangeDeckSheet(decks: model.allDecks) { deckId in
                let (notes, cards) = consumeBatchScope()
                Task { await model.changeDeckSelected(notes, cardIDs: Array(cards), deckId: deckId) }
            }
        case .setDueDate:
            SetDueDateSheet(initialExpression: model.lastSetDueExpression) { expression in
                let (notes, cards) = consumeBatchScope()
                Task { await model.setDueDateSelected(notes, cardIDs: Array(cards), expression: expression) }
            }
        case .reposition:
            RepositionSheet { start, step, randomize, shift in
                let (notes, cards) = consumeBatchScope()
                Task {
                    await model.repositionSelectedNotes(
                        notes, cardIDs: Array(cards),
                        start: start, step: step, randomize: randomize, shift: shift
                    )
                }
            }
        case .removeTags:
            RemoveTagsSheet(allTags: model.allTags) { tag in
                let (notes, cards) = consumeBatchScope()
                let resolved = await model.resolveTargetNotes(
                    cardIDs: Array(cards),
                    noteIDs: Array(notes)
                )
                Task { await model.removeTag(tag, from: Set(resolved)) }
            }
        case .forget:
            ForgetSheet { restorePosition, resetCounts in
                let (notes, cards) = consumeBatchScope()
                Task {
                    await model.forgetSelected(
                        notes, cardIDs: Array(cards),
                        restorePosition: restorePosition, resetCounts: resetCounts
                    )
                }
            }
        case .copyNote:
            CopyNoteSheet(
                noteIDs: Array(batchNotes),
                cardIDs: Array(batchCards),
                model: model
            )
        case .export:
            BrowseExportSheet(
                noteIDs: Array(batchNotes),
                cardIDs: Array(batchCards),
                model: model
            )
        case .changeNotetype:
            ChangeNotetypeSheet(
                noteIDs: Array(batchNotes),
                cardIDs: Array(batchCards),
                model: model
            )
        case .filteredDeck:
            FilteredDeckSheet(query: model.buildQuery())
        case .columns:
            BrowserColumnsSheet(model: model)
        case .savedSearchManage:
            SavedSearchManageSheet(model: model)
        case .previewNav:
            EmptyView()
        }
    }

    private func openDuplicateGroup(_ noteIds: [NoteID]) {
        // Comma-separated `nid:` per the bundled parser (`check_id_list`:
        // digits and commas only — never `nid:(1 2)`).
        let fragment = BrowseSearchGrammar.noteIDs(noteIds) ?? ""
        model.searchText = fragment
        activeSheet = nil
    }

    // MARK: - Toolbars (Apple Mail Parity)

    @ToolbarContentBuilder
    private var sidebarToolbar: some ToolbarContent {
        if model.rootDeck != nil {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            SyncToolbarButton()
            Menu {
                Button {
                    showTagsManager = true
                } label: {
                    Label("Manage Tags…", systemImage: "tag")
                }
                Button {
                    activeSheet = .savedSearchManage
                } label: {
                    Label("Manage Saved Searches…", systemImage: "heart.text.square")
                }
                Button {
                    activeSheet = .filteredDeck
                } label: {
                    Label("Create Filtered Deck…", systemImage: "square.stack.3d.down.right")
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .accessibilityLabel("Browse sources")
        }
    }

    @ToolbarContentBuilder
    private var listToolbarContent: some ToolbarContent {
        #if os(iOS)
        if selectionState.isSelectMode {
            selectModeNavigationItems
        } else {
            listDefaultTrailingItems
        }
        #else
        listDefaultTrailingItems
        #endif
        if selectionState.showsBatchActions {
            selectionToolbar
        }
    }

    #if os(iOS)
    @ToolbarContentBuilder
    private var selectModeNavigationItems: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button(allResultsSelected ? "Deselect All" : "Select All") {
                toggleSelectAllResults()
            }
            .disabled(model.ids.isEmpty)
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("Done") {
                selectionState.exitSelectMode()
            }
            .fontWeight(.semibold)
            .tint(palette.accent)
        }
    }
    #endif

    @ToolbarContentBuilder
    private var listDefaultTrailingItems: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("Add Note") { showAddNote = true }
                Button("Add Image Occlusion") { showAddImageOcclusion = true }
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("Add")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Section {
                    Button {
                        Task { await model.undoLast() }
                    } label: {
                        Label(model.undoMenuTitle, systemImage: "arrow.uturn.backward")
                    }
                    .disabled(!model.canUndo)
                    .keyboardShortcut("z", modifiers: .command)
                    Button {
                        Task { await model.redoLast() }
                    } label: {
                        Label(model.redoMenuTitle, systemImage: "arrow.uturn.forward")
                    }
                    .disabled(!model.canRedo)
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                }
                toolsSection
                selectionSection
                saveSearchSection
            } label: {
                Image(systemName: "ellipsis")
            }
            .accessibilityLabel("Browse tools")
        }
    }

    @ViewBuilder
    private var toolsSection: some View {
        Button {
            activeSheet = .columns
        } label: {
            Label("Columns…", systemImage: "tablecells")
        }
        Button {
            showDrafts = true
        } label: {
            Label("Drafts", systemImage: "doc.text")
        }
        Button {
            Task { await refreshNotetypeFields() }
            activeSheet = .findDuplicates
        } label: {
            Label("Find Duplicates…", systemImage: "square.on.square.dashed")
        }
        Button {
            Task { await refreshNotetypeFields() }
            activeSheet = .findReplace
        } label: {
            Label("Find & Replace…", systemImage: "arrow.2.squarepath")
        }
        Button {
            activeSheet = .filteredDeck
        } label: {
            Label("Create Filtered Deck…", systemImage: "square.stack.3d.down.right")
        }
        Button {
            activeSheet = .savedSearchManage
        } label: {
            Label("Manage Saved Searches…", systemImage: "heart.text.square")
        }
    }

    @ViewBuilder
    private var selectionSection: some View {
        Section("Selection") {
            #if os(iOS)
            Button {
                selectionState.enterSelectMode()
            } label: {
                Label("Select", systemImage: "checkmark.circle")
            }
            .disabled(model.ids.isEmpty)
            #endif
            Button {
                selectAllResults()
            } label: {
                Label("Select All Results", systemImage: "checkmark.square")
            }
            .disabled(model.ids.isEmpty)
            .keyboardShortcut("a", modifiers: .command)
            Button {
                invertSelection()
            } label: {
                Label("Invert Selection", systemImage: "arrow.triangle.2.circlepath.square")
            }
            .disabled(model.ids.isEmpty)
            .keyboardShortcut("a", modifiers: [.command, .shift])
            Button {
                Task { await revealSiblings() }
            } label: {
                Label("Select Sibling Cards", systemImage: "square.on.square")
            }
            .disabled(selectionState.isEmpty)
            Button {
                model.searchText = "deck:current"
            } label: {
                Label("Current Deck", systemImage: "book")
            }
        }
    }

    @ViewBuilder
    private var saveSearchSection: some View {
        Section("Saved searches") {
            ForEach(model.savedSearches.searches) { saved in
                Button {
                    model.source = .saved(saved.name)
                } label: {
                    Label(saved.name, systemImage: "heart")
                }
            }
            if !model.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                Button("Save current search…") {
                    saveSearchName = ""
                    showSaveSearchPrompt = true
                }
            }
        }
    }

    /// Three primary batch actions, then a single overflow for the rest.
    /// The overflow is a *separate* toolbar item so iOS 26 cannot fold it
    /// into the system chevron (that nested-ellipsis is what made Restore
    /// and Tags reappear inside More). A flexible spacer pins the cluster
    /// to the leading edge and More to the trailing edge.
    @ToolbarContentBuilder
    private var selectionToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .bottomBar) {
            Button {
                suspendSelected()
            } label: {
                Label("Suspend", systemImage: "pause.circle")
            }
            .disabled(selectionState.isEmpty)

            flagMenu

            Button {
                showTagSheet = true
            } label: {
                Label("Tags", systemImage: "tag")
            }
            .disabled(selectionState.isEmpty)
        }
        if #available(iOS 26.0, macOS 26.0, *) {
            ToolbarSpacer(.flexible, placement: .bottomBar)
        }
        ToolbarItem(placement: .bottomBar) {
            batchOverflowMenu
        }
    }

    /// Flags rendered with their semantic hues (Anki's seven brand colors —
    /// constants on purpose; card states stay palette-driven).
    private var flagMenu: some View {
        Menu {
            flagButton(value: 1, label: "Red", color: BrowseFlagSwatch.color(for: 1) ?? .red)
            flagButton(value: 2, label: "Orange", color: BrowseFlagSwatch.color(for: 2) ?? .orange)
            flagButton(value: 3, label: "Green", color: BrowseFlagSwatch.color(for: 3) ?? .green)
            flagButton(value: 4, label: "Blue", color: BrowseFlagSwatch.color(for: 4) ?? .blue)
            flagButton(value: 5, label: "Pink", color: BrowseFlagSwatch.color(for: 5) ?? .pink)
            flagButton(value: 6, label: "Turquoise", color: BrowseFlagSwatch.color(for: 6) ?? .cyan)
            flagButton(value: 7, label: "Purple", color: BrowseFlagSwatch.color(for: 7) ?? .purple)
            Divider()
            Button {
                applyFlag(0)
            } label: {
                Label("Clear flag", systemImage: "flag.slash")
            }
        } label: {
            Label("Flag", systemImage: "flag")
        }
        .disabled(selectionState.isEmpty)
    }

    private func flagButton(value: UInt32, label: String, color: Color) -> some View {
        Button {
            applyFlag(value)
        } label: {
            HStack {
                Image(systemName: "flag.fill").foregroundStyle(color)
                Text(label)
            }
        }
    }

    /// Remaining batch actions in one scrollable menu — no nested `Menu`s,
    /// and nothing that's already on the bar (Suspend / Flag / Tags).
    private var batchOverflowMenu: some View {
        Menu {
            Section {
                Button {
                    unsuspendSelected()
                } label: {
                    Label("Unsuspend / Unbury", systemImage: "play.circle")
                }
                Button {
                    burySelected()
                } label: {
                    Label("Bury Until Tomorrow", systemImage: "archivebox")
                }
                Button {
                    activeSheet = .forget
                } label: {
                    Label("Forget…", systemImage: "arrow.counterclockwise")
                }
                Button {
                    activeSheet = .reposition
                } label: {
                    Label("Reposition New Cards…", systemImage: "list.number")
                }
                Button {
                    activeSheet = .setDueDate
                } label: {
                    Label("Set Due Date…", systemImage: "calendar")
                }
                Button {
                    activeSheet = .changeDeck
                } label: {
                    Label("Change Deck…", systemImage: "rectangle.stack")
                }
            }

            Section("Grade Now") {
                ForEach([(Rating.again, "Again"), (.hard, "Hard"), (.good, "Good"), (.easy, "Easy")],
                        id: \.1) { rating, label in
                    Button(label) { applyGradeNow(rating) }
                }
            }

            Section {
                Button {
                    let notes = selectionState.selectedNoteIDs
                    let cards = selectionState.selectedCardIDs
                    Task { await model.toggleMarkSelected(notes, cardIDs: Array(cards)) }
                } label: {
                    Label("Mark", systemImage: "star")
                }
                Button {
                    activeSheet = .removeTags
                } label: {
                    Label("Remove Tags", systemImage: "tag.slash")
                }
                Button {
                    activeSheet = .copyNote
                } label: {
                    Label("Create Copy…", systemImage: "doc.on.doc")
                }
                Button {
                    activeSheet = .export
                } label: {
                    Label("Export Selected…", systemImage: "square.and.arrow.up")
                }
                Button {
                    activeSheet = .changeNotetype
                } label: {
                    Label("Change Note Type…", systemImage: "arrow.triangle.2.circlepath.doc")
                }
            }

            Section {
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuIndicator(.hidden)
        .disabled(selectionState.isEmpty)
        .accessibilityLabel("More actions")
    }

    private func consumeBatchScope() -> (Set<NoteID>, Set<CardID>) {
        let notes = batchNotes
        let cards = batchCards
        if batchScopeOverride == nil {
            selectionState.exitSelectMode()
        }
        batchScopeOverride = nil
        return (notes, cards)
    }

    private func applyGradeNow(_ rating: Rating) {
        let notes = selectionState.selectedNoteIDs
        let cards = selectionState.selectedCardIDs
        selectionState.exitSelectMode()
        Task { await model.gradeNowSelectedNotes(notes, cardIDs: Array(cards), rating: rating) }
    }

    // MARK: - Selection actions

    /// Capture the current selection, drop out of select mode for snappy
    /// feedback, then run the batch mutation on the model.
    private func suspendSelected() {
        let notes = selectionState.selectedNoteIDs
        let cards = selectionState.selectedCardIDs
        selectionState.exitSelectMode()
        Task { await model.suspendSelected(notes, cardIDs: Array(cards)) }
    }

    private func unsuspendSelected() {
        let notes = selectionState.selectedNoteIDs
        let cards = Array(selectionState.selectedCardIDs)
        selectionState.exitSelectMode()
        Task { await model.unSuspendSelected(notes, cardIDs: cards) }
    }

    private func burySelected() {
        let notes = selectionState.selectedNoteIDs
        let cards = selectionState.selectedCardIDs
        selectionState.exitSelectMode()
        Task { await model.burySelected(notes, cardIDs: Array(cards)) }
    }

    private func applyFlag(_ value: UInt32) {
        let notes = selectionState.selectedNoteIDs
        let cards = selectionState.selectedCardIDs
        selectionState.exitSelectMode()
        Task { await model.flagSelected(notes, cardIDs: Array(cards), value: value) }
    }

    private func deleteSelected() {
        let ids = selectionState.selectedNoteIDs
        selectionState.exitSelectMode()
        Task { await model.deleteSelected(ids) }
    }

    // MARK: - Selection commands (P2)

    private func selectAllResults() {
        switch model.mode {
        case .notes:
            selectionState.selectedNoteIDs = Set(model.allResultNoteIDs)
            selectionState.selectedCardIDs = []
        case .cards:
            selectionState.selectedCardIDs = Set(model.allResultCardIDs)
            selectionState.selectedNoteIDs = []
        }
        selectionState.isSelectMode = true
    }

    private var allResultsSelected: Bool {
        switch model.mode {
        case .notes:
            let all = model.allResultNoteIDs
            return !all.isEmpty && selectionState.selectedNoteIDs.count == all.count
        case .cards:
            let all = model.allResultCardIDs
            return !all.isEmpty && selectionState.selectedCardIDs.count == all.count
        }
    }

    private func toggleSelectAllResults() {
        if allResultsSelected {
            selectionState.clearSelectionKeepingMode()
        } else {
            selectAllResults()
        }
    }

    private func invertSelection() {
        switch model.mode {
        case .notes:
            let all = Set(model.allResultNoteIDs)
            selectionState.selectedNoteIDs = all.subtracting(selectionState.selectedNoteIDs)
            selectionState.selectedCardIDs = []
        case .cards:
            let all = Set(model.allResultCardIDs)
            selectionState.selectedCardIDs = all.subtracting(selectionState.selectedCardIDs)
            selectionState.selectedNoteIDs = []
        }
        selectionState.isSelectMode = true
    }

    /// Desktop "select notes / reveal siblings": expand the current note
    /// selection to all sibling cards (cards mode) for inspection.
    private func revealSiblings() async {
        let notes = Array(selectionState.selectedNoteIDs)
        var cards = Array(selectionState.selectedCardIDs)
        if !notes.isEmpty {
            let siblings = await model.siblingCards(of: notes)
            cards = Array(Set(cards + siblings))
        } else if !cards.isEmpty {
            let derived = await model.noteIDsOfCards(cards)
            let siblings = await model.siblingCards(of: derived)
            cards = Array(Set(siblings))
        }
        guard !cards.isEmpty else { return }
        if model.mode == .cards {
            selectionState.selectedCardIDs = Set(cards)
        } else {
            // Notes mode stays note-scoped; siblings are a card-mode concept.
            model.mode = .cards
            selectionState.selectedCardIDs = Set(cards)
            selectionState.selectedNoteIDs = []
        }
        selectionState.isSelectMode = true
    }
}

private extension Substring {
    /// Unwraps a quoted fragment like `"A::B"` → A::B.
    var trimmedQuoted: String? {
        let s = trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        return s.isEmpty ? nil : s
    }
}

#if os(iOS)
/// Settings (or Profiles) as the trailing column of a two-column Browse
/// split. Back clears the destination so the three-column browse returns.
private struct BrowseAccountDestination: View {
    @Binding var destination: AccountMenuDestination?
    @Environment(\.accountMenuProvider) private var provider

    var body: some View {
        if let destination, let provider {
            provider.destination(for: destination)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            self.destination = nil
                        } label: {
                            Label("Browse", systemImage: "chevron.backward")
                        }
                    }
                }
        }
    }
}
#endif

// MARK: - Preview

#if DEBUG
@MainActor
private func previewBrowseModel() -> BrowseModel {
    let model = BrowseModel()
    let seeded: [(Int64, String, String)] = [
        (1, "vocab", "안녕하세요 — hello"),
        (2, "marked grammar", "Bonjour le monde"),
        (3, "", "The quick brown fox jumps over the lazy dog"),
    ]
    let mods: [Int64: Int64] = [1: 1_700_000_300, 2: 1_700_000_200, 3: 1_700_000_100]
    var records: [Int64: NoteRecord] = [:]
    var ids: [Int64] = []
    for seed in seeded {
        let (id, tags, text) = seed
        records[id] = NoteRecord(
            id: NoteID(id), guid: "g\(id)", mid: NotetypeID(1), mod: mods[id] ?? 0,
            tags: tags, flds: "", sfld: text, csum: 0
        )
        ids.append(id)
    }
    model.seedPreview(ids: ids, records: records)
    model.allTags = ["vocab", "grammar", "marked"]
    return model
}

#Preview("Browse list") {
    NavigationStack {
        BrowseListColumn(
            model: previewBrowseModel(),
            selectionState: .constant(BrowseSelectionState()),
            onSwipeDelete: { _ in }
        )
        .navigationTitle("All Decks")
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif

extension BrowseView.Sheet: Identifiable {}

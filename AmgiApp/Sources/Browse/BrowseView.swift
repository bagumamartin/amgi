import SwiftUI
import AmgiUI
import AnkiKit
import AnkiClients
import Dependencies
import AmgiTheme

/// Browse container: ONE three-column `NavigationSplitView` — sources, list,
/// detail — plus the toolbar, sheets and confirmation dialogs.
///
/// It used to be mounted inside another `NavigationSplitView` (the root
/// sidebar) with a `NavigationStack` around each of its own columns. Four
/// nested columns in one window collapsed the list to a sliver and scattered
/// toolbar items above the wrong panes, so on macOS Browse now takes the
/// window over and `exit` is the way back.
///
/// Rendering is delegated to `BrowseSourceColumn` / `BrowseListColumn` /
/// `BrowseDetailTabs`; the model owns all I/O.
struct BrowseView: View {
    @State private var model: BrowseModel
    @State private var selectionState = BrowseSelectionState()
    @State private var showAddNote = false
    @State private var showAddImageOcclusion = false
    @State private var showTagSheet = false
    @State private var showDeleteConfirm = false
    @State private var pendingSwipeDelete: NoteRecord?

    // Power tools + batch destinations
    enum Sheet: Int, Hashable {
        case filterRail, findDuplicates, findReplace, changeDeck, setDueDate, reposition

        var id: Int { rawValue }
    }
    @State private var activeSheet: Sheet?
    @State private var notetypeFieldNames: [String] = []
    @State private var showSaveSearchPrompt = false
    @State private var saveSearchName = ""

    @Dependency(\.notetypesService) private var notetypesService
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.palette) private var palette

    /// Present only on macOS, where Browse replaces the root sidebar.
    private let exit: BrowseExit?

    private var savedSearchStore: SavedSearchStore { model.savedSearches }

    init(model: BrowseModel = BrowseModel(), exit: BrowseExit? = nil) {
        _model = State(initialValue: model)
        self.exit = exit
    }

    var body: some View {
        NavigationSplitView {
            BrowseSourceColumn(model: model, exit: exit)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } content: {
            listPane
                .navigationSplitViewColumnWidth(min: 300, ideal: 400)
        } detail: {
            detailPane
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: model.searchText) { _, _ in model.scheduleSearch() }
        .task { await appear() }
    }

    // MARK: - Columns

    /// The list column owns the search field and the toolbar, so both sit
    /// above the list they act on (Mail's arrangement).
    private var listPane: some View {
        NavigationStack {
            dialogContent
                .navigationTitle(sourceTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarContent }
                .accountMenu()
                .searchable(
                    text: $model.searchText,
                    placement: searchPlacement,
                    prompt: searchPrompt
                )
                .searchMinimizedIfAvailable()
                .onSubmit(of: .search) { model.commitSearchHistory() }
                .searchSuggestions {
                    ForEach(model.recentQueries.prefix(8), id: \.self) { query in
                        Button {
                            model.searchText = query
                            model.commitSearchHistory()
                            model.scheduleSearch(immediate: true)
                        } label: {
                            Label(query, systemImage: "clock.arrow.circlepath")
                        }
                        .searchCompletion(query)
                    }
                }
                #if os(iOS)
                .toolbarBackground(.visible, for: .bottomBar)
                .toolbarBackground(.ultraThinMaterial, for: .bottomBar)
                #endif
        }
    }

    private var detailPane: some View {
        NavigationStack {
            if model.focusedNote != nil || model.focusedCard != nil {
                BrowseDetailTabs(
                    note: model.focusedNote,
                    notetypeName: model.focusedNote.flatMap { model.notetypeNames[$0.mid] },
                    infoCard: model.focusedCard,
                    firstCardID: model.focusedCardID,
                    onSaved: { Task { await model.performSearch() } }
                )
                .id(model.focusedNote?.id ?? NoteID(0))
                .navigationTitle("Details")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            model.clearFocus()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(palette.textSecondary)
                        }
                        .buttonStyle(.plain)
                        .help("Close")
                        .accessibilityLabel("Close details")
                    }
                }
            } else {
                ContentUnavailableView(
                    "No Selection",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("Select a \(rowNoun) to view its details.")
                )
            }
        }
    }

    // MARK: - Titles & search chrome

    private var rowNoun: String {
        model.mode == .notes ? "note" : "card"
    }

    /// Names what the list is scoped to, mirroring the sidebar selection.
    private var sourceTitle: String {
        switch model.source {
        case .allDecks:
            return "All Decks"
        case .deck(let id):
            guard let deck = model.allDecks.first(where: { $0.id == id }) else { return "Browse" }
            return deck.name.split(separator: "::").last.map(String.init) ?? deck.name
        case .tag(let tag):
            return tag
        case .saved(let name):
            return name
        }
    }

    private var searchPlacement: SearchFieldPlacement {
        #if os(macOS)
        return .toolbar
        #else
        return horizontalSizeClass == .compact
            ? .toolbar
            : .navigationBarDrawer(displayMode: .always)
        #endif
    }

    private var searchPrompt: String {
        switch model.source {
        case .allDecks: "Search all \(rowNoun)s…"
        case .deck, .tag, .saved: "Search in \(sourceTitle)…"
        }
    }

    // MARK: - Loading

    private func appear() async {
        await model.loadDecks()
        // Drill-in from a deck detail screen or an amgi://browse deep link.
        if let seed = BrowseLauncher.shared.consume(), !seed.isEmpty {
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
    }

    /// Field names of the most common notetype among current results —
    /// feeds Find&Replace and the duplicates field picker.
    private func refreshNotetypeFields() async {
        guard let anyNote = model.ids.first(where: { model.note(at: $0) != nil })
            .flatMap({ model.note(at: $0) }) else {
            notetypeFieldNames = []
            return
        }
        if let names = try? notetypesService.getNotetype(anyNote.mid).fieldNames,
           !names.isEmpty {
            notetypeFieldNames = names
        }
    }

    // MARK: - Dialogs & sheets
    //
    // Layered into small computed views on purpose: one chained expression
    // blows past the Swift type-checker's time budget.

    private var dialogContent: some View {
        sheetContent
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
                Text("You can undo this from the toolbar.")
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
                Text("One undo entry is created; you can restore from the toolbar.")
            }
            .alert("Save current search", isPresented: $showSaveSearchPrompt) {
                TextField("Name", text: $saveSearchName)
                Button("Save") {
                    model.saveCurrentQuery(as: saveSearchName)
                    saveSearchName = ""
                }
                Button("Cancel", role: .cancel) { saveSearchName = "" }
            } message: {
                Text("Saved searches sync to every device via your collection config — desktop Anki sees them too.")
            }
    }

    private var sheetContent: some View {
        BrowseListColumn(
            model: model,
            selectionState: $selectionState,
            onSwipeDelete: { pendingSwipeDelete = $0 }
        )
        .sheet(isPresented: $showAddNote) {
            AddNoteView {
                Task { await model.performSearch() }
            }
        }
        .sheet(isPresented: $showAddImageOcclusion) {
            AddImageOcclusionNoteView { Task { await model.performSearch() } }
        }
        .sheet(isPresented: $showTagSheet) {
            BatchTagSheet(noteIDs: selectionState.selectedNoteIDs) {
                Task {
                    selectionState.exitSelectMode()
                    await model.performSearch()
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
        case .filterRail:
            BrowseFilterRailView(
                model: model,
                savedSearches: savedSearchStore.searches,
                onDeleteSaved: { savedSearchStore.delete(name: $0); savedSearchStore.refresh() },
                onSaveCurrent: { name in model.saveCurrentQuery(as: name) }
            )
            .presentationDetents([.medium, .large])
        case .findDuplicates:
            FindDuplicatesView(
                notetypeFields: notetypeFieldNames,
                runExactScan: { field, text in
                    await model.exactDuplicateGroups(field: field, searchText: text)
                },
                runNearScan: {
                    model.nearDuplicateGroupsInScope()
                },
                openGroup: { ids in openDuplicateGroup(ids.map { NoteID($0) }) }
            )
        case .findReplace:
            FindReplaceSheet(
                fieldNames: notetypeFieldNames,
                selectionCount: selectionState.count,
                onApply: { search, replacement, regex, matchCase, fieldName in
                    await model.findAndReplace(
                        search: search, replacement: replacement, regex: regex,
                        matchCase: matchCase, fieldName: fieldName,
                        scopeNoteIds: Array(selectionState.selectedNoteIDs)
                    )
                }
            )
        case .changeDeck:
            ChangeDeckSheet(decks: model.allDecks) { deckId in
                let ids = selectionState.selectedNoteIDs
                selectionState.exitSelectMode()
                Task { await model.changeDeckSelected(ids, deckId: deckId) }
            }
        case .setDueDate:
            SetDueDateSheet { expression in
                let ids = selectionState.selectedNoteIDs
                selectionState.exitSelectMode()
                Task { await model.setDueDateSelected(ids, expression: expression) }
            }
        case .reposition:
            RepositionSheet { start, step, randomize, shift in
                let ids = selectionState.selectedNoteIDs
                selectionState.exitSelectMode()
                Task {
                    await model.repositionSelectedNotes(
                        ids, start: start, step: step, randomize: randomize, shift: shift
                    )
                }
            }
        }
    }

    private func openDuplicateGroup(_ noteIds: [NoteID]) {
        let fragment = "nid:(\(noteIds.map { String($0.rawValue) }.joined(separator: " ")))"
        model.searchText = fragment
        activeSheet = nil
        model.scheduleSearch(immediate: true)
    }

    // MARK: - Toolbar
    //
    // Mode and sort live in the list column's own header bar, not here.
    // Sync is deliberately absent: it belongs to Library and ⌘⇧S.

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            if selectionState.isSelectMode {
                Button("Done") {
                    selectionState.exitSelectMode()
                }
            } else {
                Menu {
                    Button("Add Note") { showAddNote = true }
                    Button("Add Image Occlusion") { showAddImageOcclusion = true }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add")
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Menu {
                toolsSection
                saveSearchSection
            } label: {
                Image(systemName: "ellipsis")
            }
            .accessibilityLabel("Browse tools")

            EngineUndoButton()
        }
        if selectionState.showsBatchActions {
            selectionToolbar
        }
    }

    @ViewBuilder
    private var toolsSection: some View {
        Button {
            activeSheet = .filterRail
        } label: {
            Label("Filter Rail…", systemImage: "line.3.horizontal.decrease.circle")
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

    private var selectionToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .bottomBar) {
            Button {
                suspendSelected()
            } label: {
                Label("Suspend", systemImage: "pause.circle")
            }
            .disabled(selectionState.isEmpty)

            flagMenu

            markButton

            Button {
                showTagSheet = true
            } label: {
                Label("Tags", systemImage: "tag")
            }
            .disabled(selectionState.isEmpty)

            schedulingMenu

            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(selectionState.isEmpty)
        }
    }

    /// Flags rendered with their semantic hues (Anki's seven brand colors —
    /// constants on purpose; card states stay palette-driven).
    private var flagMenu: some View {
        Menu {
            flagButton(value: 1, label: "Red", color: Color(hexBrowseFlag: 0xFF3B30))
            flagButton(value: 2, label: "Orange", color: Color(hexBrowseFlag: 0xFF9500))
            flagButton(value: 3, label: "Green", color: Color(hexBrowseFlag: 0x34C759))
            flagButton(value: 4, label: "Blue", color: Color(hexBrowseFlag: 0x007AFF))
            flagButton(value: 5, label: "Pink", color: Color(hexBrowseFlag: 0xFF2D55))
            flagButton(value: 6, label: "Turquoise", color: Color(hexBrowseFlag: 0x32ADE6))
            flagButton(value: 7, label: "Purple", color: Color(hexBrowseFlag: 0xAF52DE))
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

    private var markButton: some View {
        Button {
            let ids = selectionState.selectedNoteIDs
            Task { await model.toggleMarkSelected(ids) }
        } label: {
            Label("Mark", systemImage: "star")
        }
        .disabled(selectionState.isEmpty)
    }

    /// Change deck / due date / grade-now / reposition / bury — desktop's
    /// Cards menu, consolidated for touch.
    private var schedulingMenu: some View {
        Menu {
            Button {
                activeSheet = .changeDeck
            } label: { Label("Change Deck…", systemImage: "rectangle.stack") }

            Menu("Grade Now…") {
                ForEach([(Rating.again, "Again"), (.hard, "Hard"), (.good, "Good"), (.easy, "Easy")],
                        id: \.1) { rating, label in
                    Button(label) { applyGradeNow(rating) }
                }
            }

            Button {
                activeSheet = .setDueDate
            } label: { Label("Set Due Date…", systemImage: "calendar") }

            Button {
                activeSheet = .reposition
            } label: { Label("Reposition New Cards…", systemImage: "list.number") }

            Divider()
            Button {
                let ids = selectionState.selectedNoteIDs
                selectionState.exitSelectMode()
                Task { await model.burySelected(ids) }
            } label: { Label("Bury Until Tomorrow", systemImage: "archivebox") }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .disabled(selectionState.isEmpty)
        .accessibilityLabel("Scheduling actions")
    }

    private func applyGradeNow(_ rating: Rating) {
        let ids = selectionState.selectedNoteIDs
        selectionState.exitSelectMode()
        Task { await model.gradeNowSelectedNotes(ids, rating: rating) }
    }

    // MARK: - Selection actions

    /// Capture the current selection, drop out of select mode for snappy
    /// feedback, then run the batch mutation on the model.
    private func suspendSelected() {
        let ids = selectionState.selectedNoteIDs
        selectionState.exitSelectMode()
        Task { await model.suspendSelected(ids) }
    }

    private func applyFlag(_ value: UInt32) {
        let ids = selectionState.selectedNoteIDs
        selectionState.exitSelectMode()
        Task { await model.flagSelected(ids, value: value) }
    }

    private func deleteSelected() {
        let ids = selectionState.selectedNoteIDs
        selectionState.exitSelectMode()
        Task { await model.deleteSelected(ids) }
    }
}

private extension Substring {
    /// Unwraps a quoted fragment like `"A::B"` → A::B.
    var trimmedQuoted: String? {
        let s = trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        return s.isEmpty ? nil : s
    }
}

// MARK: - Hex helper

private extension Color {
    init(hexBrowseFlag hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}

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

import SwiftUI
import AnkiKit
import AnkiClients
import Dependencies
import AmgiTheme

/// Browse container: owns navigation, sheets, selection, and the toolbar,
/// and drives a `BrowseModel` for load/search/windowing + mutations.
/// Rendering is delegated to `BrowseContent`; the model owns all I/O so the
/// View is thin presentation wiring with no direct engine access.
struct BrowseView: View {
    @State private var model: BrowseModel
    @State private var selectionState = BrowseSelectionState()
    @State private var showAddNote = false
    @State private var showAddImageOcclusion = false
    @State private var showTagSheet = false
    @State private var showDeleteConfirm = false
    @State private var pendingSwipeDelete: NoteRecord?

    init(model: BrowseModel = BrowseModel()) {
        _model = State(initialValue: model)
    }

    // The body is split into small layered computed views: a single chained
    // expression here blows past the Swift type-checker's time budget, so each
    // layer applies only a few modifiers.
    var body: some View {
        @Bindable var model = model
        decoratedContent
            .searchable(text: $model.searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search notes...")
            .onChange(of: model.searchText) { _, _ in model.scheduleSearch() }
            .onChange(of: model.activeDeck) { _, _ in model.scheduleSearch(immediate: true) }
            .onChange(of: model.activeTag) { _, _ in model.scheduleSearch(immediate: true) }
            .task { await appear() }
    }

    private func appear() async {
        await model.loadDecks()
        if let seed = BrowseLauncher.shared.consume(), !seed.isEmpty,
           seed.hasPrefix("deck:"), let name = seed.dropFirst(5).trimmedQuoted,
           let deck = model.allDecks.first(where: { $0.name == name }) {
            // Drill-in: scope to that deck, reusing the chip bar state.
            model.parentDeck = deck
            model.activeDeck = deck
            await model.loadInitial()
            await model.performSearch()
        } else if let seed = BrowseLauncher.shared.consume(), !seed.isEmpty {
            model.searchText = seed
            await model.loadInitial()
            await model.performSearch()
        } else {
            await model.loadInitial()
        }
        await model.refreshUndoStatus()
    }

    private var decoratedContent: some View {
        dialogContent
            .navigationTitle("Browse")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
    }

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
    }

    private var sheetContent: some View {
        BrowseContent(
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
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                modeSection
                Divider()
                sortSection
            } label: {
                Image(systemName: "arrow.up.arrow.down")
            }
            .disabled(model.ids.isEmpty && !model.isLoading)
        }
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
            }
        }
        ToolbarItem(placement: .principal) {
            Picker("Mode", selection: $model.mode) {
                ForEach(BrowseModel.Mode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
        }
        if selectionState.isSelectMode {
            selectionToolbar
        }
    }

    @ViewBuilder
    private var modeSection: some View {
        Picker("Show", selection: $model.mode) {
            ForEach(BrowseModel.Mode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
    }

    @ViewBuilder
    private var sortSection: some View {
        Section("Sort by") {
            ForEach(BrowseModel.SortOrder.allCases) { order in
                Button {
                    model.sortOrder = order
                } label: {
                    if model.sortOrder == order {
                        Label(order.label, systemImage: "checkmark")
                    } else {
                        Text(order.label)
                    }
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var selectionToolbar: some ToolbarContent {
        ToolbarItem(placement: .bottomBar) {
            Button {
                suspendSelected()
            } label: {
                Label("Suspend", systemImage: "pause.circle")
            }
            .disabled(selectionState.isEmpty)
        }
        ToolbarItem(placement: .bottomBar) {
            Spacer()
        }
        ToolbarItem(placement: .bottomBar) {
            flagMenu
        }
        ToolbarItem(placement: .bottomBar) {
            Spacer()
        }
        ToolbarItem(placement: .bottomBar) {
            Button {
                showTagSheet = true
            } label: {
                Label("Tags", systemImage: "tag")
            }
            .disabled(selectionState.isEmpty)
        }
        ToolbarItem(placement: .bottomBar) {
            Spacer()
        }
        ToolbarItem(placement: .bottomBar) {
            undoRedoMenu
        }
        ToolbarItem(placement: .bottomBar) {
            Spacer()
        }
        ToolbarItem(placement: .bottomBar) {
            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(selectionState.isEmpty)
        }
    }

    /// Flags rendered with their semantic hues (Anki's seven flag colors —
    /// brand constants, not theme slots; card states stay palette-driven).
    private var flagMenu: some View {
        Menu {
            flagButton(value: 1, label: "Red", color: Color(hex: 0xFF3B30))
            flagButton(value: 2, label: "Orange", color: Color(hex: 0xFF9500))
            flagButton(value: 3, label: "Green", color: Color(hex: 0x34C759))
            flagButton(value: 4, label: "Blue", color: Color(hex: 0x007AFF))
            flagButton(value: 5, label: "Pink", color: Color(hex: 0xFF2D55))
            flagButton(value: 6, label: "Turquoise", color: Color(hex: 0x32ADE6))
            flagButton(value: 7, label: "Purple", color: Color(hex: 0xAF52DE))
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

    /// Undo/redo ride the ENGINE stack, so they reverse batch deletes too.
    private var undoRedoMenu: some View {
        HStack(spacing: 16) {
            Button {
                Task { await model.undoLast() }
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .disabled(model.undoStatus?.canUndo != true)
            .accessibilityLabel(model.undoStatus.map { "Undo \($0.undoText)" } ?? "Undo")

            Button {
                Task { await model.redoLast() }
            } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .disabled(model.undoStatus?.canRedo != true)
            .accessibilityLabel(model.undoStatus.map { "Redo \($0.redoText)" } ?? "Redo")
        }
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

// MARK: - BrowseContent

/// Pure rendering for the Browse screen: the notes/cards list (select-mode,
/// swipe-to-delete, windowing hooks) plus the deck/tag filter bar. Reads
/// state from the model and drives mutations through it, but owns no I/O of
/// its own — so it renders in a `#Preview` from a seeded model.
struct BrowseContent: View {
    @Environment(\.palette) private var palette
    @Bindable var model: BrowseModel
    @Binding var selectionState: BrowseSelectionState
    let onSwipeDelete: (NoteRecord) -> Void

    var body: some View {
        statefulContent
            .safeAreaInset(edge: .top) {
                if !model.allDecks.isEmpty || !model.allTags.isEmpty {
                    filterBar
                }
            }
    }

    private var isEmpty: Bool {
        switch model.mode {
        case .notes: return model.ids.isEmpty
        case .cards: return model.ids.isEmpty
        }
    }

    @ViewBuilder
    private var statefulContent: some View {
        if isEmpty && !model.isLoading && model.searchText.isEmpty && model.activeDeck == nil {
            ContentUnavailableView(
                "Browse \(model.mode.title)",
                systemImage: "magnifyingglass",
                description: Text("Search by content, tags, or filter by deck.")
            )
        } else if isEmpty && !model.isLoading {
            ContentUnavailableView.search(text: model.searchText)
        } else {
            itemList
        }
    }

    // MARK: - Item List

    private var itemList: some View {
        List {
            ForEach(Array(model.ids.prefix(model.loadedCount).enumerated()),
                    id: \.element) { index, idRaw in
                row(for: idRaw, index: index)
            }

            if model.hasMorePages || model.isLoading {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            }
        }
        .navigationDestination(for: NoteRecord.self) { note in
            NoteEditingDestinationView(note: note) {
                Task { await model.performSearch() }
            }
        }
    }

    @ViewBuilder
    private func row(for idRaw: Int64, index: Int) -> some View {
        switch model.mode {
        case .notes:
            if let note = model.note(at: idRaw) {
                noteRow(note, index: index)
            } else {
                hydratingRow(index: index)
            }
        case .cards:
            CardRowView(card: model.card(at: idRaw))
                .onAppear { Task { await model.loadMoreIfNeeded(index: index) } }
        }
    }

    @ViewBuilder
    private func noteRow(_ note: NoteRecord, index: Int) -> some View {
        HStack {
            if selectionState.isSelectMode {
                Image(systemName: selectionState.contains(note.id.rawValue) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selectionState.contains(note.id.rawValue) ? palette.accent : palette.textSecondary)
                NoteRowView(note: note, notetypeName: model.notetypeNames[note.mid])
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectionState.toggle(note.id.rawValue)
                    }
                    .onAppear { onRowAppear(note.id.rawValue, index: index) }
            } else {
                HStack {
                    NavigationLink(value: note) {
                        NoteRowView(note: note, notetypeName: model.notetypeNames[note.mid])
                            .onAppear { onRowAppear(note.id.rawValue, index: index) }
                    }
                    NoteContextMenuButton(noteId: note.id) {
                        Task { await model.performSearch() }
                    }
                }
                .contentShape(Rectangle())
                .onLongPressGesture(minimumDuration: 0.5) {
                    selectionState.enterSelectMode(preselect: note.id.rawValue)
                }
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                onSwipeDelete(note)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func hydratingRow(index: Int) -> some View {
        HStack(spacing: 12) {
            Circle().fill(palette.surfaceElevated).frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 4) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(palette.surfaceElevated)
                    .frame(width: 160, height: 12)
                RoundedRectangle(cornerRadius: 3)
                    .fill(palette.surfaceElevated.opacity(0.6))
                    .frame(width: 100, height: 10)
            }
        }
        .opacity(0.7)
        .onAppear { Task { await model.loadMoreIfNeeded(index: index) } }
    }

    /// Trigger window extension when near the end of loaded rows.
    private func onRowAppear(_ id: Int64, index: Int) {
        Task { await model.loadMoreIfNeeded(index: index) }
    }

    // MARK: - Filter Bar (phase 3 replaces with filter rail)

    private var filterBar: some View {
        VStack(spacing: 0) {
            if !model.allDecks.isEmpty {
                deckFilterBar
            }
            if !model.allTags.isEmpty {
                tagChipRow
            }
        }
    }

    private var tagChipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chipButton(label: "All", isSelected: model.activeTag == nil) {
                    model.activeTag = nil
                }
                ForEach(model.allTags, id: \.self) { tag in
                    chipButton(label: tag, isSelected: model.activeTag == tag) {
                        model.activeTag = (model.activeTag == tag) ? nil : tag
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    private var deckFilterBar: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chipButton(label: "All", isSelected: model.activeDeck == nil) {
                        model.parentDeck = nil
                        model.activeDeck = nil
                    }
                    ForEach(model.topLevelDecks) { deck in
                        chipButton(
                            label: deck.name,
                            isSelected: model.parentDeck?.id == deck.id && model.activeDeck?.id == deck.id
                        ) {
                            model.parentDeck = deck
                            model.activeDeck = deck
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }

            if !model.childDecks.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        chipButton(
                            label: "All",
                            isSelected: model.activeDeck?.id == model.parentDeck?.id,
                            small: true
                        ) {
                            model.activeDeck = model.parentDeck
                        }
                        ForEach(model.childDecks) { child in
                            chipButton(
                                label: shortName(child.name),
                                isSelected: model.activeDeck?.id == child.id,
                                small: true
                            ) {
                                model.activeDeck = child
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                }
            }
        }
        .background(.bar)
    }
}

private extension BrowseContent {
    func chipButton(
        label: String,
        isSelected: Bool,
        small: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(label)
                .amgiFont(small ? .caption : .body)
                .padding(.horizontal, small ? 10 : 12)
                .padding(.vertical, small ? 4 : 6)
                .background(isSelected ? palette.accent : palette.surface)
                .foregroundStyle(isSelected ? .white : palette.textPrimary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    func shortName(_ fullName: String) -> String {
        String(fullName.split(separator: "::").last ?? Substring(fullName))
    }
}

// MARK: - NoteContextMenuButton

/// Resolves the first cardId for a note lazily on first appear, then shows CardContextMenu.
@MainActor
struct NoteContextMenuButton: View {
    let noteId: NoteID
    var onSuccess: (() -> Void)?

    @Dependency(\.cardClient) var cardClient
    @State private var firstCardId: CardID?

    var body: some View {
        Group {
            if let cardId = firstCardId {
                CardContextMenu(
                    cardId: cardId,
                    noteId: noteId,
                    onSuccess: onSuccess
                )
            } else {
                Image(systemName: "ellipsis.circle")
                    .amgiFont(.bodyEmphasis)
                    .foregroundStyle(.tertiary)
            }
        }
        .task(id: noteId) {
            guard firstCardId == nil else { return }
            firstCardId = (try? await cardClient.fetchByNote(noteId))?.first?.id
        }
    }
}

// MARK: - Rows

extension BrowseSelectionState {
    func contains(_ rawValue: Int64) -> Bool {
        selectedNoteIDs.contains(NoteID(rawValue))
    }

    func toggle(_ rawValue: Int64) {
        toggle(NoteID(rawValue))
    }

    func enterSelectMode(preselect rawValue: Int64) {
        enterSelectMode(preselect: NoteID(rawValue))
    }
}

/// Notes-mode row: title + subtitle + trailing state/flag chips.
/// State dot colors bind to theme card-state slots (decisions.md rule).
struct NoteRowView: View {
    @Environment(\.palette) private var palette
    let note: NoteRecord
    let notetypeName: String?

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(strippedTitle)
                    .amgiFont(.body)
                    .lineLimit(1)
                subtitleView
            }
            Spacer(minLength: 8)
            if hasMarkedTag {
                Image(systemName: "star.fill")
                    .font(.caption2)
                    .foregroundStyle(palette.customStudyBadge)
            }
        }
        .padding(.vertical, 2)
    }

    private var strippedTitle: String {
        note.sfld.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @ViewBuilder
    private var subtitleView: some View {
        let parts = [notetypeName].compactMap { $0.isEmpty ? nil : $0 } +
            note.tags.split(separator: " ").filter { $0 != "marked" }.map(String.init)
        if !parts.isEmpty {
            Text(parts.joined(separator: " · "))
                .amgiFont(.caption)
                .foregroundStyle(palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private var hasMarkedTag: Bool {
        note.tags.split(separator: " ").contains { $0.caseInsensitiveCompare("marked") == .orderedSame }
    }
}

/// Cards-mode row: per-card granularity with scheduling info.
struct CardRowView: View {
    @Environment(\.palette) private var palette
    let card: CardRecord?

    var body: some View {
        HStack(spacing: 10) {
            if let card {
                stateDot(queue: card.queue, type: card.type)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title(for: card))
                        .amgiFont(.body)
                        .lineLimit(1)
                    Text(subtitle(for: card))
                        .amgiFont(.caption)
                        .foregroundStyle(palette.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                duePill(queue: card.queue, type: card.type, due: card.due)
            } else {
                // Hydrating placeholder mirrors hydratingRow geometry.
                Circle().fill(palette.surfaceElevated).frame(width: 10, height: 10)
                Text("Loading…")
                    .amgiFont(.caption)
                    .foregroundStyle(palette.textTertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private func title(for card: CardRecord) -> String {
        "Card #\(card.id.rawValue)"
    }

    private func subtitle(for card: CardRecord) -> String {
        let typeName: String = switch card.type {
        case 0: "New"
        case 1: "Learning"
        case 2: "Review"
        case 3: "Relearning"
        default: ""
        }
        let flags = ["No flag", "Red", "Orange", "Green", "Blue", "Pink", "Turquoise", "Purple"]
        let flagName = flags[Int(card.flags & 0b111)]
        return [typeName.isEmpty ? nil : typeName, "Ease \(card.factor / 10)%"].compactMap { $0 }.joined(separator: " · ") + (flagName == "No flag" ? "" : " · \(flagName)")
    }

    private func stateDot(queue: Int16, type: Int16) -> some View {
        Circle().fill(dotColor(queue: queue, type: type)).frame(width: 10, height: 10)
    }

    private func dotColor(queue: Int16, type: Int16) -> Color {
        if queue < -1 { return palette.warning }
        if queue == -1 { return palette.cardStateSuspended }
        switch type {
        case 0: return palette.cardStateNew
        case 1: return palette.cardStateLearning
        case 3: return palette.cardStateRelearn
        default: return palette.cardStateReview
        }
    }

    @ViewBuilder
    private func duePill(queue: Int16, type: Int16, due: Int32) -> some View {
        guard let text = dueText(queue: queue, type: type, due: due) else { return }
        Text(text)
            .amgiFont(.caption2)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(dotColor(queue: queue, type: type).opacity(0.14))
            .foregroundStyle(dotColor(queue: queue, type: type))
            .clipShape(Capsule())
    }

    private func dueText(queue: Int16, type: Int16, due: Int32) -> String? {
        switch type {
        case 0:
            return "pos \(due)"
        default:
            // Learning epochs vs review days differ; coarse labels only —
            // exact formatting arrives with engine rows (P2d follow-up).
            return queue < 0 ? nil : (due > 86_400 ? "+\(due / 86_400)d" : "today")
        }
    }
}

// MARK: - Hex helper

private extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}

// MARK: - Preview

#if DEBUG
#Preview {
    // Seed the model directly: BrowseContent has no `.task`, so the sample
    // notes aren't overwritten by a load, and no live backend is touched.
    let model = BrowseModel()
    let records: [(Int64, String)] = [
        (1, "안녕하세요 — hello"),
        (2, "Bonjour le monde"),
        (3, "The quick brown fox jumps over the lazy dog"),
    ]
    model.ids = records.map(\.0)
    for (id, text) in records {
        let mod: Int64 = switch id { case 1: 1_700_000_300; case 2: 1_700_000_200; default: 1_700_000_100 }
        let tags = id == 1 ? "vocab" : (id == 2 ? "marked grammar" : "")
        model.noteRecords[id] = NoteRecord(id: NoteID(id), guid: "g\(id)", mid: NotetypeID(1), mod: mod, tags: tags, flds: "", sfld: text, csum: 0)
    }
    model.hasMorePages = false
    model.allTags = ["vocab", "grammar", "marked"]
    return NavigationStack {
        BrowseContent(
            model: model,
            selectionState: .constant(BrowseSelectionState()),
            onSwipeDelete: { _ in }
        )
        .navigationTitle("Browse")
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif

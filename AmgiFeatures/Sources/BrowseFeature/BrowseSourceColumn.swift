// AmgiApp/Sources/Browse/BrowseSourceColumn.swift
import SwiftUI
import AmgiUI
import AnkiKit
import AmgiTheme
import AmgiAppCore
#if canImport(UIKit)
import UIKit
#endif

/// What the notes/cards list is scoped to.
///
/// One value covers every sidebar section so a single `List(selection:)`
/// drives them. The previous split — a `DeckID?` binding for decks, direct
/// `model.activeTag` writes for tags, and a fire-and-forget query assignment
/// for saved searches — meant tags and saved searches never highlighted and
/// the three could contradict each other.
enum BrowseSource: Hashable {
    case allDecks
    case deck(DeckID)
    case tag(String)
    case untagged
    case saved(String)
    case flag(UInt32)
    case cardState(BrowseModelStateColor)
    case today(String)
    case notetype(String)

    /// Prefix for sidebar tag drag payloads so the list drop target can
    /// distinguish them from other strings.
    static let tagDragPrefix = "amgi-tag:"

    /// Grammar fragment this source contributes to `buildQuery()`, or nil
    /// for the unscoped collection (`allDecks` → `deck:*` at assemble time).
    func queryFragment(deckName: String? = nil, savedQuery: String? = nil) -> String? {
        switch self {
        case .allDecks:
            return nil
        case .deck:
            return deckName.map(DeckSearch.term)
        case .tag(let tag):
            return Self.quoted("tag", tag)
        case .untagged:
            return "tag:none"
        case .saved:
            return savedQuery.map { "( \($0) )" }
        case .flag(let value):
            return "flag:\(value & 0b111)"
        case .cardState(let state):
            return state.searchFragment
        case .today(let fragment):
            return fragment
        case .notetype(let name):
            return Self.quoted("note", name)
        }
    }

    private static func quoted(_ prefix: String, _ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\(prefix):\"\(escaped)\""
    }
}

/// Where Browse hands the window back on macOS. Browse replaces the root
/// sidebar while it's active, so the way out lives in its own sidebar header.
package struct BrowseExit {
    package let title: String
    package let systemImage: String
    package let action: () -> Void

    package init(title: String, systemImage: String, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }
}

/// Leading column: saved searches, today, decks, flags, card state, note
/// types, and tags — Mail's mailbox list plus Anki's sidebar scopes.
///
/// The deck tree is collapsible and defaults to collapsed (desktop Anki
/// parity). Flattening, parent resolution and search filtering live in
/// `BrowseDeckTree` so compact and regular share expansion and filtering.
struct BrowseSourceColumn: View {
    @Environment(\.palette) private var palette
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Bindable var model: BrowseModel
    let exit: BrowseExit?
    /// Batch selection for sidebar tag apply/remove. Nil on hosts without
    /// selection (compact landing); those rows hide the selection actions.
    var selection: BrowseSelectionState?
    var onSelectSource: (() -> Void)? = nil
    var onPresentSheet: ((BrowseView.Sheet, Set<NoteID>, Set<CardID>) -> Void)? = nil
    var onPresentTagSheet: ((Set<NoteID>, Set<CardID>) -> Void)? = nil
    /// Opens a note from an expanded group's search hits.
    var onOpenNote: ((Int64) -> Void)? = nil
    /// Collection mutation generation so presence glyphs refresh after
    /// suspend/bury/flag from the sidebar or list.
    var collectionGeneration: Int = 0

    /// Resolved deck-icon names (same synced overrides Library/Study use).
    @State private var iconNames: [Int64: String] = [:]

    /// Expanded deck full-names, newline-joined. `@AppStorage` can't hold a
    /// Set, and the joined form keeps the preference readable. Shared with
    /// the compact landing via `BrowseDeckTree.expandedStorageKey`.
    @AppStorage(BrowseDeckTree.expandedStorageKey) private var expandedRaw = ""
    @State private var tagRenameFrom: String?
    @State private var tagRenameTo = ""
    @State private var tagReparent: String?
    @State private var tagReparentParent = ""
    @State private var deckRenameID: DeckID?
    @State private var deckRenameTo = ""
    @State private var deckReparentID: DeckID?
    @State private var deckReparentParent = ""
    @State private var flagLabels = FlagLabelStore()
    @State private var renameFlag: UInt32?
    @State private var renameFlagTo = ""
    @State private var savedRenameFrom: String?
    @State private var savedRenameTo = ""
    @State private var confirmTitle = ""
    @State private var confirmMessage = ""
    @State private var confirmDestructive = false
    @State private var pendingBatch: PendingBatchAction?
    @State private var showBatchConfirm = false
    /// Groups opened with their search chevron while the field has text.
    @State private var expandedResults: Set<BrowseSource> = []
    @State private var groupResults: [BrowseSource: BrowseModel.GroupResults] = [:]

    var body: some View {
        List(selection: sourceSelection) {
            if let exit {
                Section {
                    exitRow(exit)
                }
                .selectionDisabled()
            }

            if !savedRows.isEmpty {
                Section("Saved Searches") {
                    ForEach(savedRows) { saved in
                        treeRow(.saved(saved.name)) {
                            Label(saved.name, systemImage: "heart")
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .tag(BrowseSource.saved(saved.name))
                        .contextMenu {
                            Button("Rename…") {
                                savedRenameFrom = saved.name
                                savedRenameTo = saved.name
                            }
                            Button("Delete saved search…", role: .destructive) {
                                presentConfirm(
                                    "Delete “\(saved.name)”?",
                                    "Notes are not deleted.",
                                    true
                                ) {
                                    model.deleteSavedSearch(named: saved.name)
                                }
                            }
                            sourceActionMenus(.saved(saved.name))
                        }
                        groupResultRows(.saved(saved.name))
                    }
                }
            }

            if !todayRows.isEmpty {
                Section("Today") {
                    ForEach(todayRows) { node in
                        treeRow(.today(node.fragment)) {
                            Label(node.title, systemImage: node.systemImage)
                        }
                        .tag(BrowseSource.today(node.fragment))
                        .contextMenu {
                            sourceActionMenus(.today(node.fragment))
                        }
                        groupResultRows(.today(node.fragment))
                    }
                }
            }

            if showsAllDecksRow || !deckRows.isEmpty {
                Section("Decks") {
                    if showsAllDecksRow {
                        treeRow(.allDecks) {
                            Label("All decks", systemImage: "square.stack.3d.up.fill")
                        }
                        .tag(BrowseSource.allDecks)
                        groupResultRows(.allDecks)
                    }
                    ForEach(deckRows) { row in
                        let source = BrowseSource.deck(row.deck.id)
                        treeRow(
                            source,
                            depth: row.depth + deckIndentBase,
                            children: row.hasChildren ? .init(
                                isOpen: row.isExpanded,
                                toggle: { toggleExpansion(row.deck.name) }
                            ) : nil
                        ) {
                            BrowseDeckRowLabel(
                                row: row,
                                iconName: iconNames[row.deck.id.rawValue],
                                presence: model.deckPresence[row.deck.id] ?? .empty
                            )
                        }
                        .tag(source)
                        .contextMenu {
                            deckManagement(row)
                            sourceActionMenus(source, includeSubdecks: true)
                        }
                        groupResultRows(source, depth: row.depth + deckIndentBase, ownOnly: row.hasChildren)
                    }
                }
            }

            if !flagRows.isEmpty {
                Section("Flags") {
                    ForEach(flagRows) { node in
                        treeRow(flagSource(node)) {
                            Label {
                                Text(flagTitle(node))
                                    .lineLimit(1)
                            } icon: {
                                Image(systemName: node.systemImage)
                                    .symbolRenderingMode(.monochrome)
                                    .foregroundStyle(flagRowColor(node))
                            }
                        }
                        .listItemTint(.fixed(flagRowColor(node)))
                        .tag(flagSource(node))
                        .contextMenu {
                            if let number = flagNumber(node), number != 0 {
                                Button("Rename flag label…") {
                                    renameFlag = number
                                    renameFlagTo = flagLabels.label(for: number)
                                }
                            }
                            sourceActionMenus(flagSource(node))
                        }
                        groupResultRows(flagSource(node))
                    }
                }
            }

            if !cardStateRows.isEmpty {
                Section("Card State") {
                    ForEach(cardStateRows) { node in
                        treeRow(stateSource(node)) {
                            Label {
                                Text(node.title)
                            } icon: {
                                Image(systemName: node.systemImage)
                                    .foregroundStyle(stateRowColor(node))
                            }
                        }
                        .tag(stateSource(node))
                        .contextMenu {
                            sourceActionMenus(stateSource(node))
                        }
                        groupResultRows(stateSource(node))
                    }
                }
            }

            if !notetypeRows.isEmpty {
                Section("Note Types") {
                    ForEach(notetypeRows, id: \.self) { name in
                        treeRow(.notetype(name)) {
                            Label(name, systemImage: "doc.text")
                                .lineLimit(1)
                        }
                        .tag(BrowseSource.notetype(name))
                        .contextMenu {
                            sourceActionMenus(.notetype(name))
                        }
                        groupResultRows(.notetype(name))
                    }
                }
            }

            if showsUntaggedRow || !tagRows.isEmpty {
                Section("Tags") {
                    if showsUntaggedRow {
                        treeRow(.untagged) {
                            Label("Untagged", systemImage: "tag.slash")
                        }
                        .tag(BrowseSource.untagged)
                        .contextMenu {
                            sourceActionMenus(.untagged)
                        }
                        groupResultRows(.untagged)
                    }
                    ForEach(tagRows, id: \.fullPath) { node in
                        let source = BrowseSource.tag(node.fullPath)
                        treeRow(
                            source,
                            depth: node.depth,
                            children: node.hasChildren ? .init(
                                isOpen: !node.isCollapsed,
                                toggle: { Task { await model.toggleTagCollapsed(node.fullPath) } }
                            ) : nil
                        ) {
                            HStack(spacing: 6) {
                                Label {
                                    Text(node.leaf)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                } icon: {
                                    Image(systemName: "tag")
                                }
                                .help(node.fullPath)
                                Spacer(minLength: 4)
                                BrowsePresenceGlyphs(presence: model.tagPresence[node.fullPath] ?? .empty)
                            }
                        }
                        .tag(source)
                        .draggable(BrowseSource.tagDragPrefix + node.fullPath)
                        .contextMenu {
                            if selection != nil {
                                Button("Add to selected notes") {
                                    guard let selection else { return }
                                    Task {
                                        await model.addSidebarTagToSelection(
                                            node.fullPath,
                                            noteIDs: selection.selectedNoteIDs,
                                            cardIDs: selection.selectedCardIDs
                                        )
                                    }
                                }
                                .disabled(selection?.isEmpty == true)
                                Button("Remove from selected notes") {
                                    guard let selection else { return }
                                    Task {
                                        await model.removeSidebarTagFromSelection(
                                            node.fullPath,
                                            noteIDs: selection.selectedNoteIDs,
                                            cardIDs: selection.selectedCardIDs
                                        )
                                    }
                                }
                                .disabled(selection?.isEmpty == true)
                                Divider()
                            }
                            Button("Rename…") {
                                tagRenameFrom = node.fullPath
                                tagRenameTo = node.fullPath
                            }
                            Button("Move under…") {
                                tagReparent = node.fullPath
                                tagReparentParent = ""
                            }
                            Button("Delete tag…", role: .destructive) {
                                Task { await model.deleteCollectionTag(node.fullPath) }
                            }
                            sourceActionMenus(source)
                        }
                        groupResultRows(source, depth: node.depth, ownOnly: node.hasChildren)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        #if os(iOS)
        // Mail-style: scrolling or tapping the list puts the keyboard away;
        // the search text stays.
        .scrollDismissesKeyboard(.immediately)
        .background(KeyboardDismissOnTap())
        #endif
        .task(id: ResultsKey(text: trimmedSearch, open: openResultSources)) {
            await loadGroupResults()
        }
        .task(id: presenceIdentity) {
            await model.refreshSourcePresence(
                decks: deckRows.map(\.deck),
                tags: tagRows.map(\.fullPath)
            )
        }
        .task {
            flagLabels.refresh()
        }
        .task(id: model.allDecks.map(\.id)) {
            iconNames = await BrowseDeckTree.loadIconNames(for: model.allDecks)
        }
        .alert("Rename tag", isPresented: Binding(
            get: { tagRenameFrom != nil },
            set: { if !$0 { tagRenameFrom = nil } }
        )) {
            TextField("Name", text: $tagRenameTo)
            Button("Rename") {
                if let from = tagRenameFrom { Task { await model.renameSidebarTag(from: from, to: tagRenameTo) } }
                tagRenameFrom = nil
            }
            Button("Cancel", role: .cancel) { tagRenameFrom = nil }
        }
        .alert("Rename deck", isPresented: Binding(
            get: { deckRenameID != nil },
            set: { if !$0 { deckRenameID = nil } }
        )) {
            TextField("Name", text: $deckRenameTo)
            Button("Rename") {
                if let id = deckRenameID { Task { await model.renameDeck(id: id, to: deckRenameTo) } }
                deckRenameID = nil
            }
            Button("Cancel", role: .cancel) { deckRenameID = nil }
        }
        .alert("Move tag under…", isPresented: Binding(
            get: { tagReparent != nil },
            set: { if !$0 { tagReparent = nil } }
        )) {
            TextField("New parent (empty = top level)", text: $tagReparentParent)
            Button("Move") {
                if let tag = tagReparent { Task { await model.reparentTag(tag, under: tagReparentParent) } }
                tagReparent = nil
            }
            Button("Cancel", role: .cancel) { tagReparent = nil }
        } message: {
            Text("Moves “\(tagReparent ?? "")” and its children.")
        }
        .alert("Move deck under…", isPresented: Binding(
            get: { deckReparentID != nil },
            set: { if !$0 { deckReparentID = nil } }
        )) {
            TextField("New parent (empty = top level)", text: $deckReparentParent)
            Button("Move") {
                if let id = deckReparentID { Task { await model.reparentDeck(id: id, under: deckReparentParent) } }
                deckReparentID = nil
            }
            Button("Cancel", role: .cancel) { deckReparentID = nil }
        }
        .alert("Rename flag label", isPresented: Binding(
            get: { renameFlag != nil },
            set: { if !$0 { renameFlag = nil } }
        )) {
            TextField("Name", text: $renameFlagTo)
            Button("Save") {
                if let flag = renameFlag { flagLabels.rename(flag: flag, to: renameFlagTo) }
                renameFlag = nil
            }
            Button("Cancel", role: .cancel) { renameFlag = nil }
        }
        .alert("Rename saved search", isPresented: Binding(
            get: { savedRenameFrom != nil },
            set: { if !$0 { savedRenameFrom = nil } }
        )) {
            TextField("Name", text: $savedRenameTo)
            Button("Rename") {
                if let from = savedRenameFrom {
                    _ = model.renameSavedSearch(from: from, to: savedRenameTo)
                }
                savedRenameFrom = nil
            }
            Button("Cancel", role: .cancel) { savedRenameFrom = nil }
        }
        .confirmationDialog(
            confirmTitle,
            isPresented: $showBatchConfirm,
            titleVisibility: .visible
        ) {
            Button(confirmDestructive ? "Delete" : "Apply", role: confirmDestructive ? .destructive : nil) {
                let work = pendingBatch
                pendingBatch = nil
                Task { await work?.run() }
            }
            Button("Cancel", role: .cancel) { pendingBatch = nil }
        } message: {
            Text(confirmMessage)
        }
    }

    /// Sidebar highlight is for a persistent column (iPad regular / Mac).
    /// Compact stacks the columns, so a selected row both tints the source
    /// and auto-pushes the notes list — iPhone should land on the tree.
    private var highlightsCurrentSource: Bool {
        #if os(iOS)
        horizontalSizeClass == .regular
        #else
        true
        #endif
    }

    /// Compact reports `nil` so the row is not highlighted; the model still
    /// keeps a source. Set never accepts nil: deselecting every row would
    /// leave the list column scoped to nothing.
    private var sourceSelection: Binding<BrowseSource?> {
        Binding(
            get: { highlightsCurrentSource ? model.source : nil },
            set: {
                if let new = $0 {
                    model.source = new
                    onSelectSource?()
                }
            }
        )
    }

    // MARK: - Group search results
    //
    // While the field has text, every row still on screen gets a chevron.
    // Opening it lists that group's direct hits, then notes close in
    // meaning (Suggested). Tapping the row itself still opens the full list.

    private func hasChildren(_ source: BrowseSource) -> Bool {
        switch source {
        case .deck(let id): deckRows.first { $0.deck.id == id }?.hasChildren ?? false
        case .tag(let path): tagRows.first { $0.fullPath == path }?.hasChildren ?? false
        default: false
        }
    }

    private var trimmedSearch: String {
        model.searchText.trimmingCharacters(in: .whitespaces)
    }

    private var isSearching: Bool { !trimmedSearch.isEmpty }

    private struct ResultsKey: Equatable {
        let text: String
        let open: Set<BrowseSource>
    }

    /// A row's own children (subdecks, child tags) and their open state.
    /// The same chevron opens them and, while searching, the row's notes.
    struct TreeChildren {
        let isOpen: Bool
        let toggle: () -> Void
    }

    private static let indentStep: CGFloat = 16

    /// Decks sit one step under "All decks" (not folded into it — it is a
    /// scope, not a parent row). Sheets scoped to one deck have no "All
    /// decks" row, so their tree starts at the margin.
    private var deckIndentBase: Int { showsAllDecksRow ? 1 : 0 }
    /// The chevron sits flush right in this slot, which hangs left of the
    /// icon: its glyph lands just right of the middle of the row's leading
    /// margin, close to the icon without crowding it.
    private static let chevronSlot: CGFloat = 14

    /// The one row layout every section uses. The chevron hangs in the
    /// row's leading margin, left of the icon, so icons and titles line up
    /// with the flat sections at depth 0 and nothing shifts when a chevron
    /// appears. Children indent one step per depth.
    private func treeRow<Content: View>(
        _ source: BrowseSource,
        depth: Int = 0,
        children: TreeChildren? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(.leading, CGFloat(depth) * Self.indentStep)
            .overlay(alignment: .leading) {
                if children != nil || isSearching {
                    chevron(source, children: children)
                        .offset(x: CGFloat(depth) * Self.indentStep - Self.chevronSlot - 4)
                }
            }
    }

    @ViewBuilder
    private func chevron(_ source: BrowseSource, children: TreeChildren?) -> some View {
        if children != nil || isSearching {
            let open = isOpen(source, children: children)
            Button {
                withAnimation(.snappy) {
                    if let children {
                        children.toggle()
                    } else if open {
                        expandedResults.remove(source)
                    } else {
                        expandedResults.insert(source)
                    }
                }
            } label: {
                Image(systemName: "chevron.right")
                    .amgiFont(.micro)
                    .foregroundStyle(palette.textSecondary)
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .frame(width: Self.chevronSlot, height: 28, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(open ? "Collapse" : "Expand")
        }
    }

    /// Rows with children share their tree expansion; leaf rows only open
    /// while searching, to show their notes.
    private func isOpen(_ source: BrowseSource, children: TreeChildren?) -> Bool {
        children?.isOpen ?? expandedResults.contains(source)
    }

    /// Sources whose notes are on screen: open leaf rows plus open parents.
    private var openResultSources: Set<BrowseSource> {
        var open = expandedResults
        for row in deckRows where row.hasChildren && row.isExpanded {
            open.insert(.deck(row.deck.id))
        }
        for node in tagRows where node.hasChildren && !node.isCollapsed {
            open.insert(.tag(node.fullPath))
        }
        return open
    }

    /// Reloads every open group for the current text. Closing the field
    /// collapses them all.
    private func loadGroupResults() async {
        guard isSearching else {
            expandedResults = []
            groupResults = [:]
            return
        }
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled else { return }
        let open = openResultSources
        // Old results stay up until new ones land: no spinner on every keystroke.
        groupResults = groupResults.filter { open.contains($0.key) }
        let own = Dictionary(uniqueKeysWithValues: open.map { ($0, hasChildren($0)) })
        let model = model
        await withTaskGroup(of: (BrowseSource, BrowseModel.GroupResults).self) { group in
            for source in open {
                group.addTask {
                    (source, await model.groupDirect(for: source, excludingChildren: own[source] ?? false))
                }
            }
            for await (source, results) in group where !Task.isCancelled {
                groupResults[source] = results
            }
        }
        guard !Task.isCancelled else { return }
        await withTaskGroup(of: (BrowseSource, [(Int64, NoteRecord)]).self) { group in
            for source in open {
                let direct = groupResults[source]?.allDirect ?? []
                group.addTask {
                    (source, await model.groupSuggestions(
                        for: source,
                        excludingChildren: own[source] ?? false,
                        excluding: direct
                    ))
                }
            }
            for await (source, suggested) in group where !Task.isCancelled {
                guard var results = groupResults[source] else { continue }
                results.suggestedIDs = suggested.map(\.0)
                for (id, note) in suggested { results.records[id] = note }
                groupResults[source] = results
            }
        }
    }

    /// A parent's notes exclude its children's (they sit under the child
    /// rows); a leaf shows everything it holds.
    @ViewBuilder
    private func groupResultRows(_ source: BrowseSource, depth: Int = 0, ownOnly: Bool = false) -> some View {
        if isSearching, openResultSources.contains(source) {
            let inset = CGFloat(depth + 1) * Self.indentStep
            if let results = groupResults[source] {
                if results.directIDs.isEmpty && results.suggestedIDs.isEmpty && !ownOnly {
                    Text("No matching notes")
                        .amgiFont(.caption)
                        .foregroundStyle(palette.textSecondary)
                        .padding(.leading, inset)
                        .selectionDisabled()
                }
                ForEach(results.directIDs, id: \.self) { id in
                    if let note = results.records[id] {
                        noteResultRow(note, inset: inset)
                    }
                }
                if results.directCount > results.directIDs.count {
                    Button {
                        model.source = source
                        onSelectSource?()
                    } label: {
                        Text(L10n.format("Show All %@", [results.directCount.formatted()]))
                            .amgiFont(.caption)
                            .foregroundStyle(palette.accent)
                            .padding(.leading, inset)
                    }
                    .buttonStyle(.plain)
                    .selectionDisabled()
                }
                if !results.suggestedIDs.isEmpty {
                    Text("Suggested")
                        .amgiFont(.micro)
                        .textCase(.uppercase)
                        .foregroundStyle(palette.textSecondary)
                        .padding(.leading, inset)
                        .selectionDisabled()
                    ForEach(results.suggestedIDs, id: \.self) { id in
                        if let note = results.records[id] {
                            noteResultRow(note, inset: inset)
                        }
                    }
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, inset)
                    .selectionDisabled()
            }
        }
    }

    private func noteResultRow(_ note: NoteRecord, inset: CGFloat) -> some View {
        Button {
            onOpenNote?(note.id.rawValue)
        } label: {
            NoteRowView(note: note, notetypeName: model.notetypeNames[note.mid])
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, inset)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .selectionDisabled()
    }

    // MARK: - Rows

    private func exitRow(_ exit: BrowseExit) -> some View {
        Button(action: exit.action) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left")
                    .amgiFont(.micro)
                Label(exit.title, systemImage: exit.systemImage)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(palette.textSecondary)
        .help("Back to \(exit.title)")
    }

    private func flagRowColor(_ node: FilterNode) -> Color {
        if case .flag(let value) = node.role, let color = BrowseFlagSwatch.color(for: value) {
            return color
        }
        return palette.textTertiary
    }

    private func flagTitle(_ node: FilterNode) -> String {
        if let number = flagNumber(node), number != 0 {
            return flagLabels.label(for: number)
        }
        return node.title
    }

    private func flagNumber(_ node: FilterNode) -> UInt32? {
        if case .flag(let value) = node.role { return value }
        if node.fragment == "flag:0" { return 0 }
        return nil
    }

    private func flagSource(_ node: FilterNode) -> BrowseSource {
        .flag(flagNumber(node) ?? 0)
    }

    private func stateSource(_ node: FilterNode) -> BrowseSource {
        if case .state(let state) = node.role { return .cardState(state) }
        return .cardState(.review)
    }

    private func stateRowColor(_ node: FilterNode) -> Color {
        guard case .state(let state) = node.role else { return palette.textSecondary }
        return switch state {
        case .newState: palette.cardStateNew
        case .learning: palette.cardStateLearning
        case .review: palette.cardStateReview
        case .suspended: palette.cardStateSuspended
        case .buried: palette.warning
        }
    }

    @ViewBuilder
    private func deckManagement(_ row: BrowseDeckTree.Row) -> some View {
        Button("Expand descendants") { setDescendants(of: row.deck.name, expanded: true) }
        Button("Collapse descendants") { setDescendants(of: row.deck.name, expanded: false) }
        Divider()
        Button("Rename…") {
            deckRenameID = row.deck.id
            deckRenameTo = row.deck.name
        }
        Button("Move under…") {
            deckReparentID = row.deck.id
            deckReparentParent = ""
        }
    }

    @ViewBuilder
    private func sourceActionMenus(_ source: BrowseSource, includeSubdecks: Bool = true) -> some View {
        BrowseSourceCompositionMenu(source: source, model: model)
        BrowseSourceBatchMenu(
            source: source,
            includeSubdecks: includeSubdecks,
            model: model,
            onPresentSheet: presentSheet,
            onPresentTagSheet: presentTagSheet,
            onConfirm: presentConfirm
        )
        if case .deck = source, includeSubdecks {
            Menu("This deck only") {
                BrowseSourceBatchMenu(
                    source: source,
                    includeSubdecks: false,
                    model: model,
                    onPresentSheet: presentSheet,
                    onPresentTagSheet: presentTagSheet,
                    onConfirm: presentConfirm
                )
            }
        }
    }

    private func presentSheet(_ sheet: BrowseView.Sheet, _ notes: Set<NoteID>, _ cards: Set<CardID>) {
        onPresentSheet?(sheet, notes, cards)
    }

    private func presentTagSheet(_ notes: Set<NoteID>, _ cards: Set<CardID>) {
        onPresentTagSheet?(notes, cards)
    }

    private func presentConfirm(
        _ title: String,
        _ message: String,
        _ destructive: Bool,
        _ work: @escaping () async -> Void
    ) {
        confirmTitle = title
        confirmMessage = message
        confirmDestructive = destructive
        pendingBatch = PendingBatchAction(work)
        showBatchConfirm = true
    }

    // MARK: - Expansion

    private var expanded: Set<String> {
        BrowseDeckTree.expandedSet(from: expandedRaw)
    }

    private func toggleExpansion(_ name: String) {
        var set = expanded
        if set.contains(name) {
            set.remove(name)
        } else {
            set.insert(name)
        }
        expandedRaw = BrowseDeckTree.raw(from: set)
    }

    // MARK: - Deck tree

    private var deckRows: [BrowseDeckTree.Row] {
        BrowseDeckTree.rows(
            decks: model.availableDecks,
            expanded: expanded,
            filterTokens: sidebarTokens,
            resultDeckIDs: model.resultDeckIDs
        )
    }

    private var sidebarTokens: [String] {
        BrowseDeckTree.filterTokens(from: model.searchText)
    }

    // MARK: - Filtered sections
    //
    // The field filters every section, not just decks and tags. A section
    // with no matching row disappears while filtering, like Mail's sidebar.

    private func titleMatches(_ titles: String...) -> Bool {
        let tokens = sidebarTokens
        guard !tokens.isEmpty else { return true }
        return titles.contains { BrowseDeckTree.nameMatches($0, tokens: tokens) }
    }

    private var savedRows: [SavedSearchStore.SavedSearch] {
        model.savedSearches.searches.filter { titleMatches($0.name, $0.query) }
    }

    private var todayRows: [FilterNode] {
        BrowseFilterSections.today().filter { titleMatches($0.title) }
    }

    private var flagRows: [FilterNode] {
        BrowseFilterSections.flags().filter { titleMatches(flagTitle($0)) }
    }

    private var cardStateRows: [FilterNode] {
        BrowseFilterSections.cardStates().filter { titleMatches($0.title) }
    }

    private var notetypeRows: [String] {
        Array(model.notetypeNames.values).sorted().filter { titleMatches($0) }
    }

    /// Never filtered out: while searching it is the way into the results
    /// (Matches, then Suggested) for the whole collection.
    private var showsAllDecksRow: Bool {
        model.rootDeck == nil
    }

    private var showsUntaggedRow: Bool {
        titleMatches(L10n.text("Untagged"))
    }

    private struct TagRow {
        let fullPath: String
        let leaf: String
        let depth: Int
        let hasChildren: Bool
        let isCollapsed: Bool
    }

    /// Hierarchical tags (`::`-nested, desktop parity) instead of flat
    /// full-name labels. Depth indents; leaf shows the last component.
    private var tagRows: [TagRow] {
        let tokens = sidebarTokens
        func matches(_ path: String) -> Bool {
            tokens.isEmpty || BrowseDeckTree.nameMatches(path, tokens: tokens)
        }
        func subtreeMatches(_ node: TagTreeNodeData) -> Bool {
            matches(node.fullPath) || node.children.contains(where: subtreeMatches)
        }
        var rows: [TagRow] = []
        // Same rule as decks: a match under a closed parent is reached by
        // opening the parent; `hasChildren` counts only children still shown.
        func walk(_ nodes: [TagTreeNodeData]) {
            for node in nodes where subtreeMatches(node) {
                let depth = node.fullPath.split(separator: "::").count - 1
                rows.append(TagRow(
                    fullPath: node.fullPath,
                    leaf: node.name,
                    depth: max(0, depth),
                    hasChildren: node.children.contains(where: subtreeMatches),
                    isCollapsed: node.collapsed
                ))
                if !node.collapsed { walk(node.children) }
            }
        }
        if let tree = model.tagTree {
            walk(tree.children)
        } else {
            // Fallback while the tree loads: flat rows, but hierarchy-aware —
            // indented leaves with the full path on hover. (No synthetic
            // parents: a parent with no notes of its own would scope to an
            // empty result set.)
            for tag in visibleTags {
                let depth = tag.split(separator: "::").count - 1
                rows.append(TagRow(
                    fullPath: tag,
                    leaf: String(tag.split(separator: "::").last ?? Substring(tag)),
                    depth: max(0, depth),
                    hasChildren: false,
                    isCollapsed: false
                ))
            }
        }
        return rows
    }

    private var visibleTags: [String] {
        BrowseDeckTree.visibleTags(
            model.allTags,
            tokens: sidebarTokens
        )
    }

    /// Visible deck/tag keys plus collection generation — expanding a
    /// parent or a mass mutation both restart the presence scan.
    private var presenceIdentity: String {
        let decks = deckRows.map { String($0.deck.id.rawValue) }.joined(separator: ",")
        let tags = tagRows.map(\.fullPath).joined(separator: "\u{1e}")
        return "\(collectionGeneration)|\(decks)|\(tags)"
    }

    private func setDescendants(of name: String, expanded: Bool) {
        var set = self.expanded
        let prefix = name + "::"
        for deck in model.availableDecks.map(\.name) where deck.hasPrefix(prefix) {
            if expanded { set.insert(deck) } else { set.remove(deck) }
        }
        if expanded { set.insert(name) } else { set.remove(name) }
        expandedRaw = BrowseDeckTree.raw(from: set)
    }
}

@MainActor
private final class PendingBatchAction {
    let run: () async -> Void
    init(_ run: @escaping () async -> Void) {
        self.run = run
    }
}

#if os(iOS)
/// Puts the keyboard away when the user taps the sidebar list, without
/// taking the tap: the recognizer never cancels or delays touches and
/// recognizes alongside everything else, so rows, chevrons and buttons still
/// get their taps. (A SwiftUI tap gesture on the List swallows selection; one
/// on the window closed the search before a suggestion's tap landed.)
private struct KeyboardDismissOnTap: UIViewRepresentable {
    func makeUIView(context: Context) -> Anchor { Anchor() }
    func updateUIView(_ uiView: Anchor, context: Context) {}

    final class Anchor: UIView, UIGestureRecognizerDelegate {
        private lazy var recognizer: UITapGestureRecognizer = {
            let tap = UITapGestureRecognizer(target: self, action: #selector(dismiss))
            tap.cancelsTouchesInView = false
            tap.delaysTouchesBegan = false
            tap.delaysTouchesEnded = false
            tap.delegate = self
            return tap
        }()

        /// Installed on the List's own scroll view, not the window: a tap
        /// on a search suggestion (shown in a separate view) must reach the
        /// suggestion, not close the search first.
        override func didMoveToWindow() {
            super.didMoveToWindow()
            recognizer.view?.removeGestureRecognizer(recognizer)
            guard window != nil else { return }
            // The List lays out after this view joins the window.
            DispatchQueue.main.async { [weak self] in
                guard let self, let list = self.siblingScrollView() else { return }
                list.addGestureRecognizer(self.recognizer)
            }
        }

        override func removeFromSuperview() {
            recognizer.view?.removeGestureRecognizer(recognizer)
            super.removeFromSuperview()
        }

        /// The scroll view this background sits behind: the nearest one,
        /// under a shared ancestor, that covers this view's frame.
        private func siblingScrollView() -> UIScrollView? {
            guard let window else { return nil }
            let target = convert(bounds, to: window)
            var ancestor = superview
            while let container = ancestor {
                if let found = Self.scrollView(in: container, covering: target, window: window, depth: 0) {
                    return found
                }
                ancestor = container.superview
            }
            return nil
        }

        private static func scrollView(
            in view: UIView, covering target: CGRect, window: UIWindow, depth: Int
        ) -> UIScrollView? {
            guard depth < 12 else { return nil }
            for subview in view.subviews {
                if let scroll = subview as? UIScrollView {
                    let frame = scroll.convert(scroll.bounds, to: window)
                    if frame.intersection(target).width >= target.width * 0.9 { return scroll }
                }
                if let found = scrollView(in: subview, covering: target, window: window, depth: depth + 1) {
                    return found
                }
            }
            return nil
        }

        @objc private func dismiss() {
            window?.endEditing(true)
        }

        /// Taps on a text input keep the keyboard (moving the caret, the
        /// search field itself).
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var view = touch.view
            while let current = view {
                if current is UITextField || current is UITextView || current is UISearchBar { return false }
                view = current.superview
            }
            return true
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool { true }
    }
}
#endif

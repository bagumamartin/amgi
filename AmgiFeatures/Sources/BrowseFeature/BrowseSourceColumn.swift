// AmgiApp/Sources/Browse/BrowseSourceColumn.swift
import SwiftUI
import AmgiUI
import AnkiKit
import AmgiTheme

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

/// Leading column: saved searches, today, flags, card state, decks, note
/// types, and tags — Mail's mailbox list plus Anki's sidebar scopes.
///
/// The deck tree is collapsible and defaults to collapsed (desktop Anki
/// parity). Flattening, parent resolution and search filtering live in
/// `BrowseDeckTree` so compact and regular share expansion and filtering.
struct BrowseSourceColumn: View {
    @Environment(\.palette) private var palette
    @Bindable var model: BrowseModel
    let exit: BrowseExit?
    /// Batch selection for sidebar tag apply/remove. Nil on hosts without
    /// selection (compact landing); those rows hide the selection actions.
    var selection: BrowseSelectionState?
    var onSelectSource: (() -> Void)? = nil
    var onPresentSheet: ((BrowseView.Sheet, Set<NoteID>, Set<CardID>) -> Void)? = nil
    var onPresentTagSheet: ((Set<NoteID>, Set<CardID>) -> Void)? = nil

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

    var body: some View {
        List(selection: sourceSelection) {
            if let exit {
                Section {
                    exitRow(exit)
                }
                .selectionDisabled()
            }

            if !model.savedSearches.searches.isEmpty {
                Section("Saved Searches") {
                    ForEach(model.savedSearches.searches) { saved in
                        Label(saved.name, systemImage: "heart")
                            .lineLimit(1)
                            .truncationMode(.tail)
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
                    }
                }
            }

            Section("Today") {
                ForEach(BrowseFilterSections.today()) { node in
                    Label(node.title, systemImage: node.systemImage)
                        .tag(BrowseSource.today(node.fragment))
                        .contextMenu {
                            sourceActionMenus(.today(node.fragment))
                        }
                }
            }

            Section("Flags") {
                ForEach(BrowseFilterSections.flags()) { node in
                    Label {
                        Text(flagTitle(node))
                            .lineLimit(1)
                    } icon: {
                        Image(systemName: node.systemImage)
                            .symbolRenderingMode(.monochrome)
                            .foregroundStyle(flagRowColor(node))
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
                }
            }

            Section("Card State") {
                ForEach(BrowseFilterSections.cardStates()) { node in
                    Label {
                        Text(node.title)
                    } icon: {
                        Image(systemName: node.systemImage)
                            .foregroundStyle(stateRowColor(node))
                    }
                    .tag(stateSource(node))
                    .contextMenu {
                        sourceActionMenus(stateSource(node))
                    }
                }
            }

            Section("Decks") {
                if model.rootDeck == nil {
                    Label("All decks", systemImage: "square.stack.3d.up.fill")
                        .tag(BrowseSource.allDecks)
                }
                ForEach(deckRows) { row in
                    BrowseDeckRowLabel(row: row, iconName: iconNames[row.deck.id.rawValue]) {
                        toggleExpansion(row.deck.name)
                    }
                    .tag(BrowseSource.deck(row.deck.id))
                    .contextMenu {
                        deckManagement(row)
                        sourceActionMenus(.deck(row.deck.id), includeSubdecks: true)
                    }
                }
            }

            if !model.notetypeNames.isEmpty {
                Section("Note Types") {
                    ForEach(Array(model.notetypeNames.values).sorted(), id: \.self) { name in
                        Label(name, systemImage: "doc.text")
                            .lineLimit(1)
                            .tag(BrowseSource.notetype(name))
                            .contextMenu {
                                sourceActionMenus(.notetype(name))
                            }
                    }
                }
            }

            Section("Tags") {
                Label("Untagged", systemImage: "tag.slash")
                    .tag(BrowseSource.untagged)
                    .contextMenu {
                        sourceActionMenus(.untagged)
                    }
                ForEach(tagRows, id: \.fullPath) { node in
                    HStack(spacing: 6) {
                        if node.depth > 0 {
                            Color.clear.frame(width: CGFloat(node.depth) * 12, height: 4)
                        }
                        if node.hasChildren {
                            Button {
                                Task { await model.toggleTagCollapsed(node.fullPath) }
                            } label: {
                                Image(systemName: node.isCollapsed ? "chevron.right" : "chevron.down")
                                    .amgiFont(.micro)
                                    .foregroundStyle(palette.textSecondary)
                                    .frame(width: 12, height: 12)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(
                                node.isCollapsed
                                    ? "Expand \(node.fullPath)"
                                    : "Collapse \(node.fullPath)"
                            )
                        }
                        Label {
                            Text(node.leaf)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        } icon: {
                            Image(systemName: "tag")
                        }
                        .help(node.fullPath)
                    }
                    .tag(BrowseSource.tag(node.fullPath))
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
                        sourceActionMenus(.tag(node.fullPath))
                    }
                }
            }
        }
        .listStyle(.sidebar)
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

    /// Selection never clears to nil: deselecting every row would leave the
    /// list column scoped to nothing.
    private var sourceSelection: Binding<BrowseSource?> {
        Binding(
            get: { model.source },
            set: {
                if let new = $0 {
                    model.source = new
                    onSelectSource?()
                }
            }
        )
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
        var rows: [TagRow] = []
        func walk(_ nodes: [TagTreeNodeData]) {
            for node in nodes {
                if matches(node.fullPath) || node.children.contains(where: { matches($0.fullPath) }) {
                    let depth = node.fullPath.split(separator: "::").count - 1
                    rows.append(TagRow(
                        fullPath: node.fullPath,
                        leaf: node.name,
                        depth: max(0, depth),
                        hasChildren: !node.children.isEmpty,
                        isCollapsed: node.collapsed
                    ))
                    if !node.collapsed { walk(node.children) }
                }
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

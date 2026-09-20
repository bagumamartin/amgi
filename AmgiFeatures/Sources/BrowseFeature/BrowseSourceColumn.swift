// AmgiApp/Sources/Browse/BrowseSourceColumn.swift
import SwiftUI
import AmgiUI
import AnkiKit
import AmgiTheme

/// What the notes/cards list is scoped to.
///
/// One value covers all three sidebar sections so a single `List(selection:)`
/// drives them. The previous split — a `DeckID?` binding for decks, direct
/// `model.activeTag` writes for tags, and a fire-and-forget query assignment
/// for saved searches — meant tags and saved searches never highlighted and
/// the three could contradict each other.
enum BrowseSource: Hashable {
    case allDecks
    case deck(DeckID)
    case tag(String)
    case saved(String)
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

/// Leading column: deck tree, tags, and saved searches — Mail's mailbox list.
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

    var body: some View {
        List(selection: sourceSelection) {
            if let exit {
                Section {
                    exitRow(exit)
                }
                .selectionDisabled()
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
                }
            }

            if !visibleTags.isEmpty {
                Section("Tags") {
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
                        }
                    }
                }
            }

            Section("Flags") {
                ForEach(BrowseFilterSections.flags()) { node in
                    Button {
                        model.searchText = node.fragment
                    } label: {
                        Label {
                            Text(node.title)
                                .lineLimit(1)
                        } icon: {
                            Image(systemName: node.systemImage)
                                .symbolRenderingMode(.monochrome)
                                .foregroundStyle(flagRowColor(node))
                        }
                    }
                    .buttonStyle(.plain)
                    .listItemTint(.fixed(flagRowColor(node)))
                }
            }
            .selectionDisabled()

            if !model.savedSearches.searches.isEmpty {
                Section("Saved Searches") {
                    ForEach(model.savedSearches.searches) { saved in
                        Label(saved.name, systemImage: "heart")
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .tag(BrowseSource.saved(saved.name))
                    }
                }
            }
        }
        .listStyle(.sidebar)
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

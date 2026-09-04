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
struct BrowseExit {
    let title: String
    let systemImage: String
    let action: () -> Void
}

/// Leading column: deck tree, tags, and saved searches — Mail's mailbox list.
///
/// The deck tree is collapsible and defaults to collapsed (desktop Anki
/// parity). It used to be a flat list indented by depth, which meant every
/// subdeck of every deck was permanently on screen and truncated.
struct BrowseSourceColumn: View {
    @Environment(\.palette) private var palette
    @Bindable var model: BrowseModel
    let exit: BrowseExit?

    /// Resolved deck-icon names (same synced overrides Library/Study use).
    @State private var iconNames: [Int64: String] = [:]

    /// Expanded deck full-names, newline-joined. `@AppStorage` can't hold a
    /// Set, and the joined form keeps the preference readable.
    @AppStorage("browse.sidebar.expandedDecks") private var expandedRaw = ""

    var body: some View {
        List(selection: sourceSelection) {
            if let exit {
                Section {
                    exitRow(exit)
                }
                .selectionDisabled()
            }

            Section("Decks") {
                Label("All decks", systemImage: "square.stack.3d.up.fill")
                    .tag(BrowseSource.allDecks)
                ForEach(deckRows) { row in
                    deckRow(row)
                }
            }

            if !visibleTags.isEmpty {
                Section("Tags") {
                    ForEach(visibleTags, id: \.self) { tag in
                        Label(tag, systemImage: "tag")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .tag(BrowseSource.tag(tag))
                    }
                }
            }

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
            await loadDeckIcons()
        }
    }

    /// Selection never clears to nil: deselecting every row would leave the
    /// list column scoped to nothing.
    private var sourceSelection: Binding<BrowseSource?> {
        Binding(
            get: { model.source },
            set: { if let new = $0 { model.source = new } }
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

    private func deckRow(_ row: DeckRow) -> some View {
        let leaf = Self.leafName(row.deck.name)
        return HStack(spacing: 6) {
            disclosure(row)
            deckTile(leaf: leaf, deck: row.deck)
                .frame(width: 22, height: 22)
            Text(leaf)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if row.deck.counts.total > 0 {
                Text("\(row.deck.counts.total)")
                    .monospacedDigit()
                    .amgiFont(.caption)
                    .foregroundStyle(palette.textSecondary)
            }
        }
        .padding(.leading, CGFloat(row.depth) * 12)
        .tag(BrowseSource.deck(row.deck.id))
    }

    /// Manual chevron rather than `DisclosureGroup`: every row stays a plain
    /// selectable `List` row, so native selection and the compact-width push
    /// behave predictably.
    @ViewBuilder
    private func disclosure(_ row: DeckRow) -> some View {
        if row.hasChildren {
            Button {
                toggleExpansion(row.deck.name)
            } label: {
                Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                    .amgiFont(.micro)
                    .foregroundStyle(palette.textSecondary)
                    .frame(width: 12, height: 12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                row.isExpanded
                    ? "Collapse \(Self.leafName(row.deck.name))"
                    : "Expand \(Self.leafName(row.deck.name))"
            )
        } else {
            Color.clear.frame(width: 12, height: 12)
        }
    }

    /// The exact tile Library/Study use (`DeckIconTile`); emoji-named decks
    /// fall back to their emoji rendered inline at tile size.
    @ViewBuilder
    private func deckTile(leaf: String, deck: DeckInfo) -> some View {
        if let icon = iconNames[deck.id.rawValue] {
            DeckIconTile(
                iconName: icon, deckName: leaf,
                size: 22, cornerRadius: AmgiRadius.small
            )
        } else if DeckIconRendering.hasLeadingEmoji(in: leaf), let char = leaf.first {
            ZStack {
                RoundedRectangle(cornerRadius: AmgiRadius.small, style: .continuous)
                    .fill(palette.surfaceElevated)
                Text(String(char))
                    .amgiFont(.caption)
            }
        } else {
            Image(systemName: "books.vertical.fill")
                .foregroundStyle(palette.accent)
                .amgiFont(.caption)
        }
    }

    // MARK: - Expansion

    private var expanded: Set<String> {
        Set(expandedRaw.split(separator: "\n").map(String.init))
    }

    private func toggleExpansion(_ name: String) {
        var set = expanded
        if set.contains(name) {
            set.remove(name)
        } else {
            set.insert(name)
        }
        expandedRaw = set.sorted().joined(separator: "\n")
    }

    // MARK: - Deck tree

    struct DeckRow: Identifiable {
        let deck: DeckInfo
        let depth: Int
        let hasChildren: Bool
        let isExpanded: Bool
        var id: DeckID { deck.id }
    }

    private static func leafName(_ fullName: String) -> String {
        fullName.split(separator: "::").last.map(String.init) ?? fullName
    }

    /// Flattened list of the rows that should currently be on screen: roots
    /// plus the descendants of expanded decks, narrowed to search matches
    /// (and their ancestors) while the field has free text.
    private var deckRows: [DeckRow] {
        let decks = model.allDecks.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        guard !decks.isEmpty else { return [] }

        let names = Set(decks.map(\.name))
        var childrenByParent: [String: [DeckInfo]] = [:]
        var roots: [DeckInfo] = []
        for deck in decks {
            let parts = deck.name.split(separator: "::").map(String.init)
            var parent: String?
            if parts.count > 1 {
                // Nearest ancestor that actually exists. Anki materializes
                // parent decks, but a partially synced tree can be missing one
                // and its children must still appear somewhere.
                for drop in 1..<parts.count {
                    let candidate = parts.dropLast(drop).joined(separator: "::")
                    if names.contains(candidate) {
                        parent = candidate
                        break
                    }
                }
            }
            if let parent {
                childrenByParent[parent, default: []].append(deck)
            } else {
                roots.append(deck)
            }
        }

        // While searching, keep decks that name-match or hold matching cards,
        // plus their ancestors, and force the tree open so hits are reachable.
        let searching = !filterTokens.isEmpty
        var keep: Set<DeckID>?
        if searching {
            var kept: Set<DeckID> = []
            func mark(_ deck: DeckInfo) -> Bool {
                var hit = nameMatches(deck.name)
                    || model.resultDeckIDs.contains(deck.id.rawValue)
                for child in childrenByParent[deck.name] ?? [] where mark(child) {
                    hit = true
                }
                if hit { kept.insert(deck.id) }
                return hit
            }
            for root in roots { _ = mark(root) }
            keep = kept
        }

        let expandedNames = expanded
        var rows: [DeckRow] = []
        func walk(_ deck: DeckInfo, depth: Int) {
            if let keep, !keep.contains(deck.id) { return }
            let children = (childrenByParent[deck.name] ?? [])
                .filter { keep?.contains($0.id) ?? true }
            let isExpanded = searching || expandedNames.contains(deck.name)
            rows.append(DeckRow(
                deck: deck,
                depth: depth,
                hasChildren: !children.isEmpty,
                isExpanded: isExpanded
            ))
            guard isExpanded else { return }
            for child in children { walk(child, depth: depth + 1) }
        }
        for root in roots { walk(root, depth: 0) }
        return rows
    }

    // MARK: - Search-driven filtering

    /// Free-text tokens from the search field — grammar fragments
    /// (`deck:`, `tag:`, `is:`, …) are not name filters.
    private var filterTokens: [String] {
        let prefixes = ["deck:", "tag:", "is:", "due:", "added:", "edited:",
                        "rated:", "prop:", "nid:", "note:", "flag:", "introduced:"]
        return model.searchText.split(separator: " ")
            .map { $0.lowercased() }
            .filter { token in !prefixes.contains { token.hasPrefix($0) } }
    }

    private func nameMatches(_ name: String) -> Bool {
        let tokens = filterTokens
        if tokens.isEmpty { return true }
        let lowered = name.lowercased()
        return tokens.contains { lowered.contains($0) }
    }

    private var visibleTags: [String] {
        guard !filterTokens.isEmpty else { return model.allTags }
        return model.allTags.filter { nameMatches($0) }
    }

    // MARK: - Icons

    /// Resolve the same synced deck icons Library/Study render — manual
    /// picks first, then the first-writer-wins auto picks. Emoji-prefixed
    /// decks resolve to nil and render their emoji inline instead.
    private func loadDeckIcons() async {
        guard !model.allDecks.isEmpty else { return }
        await DeckIconOverrides.refresh()
        for deck in model.allDecks {
            let leaf = Self.leafName(deck.name)
            if let icon = await DeckIconOverrides.resolvedIcon(
                deckId: deck.id.rawValue, name: leaf, fullName: deck.name
            ) {
                iconNames[deck.id.rawValue] = icon
            }
        }
    }
}

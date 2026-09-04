// AmgiApp/Sources/Browse/BrowseDeckTree.swift
import SwiftUI
import AmgiAppShared
import AmgiUI
import AnkiKit
import AmgiTheme

/// Flattened, filterable deck tree shared by the Browse sidebar and the
/// compact Search landing. One expansion set (`expandedStorageKey`) so a
/// deck opened on iPhone stays open on iPad.
enum BrowseDeckTree {
    static let expandedStorageKey = "browse.sidebar.expandedDecks"

    struct Row: Identifiable {
        let deck: DeckInfo
        let depth: Int
        let hasChildren: Bool
        let isExpanded: Bool
        var id: DeckID { deck.id }
    }

    static func leafName(_ fullName: String) -> String {
        fullName.split(separator: "::").last.map(String.init) ?? fullName
    }

    static func expandedSet(from raw: String) -> Set<String> {
        Set(raw.split(separator: "\n").map(String.init))
    }

    static func raw(from expanded: Set<String>) -> String {
        expanded.sorted().joined(separator: "\n")
    }

    /// Free-text tokens from the search field — grammar fragments
    /// (`deck:`, `tag:`, `is:`, …) are not name filters.
    static func filterTokens(from searchText: String) -> [String] {
        let prefixes = ["deck:", "tag:", "is:", "due:", "added:", "edited:",
                        "rated:", "prop:", "nid:", "note:", "flag:", "introduced:"]
        return searchText.split(separator: " ")
            .map { $0.lowercased() }
            .filter { token in !prefixes.contains { token.hasPrefix($0) } }
    }

    static func nameMatches(_ name: String, tokens: [String]) -> Bool {
        if tokens.isEmpty { return true }
        let lowered = name.lowercased()
        return tokens.contains { lowered.contains($0) }
    }

    static func visibleTags(_ tags: [String], tokens: [String]) -> [String] {
        guard !tokens.isEmpty else { return tags }
        return tags.filter { nameMatches($0, tokens: tokens) }
    }

    /// Flattened list of the rows that should currently be on screen: roots
    /// plus the descendants of expanded decks, narrowed to search matches
    /// (and their ancestors) while the field has free text.
    static func rows(
        decks: [DeckInfo],
        expanded: Set<String>,
        filterTokens: [String],
        resultDeckIDs: Set<Int64>
    ) -> [Row] {
        let decks = decks.sorted {
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
                var hit = nameMatches(deck.name, tokens: filterTokens)
                    || resultDeckIDs.contains(deck.id.rawValue)
                for child in childrenByParent[deck.name] ?? [] where mark(child) {
                    hit = true
                }
                if hit { kept.insert(deck.id) }
                return hit
            }
            for root in roots { _ = mark(root) }
            keep = kept
        }

        var rows: [Row] = []
        func walk(_ deck: DeckInfo, depth: Int) {
            if let keep, !keep.contains(deck.id) { return }
            let children = (childrenByParent[deck.name] ?? [])
                .filter { keep?.contains($0.id) ?? true }
            let isExpanded = searching || expanded.contains(deck.name)
            rows.append(Row(
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

    /// Resolve the same synced deck icons Library/Study render — manual
    /// picks first, then the first-writer-wins auto picks. Emoji-prefixed
    /// decks resolve to nil and render their emoji inline instead.
    @MainActor
    static func loadIconNames(for decks: [DeckInfo]) async -> [Int64: String] {
        guard !decks.isEmpty else { return [:] }
        await DeckIconLookup.refresh?()
        var names: [Int64: String] = [:]
        for deck in decks {
            let leaf = leafName(deck.name)
            if let icon = await DeckIconLookup.resolvedIcon?(
                deck.id.rawValue, leaf, deck.name
            ) {
                names[deck.id.rawValue] = icon
            }
        }
        return names
    }
}

/// Disclosure chevron + icon tile + leaf name + optional count. Used by the
/// sidebar (which adds a selection tag) and the landing (which adds a tap).
struct BrowseDeckRowLabel: View {
    @Environment(\.palette) private var palette
    let row: BrowseDeckTree.Row
    let iconName: String?
    let onToggleExpand: () -> Void

    var body: some View {
        let leaf = BrowseDeckTree.leafName(row.deck.name)
        HStack(spacing: 6) {
            disclosure
            deckTile(leaf: leaf)
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
    }

    /// Manual chevron rather than `DisclosureGroup`: every row stays a plain
    /// `List` row, so native selection and the compact-width push behave
    /// predictably.
    @ViewBuilder
    private var disclosure: some View {
        if row.hasChildren {
            Button(action: onToggleExpand) {
                Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                    .amgiFont(.micro)
                    .foregroundStyle(palette.textSecondary)
                    .frame(width: 12, height: 12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                row.isExpanded
                    ? "Collapse \(BrowseDeckTree.leafName(row.deck.name))"
                    : "Expand \(BrowseDeckTree.leafName(row.deck.name))"
            )
        } else {
            Color.clear.frame(width: 12, height: 12)
        }
    }

    @ViewBuilder
    private func deckTile(leaf: String) -> some View {
        if let iconName {
            DeckIconTile(
                iconName: iconName, deckName: leaf,
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
}

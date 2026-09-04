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
/// parity). Flattening, parent resolution and search filtering live in
/// `BrowseDeckTree` so the compact Search landing can reuse them.
struct BrowseSourceColumn: View {
    @Environment(\.palette) private var palette
    @Bindable var model: BrowseModel
    let exit: BrowseExit?

    /// Resolved deck-icon names (same synced overrides Library/Study use).
    @State private var iconNames: [Int64: String] = [:]

    /// Expanded deck full-names, newline-joined. `@AppStorage` can't hold a
    /// Set, and the joined form keeps the preference readable. Shared with
    /// the compact landing via `BrowseDeckTree.expandedStorageKey`.
    @AppStorage(BrowseDeckTree.expandedStorageKey) private var expandedRaw = ""

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
                    BrowseDeckRowLabel(row: row, iconName: iconNames[row.deck.id.rawValue]) {
                        toggleExpansion(row.deck.name)
                    }
                    .tag(BrowseSource.deck(row.deck.id))
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
            iconNames = await BrowseDeckTree.loadIconNames(for: model.allDecks)
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
            decks: model.allDecks,
            expanded: expanded,
            filterTokens: BrowseDeckTree.filterTokens(from: model.searchText),
            resultDeckIDs: model.resultDeckIDs
        )
    }

    private var visibleTags: [String] {
        BrowseDeckTree.visibleTags(
            model.allTags,
            tokens: BrowseDeckTree.filterTokens(from: model.searchText)
        )
    }
}

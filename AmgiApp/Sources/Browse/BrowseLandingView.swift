// AmgiApp/Sources/Browse/BrowseLandingView.swift
#if os(iOS)
import SwiftUI
import AmgiUI
import AnkiKit
import AmgiTheme

private enum BrowseColumn {
    static let maxWidth: CGFloat = 800
}

/// Compact Search tab root. Three states:
///
/// - Idle: quick-filter tiles, then Decks / Tags / Saved Searches.
/// - Focused with an empty query: Recent Searches + Saved Searches.
/// - Non-empty query: `BrowseListColumn` replaces the landing in place.
///
/// Rows are plain buttons with no `List(selection:)` — the grey full-bleed
/// slab on the old compact sidebar was that selection highlight sitting
/// outside an inset-grouped card.
struct BrowseLandingView: View {
    @Environment(\.isSearching) private var isSearching
    @Environment(\.palette) private var palette
    @Bindable var model: BrowseModel
    @Binding var selectionState: BrowseSelectionState
    let onSwipeDelete: (NoteRecord) -> Void
    let onSelect: (BrowseSource) -> Void
    let onOpenDetail: () -> Void

    @State private var iconNames: [Int64: String] = [:]
    @AppStorage(BrowseDeckTree.expandedStorageKey) private var expandedRaw = ""

    private var query: String {
        model.searchText.trimmingCharacters(in: .whitespaces)
    }

    var body: some View {
        Group {
            if !query.isEmpty {
                BrowseListColumn(
                    model: model,
                    selectionState: $selectionState,
                    onSwipeDelete: onSwipeDelete,
                    onOpenDetail: onOpenDetail
                )
            } else if isSearching {
                focusedEmpty
            } else {
                idleLanding
            }
        }
        .task(id: model.allDecks.map(\.id)) {
            iconNames = await BrowseDeckTree.loadIconNames(for: model.allDecks)
        }
    }

    // MARK: - Idle

    private var idleLanding: some View {
        List {
            Section {
                quickFilters
                    .listRowInsets(EdgeInsets(
                        top: AmgiSpacing.sm,
                        leading: AmgiSpacing.lg,
                        bottom: AmgiSpacing.sm,
                        trailing: AmgiSpacing.lg
                    ))
                    .listRowBackground(Color.clear)
            }

            Section {
                ForEach(deckRows) { row in
                    Button {
                        onSelect(.deck(row.deck.id))
                    } label: {
                        BrowseDeckRowLabel(
                            row: row,
                            iconName: iconNames[row.deck.id.rawValue]
                        ) {
                            toggleExpansion(row.deck.name)
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(palette.textPrimary)
                }
            } header: {
                sectionHeader("Decks")
            }

            if !visibleTags.isEmpty {
                Section {
                    ForEach(visibleTags, id: \.self) { tag in
                        Button {
                            onSelect(.tag(tag))
                        } label: {
                            Label(tag, systemImage: "tag")
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .foregroundStyle(palette.textPrimary)
                    }
                } header: {
                    sectionHeader("Tags")
                }
            }

            if !model.savedSearches.searches.isEmpty {
                savedSearchSection
            }
        }
        .listStyle(.insetGrouped)
        .frame(maxWidth: BrowseColumn.maxWidth)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Focused, empty query

    private var focusedEmpty: some View {
        List {
            if !model.recentQueries.isEmpty {
                Section {
                    ForEach(model.recentQueries, id: \.self) { recent in
                        Button {
                            model.searchText = recent
                            model.commitSearchHistory()
                            model.scheduleSearch(immediate: true)
                        } label: {
                            Label(recent, systemImage: "clock.arrow.circlepath")
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .foregroundStyle(palette.textPrimary)
                    }
                } header: {
                    HStack {
                        sectionHeader("Recent Searches")
                        Spacer()
                        Button("Clear") {
                            model.clearSearchHistory()
                        }
                        .amgiFont(.caption)
                        .foregroundStyle(palette.accent)
                        .textCase(nil)
                    }
                }
            }

            if !model.savedSearches.searches.isEmpty {
                savedSearchSection
            }
        }
        .listStyle(.insetGrouped)
        .frame(maxWidth: BrowseColumn.maxWidth)
        .frame(maxWidth: .infinity)
    }

    private var savedSearchSection: some View {
        Section {
            ForEach(model.savedSearches.searches) { saved in
                Button {
                    onSelect(.saved(saved.name))
                } label: {
                    Label(saved.name, systemImage: "heart")
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .foregroundStyle(palette.textPrimary)
            }
        } header: {
            sectionHeader("Saved Searches")
        }
    }

    // MARK: - Quick filters

    private var quickFilterNodes: [FilterNode] {
        Array(BrowseFilterSections.today().prefix(3)) + BrowseFilterSections.cardStates()
    }

    private var quickFilters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AmgiSpacing.sm) {
                ForEach(quickFilterNodes) { node in
                    Button {
                        Task { await model.applyFilterNode(node, composition: .replace) }
                    } label: {
                        Label(node.title, systemImage: node.systemImage)
                            .amgiFont(.caption)
                            .padding(.horizontal, AmgiSpacing.md)
                            .padding(.vertical, AmgiSpacing.sm)
                            .foregroundStyle(filterForeground(node))
                            .background(filterBackground(node), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(node.title)
                }
            }
        }
    }

    private func filterForeground(_ node: FilterNode) -> Color {
        switch node.role {
        case .state(let state): stateColor(state)
        case .flag, .none: palette.textPrimary
        }
    }

    private func filterBackground(_ node: FilterNode) -> Color {
        switch node.role {
        case .state(let state): stateColor(state).opacity(0.14)
        case .flag, .none: palette.surfaceElevated
        }
    }

    private func stateColor(_ color: BrowseModelStateColor) -> Color {
        switch color {
        case .newState: palette.cardStateNew
        case .learning: palette.cardStateLearning
        case .review: palette.cardStateReview
        case .suspended: palette.cardStateSuspended
        case .buried: palette.warning
        }
    }

    // MARK: - Headers & tree

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .amgiFont(.sectionHeading)
            .foregroundStyle(palette.textPrimary)
            .textCase(nil)
    }

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

    private var deckRows: [BrowseDeckTree.Row] {
        BrowseDeckTree.rows(
            decks: model.allDecks,
            expanded: expanded,
            filterTokens: [],
            resultDeckIDs: []
        )
    }

    private var visibleTags: [String] {
        model.allTags
    }
}
#endif

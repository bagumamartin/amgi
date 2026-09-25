import Foundation
import SwiftUI
import AmgiTheme
import AmgiUI
import AmgiCharts
import AnkiKit

enum StatsDashboardLayout: Equatable {
    case compact
    case regular

    static let minimumRegularWidth: CGFloat = 800

    /// Kept for callers/tests that only have a coarse size-class signal.
    static func resolve(isRegularWidth: Bool) -> Self {
        isRegularWidth ? .regular : .compact
    }

    /// The real layout boundary is the width of the stats workspace, not
    /// whether the device calls itself regular. A split-view iPad can be
    /// regular at 500 points and must keep the phone-scale chart stack.
    static func resolve(
        availableWidth: CGFloat,
        isAccessibilitySize: Bool = false
    ) -> Self {
        guard !isAccessibilitySize, availableWidth >= minimumRegularWidth else {
            return .compact
        }
        return .regular
    }
}

/// Pure render-from-data half of the stats dashboard. Owns no dependencies
/// and performs no loading, so every state previews by varying one argument.
struct StatsDashboardContent: View {

    enum State {
        case loading
        case loaded(GraphsSnapshot)
        case failed(String)
    }

    let state: State
    let period: StatsPeriod
    let selectedDeck: DeckInfo?
    /// The complete deck list, including subdecks. A deck search includes its
    /// descendants, so exposing that hierarchy makes the scope picker match
    /// the query that is actually sent to Anki.
    let decks: [DeckInfo]
    let onSelectDeck: (DeckInfo?) -> Void
    let onSelectPeriod: (StatsPeriod) -> Void
    /// A period/deck change keeps the previous graphs on screen rather than
    /// blanking to a spinner — but silently, the screen was indistinguishable
    /// from one that had ignored the tap. This marks the wait.
    let isRefreshing: Bool
    let allowsDeckSelection: Bool

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var isDeckPickerPresented = false
    @State private var deckSearchText = ""

    private var deckOptions: [StatsDeckScopeItem] {
        StatsDeckScopeCatalog.items(from: decks)
    }

    var body: some View {
        GeometryReader { proxy in
            let layout = StatsDashboardLayout.resolve(
                availableWidth: proxy.size.width,
                isAccessibilitySize: dynamicTypeSize.isAccessibilitySize
            )
            ScrollView {
                LazyVStack(spacing: AmgiSpacing.lg) {
                    // Outside the switch: the filters used to render only in
                    // `.loaded`, so during the first load — the slowest case,
                    // and the one where the user most wants a cheaper period —
                    // there was nothing on screen to change.
                    filters(layout: layout)

                    switch state {
                    case .loading:
                        ProgressView("Loading statistics...").padding(.top, 40)
                    case .failed(let message):
                        ContentUnavailableView(
                            "Failed to Load Stats",
                            systemImage: "exclamationmark.triangle",
                            description: Text(message)
                        )
                    case .loaded(let graphs):
                        charts(graphs, layout: layout)
                            .opacity(isRefreshing ? 0.4 : 1)
                            .overlay(alignment: .top) {
                                if isRefreshing { ProgressView().padding(.top, 40) }
                            }
                            .animation(AmgiMotion.standard, value: isRefreshing)
                    }
                }
                .frame(maxWidth: 1_200)
                .frame(maxWidth: .infinity)
                .padding(AmgiSpacing.lg)
            }
        }
    }

    // MARK: - Filters

    private func filters(layout: StatsDashboardLayout) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: AmgiSpacing.md) {
                if allowsDeckSelection { deckScopeControl(layout: layout) }
                else if let selectedDeck { lockedDeckCapsule(selectedDeck) }
                periodMenu
            }
            VStack(alignment: .leading, spacing: AmgiSpacing.sm) {
                if allowsDeckSelection { deckScopeControl(layout: layout) }
                else if let selectedDeck { lockedDeckCapsule(selectedDeck) }
                periodMenu
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func lockedDeckCapsule(_ deck: DeckInfo) -> some View {
        filterCapsule(icon: "rectangle.stack", label: deck.name, showsDisclosure: false)
    }

    @ViewBuilder
    private func deckScopeControl(layout: StatsDashboardLayout) -> some View {
        switch layout {
        case .compact:
            // Preserve the compact phone's familiar menu. It now includes the
            // full hierarchy and counts, but occupies the same control shape.
            deckMenu
        case .regular:
            Button {
                isDeckPickerPresented = true
            } label: {
                filterCapsule(
                    icon: "rectangle.stack",
                    label: selectedDeck?.name ?? "Whole Collection"
                )
            }
            .buttonStyle(.plain)
            .popover(isPresented: $isDeckPickerPresented) {
                deckPicker
                    .presentationCompactAdaptation(.popover)
            }
        }
    }

    private var deckMenu: some View {
        Menu {
            Button { onSelectDeck(nil) } label: {
                if selectedDeck == nil { Label("Whole Collection", systemImage: "checkmark") }
                else { Text("Whole Collection") }
            }
            if !deckOptions.isEmpty { Divider() }
            ForEach(deckOptions) { item in
                Button { onSelectDeck(item.deck) } label: {
                    if selectedDeck?.id == item.deck.id {
                        Label(item.deck.name, systemImage: "checkmark")
                    } else {
                        Text(item.deck.name)
                    }
                }
            }
        } label: {
            filterCapsule(
                icon: "rectangle.stack",
                label: selectedDeck?.name ?? "Collection"
            )
        }
    }

    private var periodMenu: some View {
        Menu {
            ForEach(StatsPeriod.allCases, id: \.self) { p in
                Button { onSelectPeriod(p) } label: {
                    if period == p { Label(p.rawValue, systemImage: "checkmark") }
                    else { Text(p.rawValue) }
                }
            }
        } label: {
            filterCapsule(
                icon: "calendar",
                label: period.shortLabel
            )
        }
    }

    private var deckPicker: some View {
        NavigationStack {
            List {
                Button {
                    chooseDeck(nil)
                } label: {
                    scopeRow(
                        title: "Whole Collection",
                        subtitle: "Every deck",
                        systemImage: "square.stack.3d.up",
                        isSelected: selectedDeck == nil,
                        indent: 0
                    )
                }
                .buttonStyle(.plain)

                if filteredDeckOptions.isEmpty {
                    ContentUnavailableView.search(text: deckSearchText)
                } else {
                    Section("Decks") {
                        ForEach(filteredDeckOptions) { item in
                            Button {
                                chooseDeck(item.deck)
                            } label: {
                                scopeRow(
                                    title: item.displayName,
                                    subtitle: item.parentPath,
                                    systemImage: item.deck.isFiltered ? "line.3.horizontal.decrease.circle" : "rectangle.stack",
                                    isSelected: selectedDeck?.id == item.deck.id,
                                    indent: item.depth,
                                    trailingText: "\(item.deck.counts.total) due"
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(item.deck.name)
                            .accessibilityValue("\(item.deck.counts.total) due")
                        }
                    }
                }
            }
            .searchable(text: $deckSearchText, prompt: "Find a deck")
            .navigationTitle("Statistics Scope")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { isDeckPickerPresented = false }
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        .frame(minWidth: 320, idealWidth: 380, minHeight: 360, idealHeight: 480)
    }

    private var filteredDeckOptions: [StatsDeckScopeItem] {
        StatsDeckScopeCatalog.filter(deckOptions, query: deckSearchText)
    }

    private func chooseDeck(_ deck: DeckInfo?) {
        onSelectDeck(deck)
        deckSearchText = ""
        isDeckPickerPresented = false
    }

    private func scopeRow(
        title: String,
        subtitle: String,
        systemImage: String,
        isSelected: Bool,
        indent: Int,
        trailingText: String? = nil
    ) -> some View {
        HStack(spacing: AmgiSpacing.sm) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : systemImage)
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .fontWeight(isSelected ? .semibold : .regular)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .amgiFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.leading, CGFloat(indent) * 14)
            Spacer(minLength: AmgiSpacing.sm)
            if let trailingText {
                Text(trailingText)
                    .amgiFont(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func filterCapsule(icon: String, label: String, showsDisclosure: Bool = true) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .amgiFont(.caption)
            Text(label)
                .fontWeight(.medium)
                .lineLimit(1)
            if showsDisclosure {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8))
            }
        }
        .amgiFont(.body)
        .amgiCapsuleControl()
    }

    // MARK: - Charts

    @ViewBuilder
    private func charts(_ graphs: GraphsSnapshot, layout: StatsDashboardLayout) -> some View {
        StatsChartStack(
            graphs: graphs,
            period: period,
            layout: layout == .regular ? .twoColumn : .singleColumn
        )
    }
}

struct StatsDeckScopeItem: Identifiable, Equatable {
    let deck: DeckInfo
    let depth: Int

    var id: Int64 { deck.id.rawValue }
    var displayName: String { deck.name.split(separator: "::").last.map(String.init) ?? deck.name }

    var parentPath: String {
        let components = deck.name.split(separator: "::", omittingEmptySubsequences: true)
        guard components.count > 1 else { return "Includes subdecks" }
        return components.dropLast().joined(separator: " › ")
    }
}

enum StatsDeckScopeCatalog {
    /// Natural tree order keeps a child beside its parent. The path fallback
    /// handles collections that contain no explicit parent row.
    static func items(from decks: [DeckInfo]) -> [StatsDeckScopeItem] {
        decks
            .map { deck in
                StatsDeckScopeItem(
                    deck: deck,
                    depth: max(
                        0,
                        deck.name.split(separator: "::").filter { !$0.isEmpty }.count - 1
                    )
                )
            }
            .sorted { lhs, rhs in
                let comparison = lhs.deck.name.localizedStandardCompare(rhs.deck.name)
                if comparison == .orderedSame { return lhs.id < rhs.id }
                return comparison == .orderedAscending
            }
    }

    static func filter(_ items: [StatsDeckScopeItem], query: String) -> [StatsDeckScopeItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return items }
        return items.filter { item in
            item.deck.name.localizedCaseInsensitiveContains(trimmed)
        }
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Loaded") {
    StatsDashboardContent(
        state: .loaded(.sample), period: .month, selectedDeck: nil,
        decks: [], onSelectDeck: { _ in }, onSelectPeriod: { _ in },
        isRefreshing: false, allowsDeckSelection: true
    )
}

#Preview("Refreshing") {
    StatsDashboardContent(
        state: .loaded(.sample), period: .year, selectedDeck: nil,
        decks: [], onSelectDeck: { _ in }, onSelectPeriod: { _ in },
        isRefreshing: true, allowsDeckSelection: true
    )
}

#Preview("Loading") {
    StatsDashboardContent(
        state: .loading, period: .month, selectedDeck: nil,
        decks: [], onSelectDeck: { _ in }, onSelectPeriod: { _ in },
        isRefreshing: false, allowsDeckSelection: true
    )
}

#Preview("Failed") {
    StatsDashboardContent(
        state: .failed("The collection is locked."), period: .month,
        selectedDeck: nil, decks: [], onSelectDeck: { _ in }, onSelectPeriod: { _ in },
        isRefreshing: false, allowsDeckSelection: true
    )
}
#endif

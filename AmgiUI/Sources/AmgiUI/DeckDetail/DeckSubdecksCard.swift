public import SwiftUI
import AmgiTheme

/// Inset-group card listing the deck's direct children. Each row tap
/// fires `onSelect(rowData)` — the Container translates to a navigation
/// push. Empty `rows` should be filtered at the Container layer; if you
/// pass `[]` here the card still renders the section header but the
/// surface collapses to zero height.
public struct DeckSubdecksCard: View {
    public let rows: [DeckSubdeckRowData]
    public let onSelect: (DeckSubdeckRowData) -> Void
    public let onRename: (DeckSubdeckRowData) -> Void
    public let onChangeIcon: (DeckSubdeckRowData) -> Void
    public let onDelete: (DeckSubdeckRowData) -> Void

    @Environment(\.palette) private var palette
    /// Matches the row's own metrics (12pt vertical padding + 30pt glyph).
    /// The List is sized to fit every row exactly so it never scrolls
    /// internally — the enclosing screen ScrollView stays the sole scroller,
    /// and native swipeActions come free.
    @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat = 54

    public init(
        rows: [DeckSubdeckRowData],
        onSelect: @escaping (DeckSubdeckRowData) -> Void,
        onRename: @escaping (DeckSubdeckRowData) -> Void = { _ in },
        onChangeIcon: @escaping (DeckSubdeckRowData) -> Void = { _ in },
        onDelete: @escaping (DeckSubdeckRowData) -> Void = { _ in }
    ) {
        self.rows = rows
        self.onSelect = onSelect
        self.onRename = onRename
        self.onChangeIcon = onChangeIcon
        self.onDelete = onDelete
    }

    public var body: some View {
        List {
            ForEach(Array(rows.enumerated()), id: \.element.id) { idx, row in
                DeckSubdeckRow(
                    data: row,
                    showsDivider: idx < rows.count - 1,
                    onTap: { onSelect(row) },
                    onRename: { onRename(row) },
                    onChangeIcon: { onChangeIcon(row) },
                    onDelete: { onDelete(row) }
                )
                // Pin every row to the same scaled metric the container
                // height multiplies — guarantees count × rowHeight exactly
                // equals the List's content, so nothing clips or scrolls.
                .frame(height: rowHeight)
                .listRowInsets(EdgeInsets())
                #if !os(watchOS)
                .listRowSeparator(.hidden)
                #endif
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        #if !os(watchOS)
        .scrollContentBackground(.hidden)
        #endif
        // Rigid: every row is pinned to `rowHeight`, so the container height
        // below always equals the content height — the List never scrolls;
        // the enclosing screen ScrollView stays the sole scroller.
        .scrollDisabled(true)
        .frame(height: CGFloat(rows.count) * rowHeight)
        .clipShape(cardShape)
        .background(cardShape.fill(palette.surfaceElevated))
        .overlay(cardShape.strokeBorder(palette.border, lineWidth: 0.5))
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: AmgiRadius.inset, style: .continuous)
    }
}

// MARK: - Previews

#if DEBUG
private let _subdecksSample: [DeckSubdeckRowData] = [
    DeckSubdeckRowData(id: 1, name: "Vocab Typing", fullName: "한국어::Vocab Typing", newCount: 20, learnCount: 0, reviewCount: 5, isFiltered: false),
    DeckSubdeckRowData(id: 2, name: "Cloze Grammar", fullName: "한국어::Cloze Grammar", newCount: 0, learnCount: 4, reviewCount: 9, isFiltered: false),
    DeckSubdeckRowData(id: 3, name: "Collocations", fullName: "한국어::Collocations", newCount: 0, learnCount: 14, reviewCount: 0, isFiltered: false),
    DeckSubdeckRowData(id: 4, name: "Manual Tags", fullName: "한국어::Manual Tags", newCount: 20, learnCount: 3, reviewCount: 3, isFiltered: false),
]

#Preview("Subdecks — four rows") {
    DeckSubdecksCard(rows: _subdecksSample, onSelect: { _ in })
        .padding()
        .environment(\.palette, .vividLight)
}

#Preview("Subdecks — single row") {
    DeckSubdecksCard(rows: [_subdecksSample[0]], onSelect: { _ in })
        .padding()
        .environment(\.palette, .vividLight)
}
#endif

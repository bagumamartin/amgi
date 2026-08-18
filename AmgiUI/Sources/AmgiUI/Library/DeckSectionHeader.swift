public import SwiftUI
import AmgiTheme

/// Section title with a trailing sort menu — used for Library "Decks" and
/// deck-detail "Subdecks". Pure rendering; the container owns persistence.
public struct DeckSectionHeader: View {
    public let title: String
    @Binding public var sortOrder: DeckSortOrder

    @Environment(\.palette) private var palette

    public init(title: String, sortOrder: Binding<DeckSortOrder>) {
        self.title = title
        self._sortOrder = sortOrder
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.caption.weight(.semibold))
                .tracking(0.4)
                .foregroundStyle(palette.textTertiary)
                .textCase(nil)

            Spacer(minLength: 8)

            Menu {
                Picker("Sort decks", selection: $sortOrder) {
                    ForEach(DeckSortOrder.allCases) { order in
                        Text(order.menuLabel).tag(order)
                    }
                }
            } label: {
                Label(sortOrder.title, systemImage: "arrow.up.arrow.down")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(palette.accent)
                    .labelStyle(.titleAndIcon)
            }
            .menuOrder(.fixed)
        }
        .padding(.leading, 4)
        .padding(.trailing, 0)
        .textCase(nil)
    }
}

#if DEBUG
#Preview("Library decks header") {
    @Previewable @State var sortOrder: DeckSortOrder = .mostUsed
    DeckSectionHeader(title: "Decks", sortOrder: $sortOrder)
        .padding()
        .environment(\.palette, .vividLight)
}

#Preview("Subdecks header") {
    @Previewable @State var sortOrder: DeckSortOrder = .alphabetical
    DeckSectionHeader(title: "SUBDECKS", sortOrder: $sortOrder)
        .padding()
        .environment(\.palette, .vividLight)
}
#endif

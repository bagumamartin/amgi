// iOS/macOS-only — `Menu` is unavailable on watchOS.
#if !os(watchOS)
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
                .amgiFont(.sectionHeading)
                .foregroundStyle(palette.textPrimary)
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
                    .amgiFont(.caption)
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

/// Collapsed "Archived" header. Only mount this when `count > 0` — the
/// Library and deck-detail screens both hide the section when nothing is parked.
public struct ArchivedSectionHeader: View {
    public let count: Int
    public let itemNoun: String
    @Binding public var isExpanded: Bool

    @Environment(\.palette) private var palette

    public init(count: Int, itemNoun: String, isExpanded: Binding<Bool>) {
        self.count = count
        self.itemNoun = itemNoun
        self._isExpanded = isExpanded
    }

    public var body: some View {
        Button {
            withAnimation(AmgiMotion.standard) { isExpanded.toggle() }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Archived")
                    .amgiFont(.sectionHeading)
                    .foregroundStyle(palette.textPrimary)
                Text("\(count)")
                    .amgiFont(.caption)
                    .foregroundStyle(palette.textTertiary)
                    .monospacedDigit()
                Spacer(minLength: 8)
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.textTertiary)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
            .padding(.leading, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Archived, \(count) \(itemNoun)")
        .accessibilityHint(isExpanded ? "Collapse" : "Expand")
        .accessibilityAddTraits(.isButton)
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

#Preview("Archived header") {
    @Previewable @State var expanded = false
    ArchivedSectionHeader(count: 2, itemNoun: "subdecks", isExpanded: $expanded)
        .padding()
        .environment(\.palette, .vividLight)
}
#endif
#endif  // !os(watchOS)

#if os(watchOS)
public import SwiftUI
import AmgiTheme

/// Title-only stand-in: `Menu` is unavailable on watchOS, and the watch
/// never presents this header. Kept so sibling AmgiUI files still type-check.
public struct DeckSectionHeader: View {
    public let title: String
    @Binding public var sortOrder: DeckSortOrder

    public init(title: String, sortOrder: Binding<DeckSortOrder>) {
        self.title = title
        self._sortOrder = sortOrder
    }

    public var body: some View {
        Text(title)
            .amgiFont(.sectionHeading)
            .textCase(nil)
    }
}

/// Title-only stand-in: the watch never presents Archived. Kept so sibling
/// AmgiUI files still type-check.
public struct ArchivedSectionHeader: View {
    public let count: Int
    public let itemNoun: String
    @Binding public var isExpanded: Bool

    public init(count: Int, itemNoun: String, isExpanded: Binding<Bool>) {
        self.count = count
        self.itemNoun = itemNoun
        self._isExpanded = isExpanded
    }

    public var body: some View {
        Text("Archived")
            .amgiFont(.sectionHeading)
            .textCase(nil)
    }
}
#endif

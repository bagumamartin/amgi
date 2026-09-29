// iOS-only component — Menu/popover/listRowSeparator APIs are unavailable on watchOS.
#if !os(watchOS)
public import SwiftUI
import AmgiTheme

/// The Library "Needs a decision" card: decks with a collection problem
/// only the Library can state (neglected, never started, new wall, empty).
/// Pure rendering — the container classifies into `DeckTriageData` and
/// hands rows back through `onTapDeck`, the same path deck-list taps use.
/// Hidden entirely when resolved-and-empty; a redacted placeholder while
/// the review history it depends on is still in flight.
public struct DeckTriageCard: View {
    public let data: DeckTriageData
    public let onTapDeck: (DeckRowViewData) -> Void

    @Environment(\.palette) private var palette

    public init(data: DeckTriageData, onTapDeck: @escaping (DeckRowViewData) -> Void) {
        self.data = data
        self.onTapDeck = onTapDeck
    }

    public var body: some View {
        // The container mounts this only when `!data.isHidden`; the guard
        // keeps direct uses (previews, tests) honest too.
        if !data.isHidden {
            AmgiCard(background: .surfaceElevated, shadow: nil) {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    if data.isResolved {
                        ForEach(data.items) { item in
                            triageRow(item, disabled: false)
                        }
                        if data.overflowCount > 0 {
                            Text("and \(data.overflowCount) more")
                                .amgiFont(.caption)
                                .foregroundStyle(palette.textSecondary)
                        }
                    } else {
                        // Fixed skeleton count — the cap is 4, three reads
                        // as "loading" without implying a full card.
                        ForEach(0..<3, id: \.self) { _ in
                            triageRow(skeletonItem, disabled: true)
                        }
                    }
                }
            }
            .redacted(reason: data.isResolved ? [] : .placeholder)
            .accessibilityLabel("Needs a decision")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Needs a decision")
                .amgiFont(.sectionHeading)
                .foregroundStyle(palette.textPrimary)
            if data.isResolved {
                Text("\(data.items.count + data.overflowCount)")
                    .amgiFont(.caption)
                    .foregroundStyle(palette.textSecondary)
            }
            Spacer(minLength: 8)
        }
    }

    private func triageRow(_ item: DeckTriageItem, disabled: Bool) -> some View {
        Button {
            onTapDeck(item.row)
        } label: {
            HStack(spacing: 12) {
                DeckTile(name: item.row.name, iconName: item.row.iconName, isFiltered: item.row.isFiltered)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.row.name)
                        .amgiFont(.body)
                        .bold()
                        .foregroundStyle(palette.textPrimary)
                    Text(item.subtitle)
                        .amgiFont(.caption)
                        .foregroundStyle(palette.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.textTertiary)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    /// Redacted filler — content never seen, only its shimmer.
    private var skeletonItem: DeckTriageItem {
        DeckTriageItem(
            row: DeckRowViewData(
                id: -1, name: "Loading deck", fullName: "Loading deck",
                newCount: 10, learnCount: 5, reviewCount: 20,
                isFiltered: false, subdeckCount: 0
            ),
            issue: .neglected(daysAgo: 30)
        )
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Triage — populated") {
    DeckTriageCard(data: .sample, onTapDeck: { _ in })
        .padding()
        .environment(\.palette, .vividLight)
}

#Preview("Triage — resolving") {
    DeckTriageCard(data: .unresolved, onTapDeck: { _ in })
        .padding()
        .environment(\.palette, .vividLight)
}

#Preview("Triage — minimal palette") {
    DeckTriageCard(data: .sample, onTapDeck: { _ in })
        .padding()
        .environment(\.palette, ThemeRegistry.shared.palette(id: .minimal, scheme: .light))
}
#endif
#endif  // !os(watchOS)

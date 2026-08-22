public import SwiftUI
import AmgiTheme

/// Single subdeck row inside `DeckSubdecksCard`. Renders the deck's
/// glyph chip, leaf name, count badges, and a trailing chevron.
/// Tap is routed through the caller-supplied closure — Container layer
/// wires this to a programmatic navigation push so AmgiUI stays
/// independent of `NavigationLink(value:)` and AnkiKit's `DeckInfo`.
public struct DeckSubdeckRow: View {
    public let data: DeckSubdeckRowData
    public let showsDivider: Bool
    public let onTap: () -> Void
    public let onRename: () -> Void
    public let onChangeIcon: () -> Void
    public let onDelete: () -> Void

    @Environment(\.palette) private var palette
    /// Must match `DeckSubdecksCard`'s metric — the card multiplies this by
    /// row count for its rigid height, and pins each row with it.
    @ScaledMetric(relativeTo: .body) private var fixedHeight: CGFloat = 54

    public init(
        data: DeckSubdeckRowData,
        showsDivider: Bool,
        onTap: @escaping () -> Void,
        onRename: @escaping () -> Void = {},
        onChangeIcon: @escaping () -> Void = {},
        onDelete: @escaping () -> Void = {}
    ) {
        self.data = data
        self.showsDivider = showsDivider
        self.onTap = onTap
        self.onRename = onRename
        self.onChangeIcon = onChangeIcon
        self.onDelete = onDelete
    }

    /// Compact swipe-button label: icon stacked over a small caption.
    private func swipeLabel(_ systemImage: String, _ title: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
        }
    }

    public var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                if let iconName = data.iconName, !iconName.isEmpty {
                    DeckIconTile(iconName: iconName, deckName: data.name, size: 30, cornerRadius: 8)
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(palette.textPrimary.opacity(0.05))
                        Image(systemName: "rectangle.stack")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(palette.textSecondary)
                    }
                    .frame(width: 30, height: 30)
                }

                Text(data.name)
                    .font(.system(size: 16))
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                Spacer()

                DeckCountBadges(
                    newCount: data.newCount,
                    learnCount: data.learnCount,
                    reviewCount: data.reviewCount
                )

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.textTertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .frame(height: fixedHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Row management matches the Library screen. The card is a real
        // List (see `DeckSubdecksCard`), so native swipe actions work;
        // delete routes through the container's confirmation alert.
        // Labels are explicit icon-over-caption stacks — compact like the
        // Library's swipe buttons instead of wide side-by-side Labels.
        #if !os(watchOS)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                onDelete()
            } label: {
                swipeLabel("trash", "Delete")
            }
            Button {
                onChangeIcon()
            } label: {
                swipeLabel("paintpalette", "Edit Icon")
                    .tint(.indigo)
            }
            Button {
                onRename()
            } label: {
                swipeLabel("pencil", "Rename")
                    .tint(.orange)
            }
        }
        #endif
        .contextMenu {
            Button {
                onRename()
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button {
                onChangeIcon()
            } label: {
                Label("Edit Icon", systemImage: "paintpalette")
            }
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .overlay(alignment: .bottom) {
            if showsDivider {
                Rectangle()
                    .fill(palette.border)
                    .frame(height: 0.5)
                    .padding(.leading, 56)
            }
        }
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Subdeck row") {
    DeckSubdeckRow(
        data: DeckSubdeckRowData(
            id: 1,
            name: "Vocab Typing",
            fullName: "한국어::Vocab Typing",
            newCount: 20,
            learnCount: 0,
            reviewCount: 5,
            isFiltered: false
        ),
        showsDivider: true,
        onTap: {}
    )
    .padding()
    .environment(\.palette, .vividLight)
}

#Preview("Subdeck row — filtered, no new") {
    DeckSubdeckRow(
        data: DeckSubdeckRowData(
            id: 2,
            name: "Cloze Grammar",
            fullName: "한국어::Cloze Grammar",
            newCount: 0,
            learnCount: 4,
            reviewCount: 9,
            isFiltered: true
        ),
        showsDivider: false,
        onTap: {}
    )
    .padding()
    .environment(\.palette, .vividLight)
}
#endif

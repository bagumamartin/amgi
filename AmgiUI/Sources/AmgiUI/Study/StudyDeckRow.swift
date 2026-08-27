public import SwiftUI
import AmgiTheme

/// A single row in the Study "Up Next" list.
///
/// Top-level decks (`depth == 0`) show the deck tile plus a chevron on the
/// right end when the deck has subdecks. Subdecks (`depth > 0`) drop the
/// tile, indent under the parent's name, and display only the last path
/// segment (`data.name`) — never the `parent::child` full path.
public struct StudyDeckRow: View {
    public let data: StudyDeckRowData
    public let depth: Int
    public let isExpanded: Bool
    public let onTap: () -> Void
    public let onToggleExpand: () -> Void

    @Environment(\.palette) private var palette

    public init(
        data: StudyDeckRowData,
        depth: Int = 0,
        isExpanded: Bool = false,
        onTap: @escaping () -> Void,
        onToggleExpand: @escaping () -> Void = {}
    ) {
        self.data = data
        self.depth = depth
        self.isExpanded = isExpanded
        self.onTap = onTap
        self.onToggleExpand = onToggleExpand
    }

    public var body: some View {
        HStack(spacing: 0) {
            Button(action: onTap) {
                HStack(spacing: 12) {
                    if depth == 0 {
                        StudyDeckTile(name: data.name, iconName: data.iconName, isFiltered: data.isFiltered)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        if depth > 0, let iconName = data.iconName, !iconName.isEmpty {
                            HStack(spacing: 8) {
                                DeckIconTile(iconName: iconName, deckName: data.name, size: 30, cornerRadius: 8)
                                Text(data.name)
                                    .amgiFont(.body)
                                    .foregroundStyle(palette.textPrimary)
                                    .lineLimit(1)
                            }
                        } else {
                            Text(data.name)
                                .amgiFont(.body)
                                .fontWeight(depth == 0 ? .bold : .regular)
                                .foregroundStyle(palette.textPrimary)
                                .lineLimit(1)
                        }
                        if data.isFiltered {
                            Label("Filtered", systemImage: "bolt.fill")
                                .amgiFont(.caption)
                                .foregroundStyle(palette.customStudyBadge)
                        }
                    }
                    Spacer(minLength: 12)
                    // Unit-free count, right-aligned at a uniform edge: the
                    // chevron zone below is reserved on EVERY row, so counts
                    // stop at the same distance from the trailing edge
                    // whether or not the deck expands. Top-level counts are
                    // as bold as their deck names.
                    Text("\(data.totalDue)")
                        .amgiFont(.caption)
                        .fontWeight(depth == 0 ? .bold : .regular)
                        .monospacedDigit()
                        .foregroundStyle(depth == 0 ? palette.textPrimary : palette.textSecondary)
                }
                .padding(.vertical, depth == 0 ? 10 : 8)
                .padding(.leading, leadingIndent)
                .frame(minHeight: depth == 0 ? 56 : 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)

            // Reserved trailing zone: the expand/collapse chevron when the
            // deck has subdecks, otherwise blank space of the same width so
            // every row's count lines up.
            Group {
                if !data.subdecks.isEmpty {
                    Button(action: onToggleExpand) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(palette.textTertiary)
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
                            .frame(width: 40, height: depth == 0 ? 56 : 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    Color.clear
                        .frame(width: 40, height: depth == 0 ? 56 : 44)
                }
            }
        }
    }

    /// Leading indent for nested rows. Depth 1 aligns the subdeck name under
    /// the parent's name (tile 40 + spacing 12); deeper levels add 20pt each.
    private var leadingIndent: CGFloat {
        guard depth > 0 else { return 0 }
        return 52 + CGFloat(depth - 1) * 20
    }
}

// MARK: - StudyDeckTile

/// Private tile glyph matching the Library deck tile style.
/// Intentionally duplicated from `DeckListRowView`'s private `DeckTile`
/// to avoid premature abstraction — promote when a third call site appears.
private struct StudyDeckTile: View {
    let name: String
    let iconName: String?
    let isFiltered: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        if let iconName, !iconName.isEmpty {
            DeckIconTile(iconName: iconName, deckName: name, size: 40, cornerRadius: AmgiRadius.control)
        } else {
            legacyTile
        }
    }

    private var legacyTile: some View {
        let resolved = DeckTileGlyph.resolve(deckName: name, palette: palette)
        let fill: Color
        let glyphColor: Color
        switch resolved.mode {
        case .emoji:
            fill = palette.surfaceElevated
            glyphColor = palette.textPrimary
        case .letter(let tint):
            fill = tint
            glyphColor = .white
        case .monogram(let tint):
            fill = tint.opacity(0.11)
            glyphColor = tint
        }

        return ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: AmgiRadius.control, style: .continuous)
                .fill(fill)
                .frame(width: 40, height: 40)
                .overlay(
                    Text(resolved.display)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(glyphColor)
                )
            if isFiltered {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 14, height: 14)
                    .background(palette.customStudyBadge, in: Circle())
                    .offset(x: 4, y: 4)
            }
        }
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Due row") {
    StudyDeckRow(
        data: StudyDeckRowData(
            id: 1,
            name: "한국어 · Vocab Typing",
            totalDue: 25,
            newCount: 10,
            learnCount: 8,
            reviewCount: 7,
            isFiltered: false
        ),
        onTap: {}
    )
    .padding()
    .environment(\.palette, .vividLight)
}

#Preview("Filtered deck") {
    StudyDeckRow(
        data: StudyDeckRowData(
            id: 2,
            name: "Hard cards only",
            totalDue: 24,
            newCount: 0,
            learnCount: 0,
            reviewCount: 24,
            isFiltered: true
        ),
        onTap: {}
    )
    .padding()
    .environment(\.palette, .vividLight)
}

#Preview("Parent with chevron (expanded)") {
    StudyDeckRow(
        data: StudyDeckRowData(
            id: 3,
            name: "한국어",
            totalDue: 25,
            newCount: 10,
            learnCount: 8,
            reviewCount: 7,
            isFiltered: false,
            subdecks: [
                StudyDeckRowData(id: 31, name: "Vocab Typing", totalDue: 15, newCount: 6, learnCount: 5, reviewCount: 4, isFiltered: false),
                StudyDeckRowData(id: 32, name: "Sentences", totalDue: 10, newCount: 4, learnCount: 3, reviewCount: 3, isFiltered: false),
            ]
        ),
        isExpanded: true,
        onTap: {}
    )
    .padding()
    .environment(\.palette, .vividLight)
}

#Preview("Subdeck row") {
    StudyDeckRow(
        data: StudyDeckRowData(
            id: 31,
            name: "Vocab Typing",
            totalDue: 15,
            newCount: 6,
            learnCount: 5,
            reviewCount: 4,
            isFiltered: false
        ),
        depth: 1,
        onTap: {}
    )
    .padding()
    .environment(\.palette, .vividLight)
}
#endif

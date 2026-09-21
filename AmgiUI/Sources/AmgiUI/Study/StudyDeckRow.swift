public import SwiftUI
import AmgiTheme

/// One deck the desk can start. Mix counts say what the sitting contains;
/// subdecks are a caption, not a second list.
public struct StudyDeckRow: View {
    public let data: StudyDeckRowData
    public let onTap: () -> Void

    @Environment(\.palette) private var palette

    public init(data: StudyDeckRowData, onTap: @escaping () -> Void) {
        self.data = data
        self.onTap = onTap
    }

    public var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                StudyDeckTile(name: data.name, iconName: data.iconName, isFiltered: data.isFiltered)
                VStack(alignment: .leading, spacing: 2) {
                    Text(data.name)
                        .amgiFont(.body)
                        .fontWeight(.bold)
                        .foregroundStyle(palette.textPrimary)
                        .lineLimit(1)
                    if data.isFiltered {
                        Text("Extra session")
                            .amgiFont(.caption)
                            .foregroundStyle(palette.customStudyBadge)
                    } else if !mixLabel.isEmpty {
                        Text(mixLabel)
                            .amgiFont(.caption)
                            .foregroundStyle(palette.textSecondary)
                            .lineLimit(1)
                    }
                    if let includes = data.includesLabel {
                        Text(includes)
                            .amgiFont(.caption)
                            .foregroundStyle(palette.textTertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 12)
                Text("\(data.totalDue)")
                    .amgiFont(.caption)
                    .fontWeight(.bold)
                    .monospacedDigit()
                    .foregroundStyle(palette.textPrimary)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressScale)
    }

    private var mixLabel: String {
        var parts: [String] = []
        if data.newCount > 0 { parts.append("\(data.newCount) new") }
        if data.learnCount > 0 { parts.append("\(data.learnCount) learn") }
        if data.reviewCount > 0 { parts.append("\(data.reviewCount) review") }
        return parts.joined(separator: " · ")
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

#Preview("With subdecks") {
    StudyDeckRow(
        data: StudyDeckRowData(
            id: 3,
            name: "한국어",
            totalDue: 25,
            newCount: 10,
            learnCount: 8,
            reviewCount: 7,
            isFiltered: false,
            includesLabel: "Includes Vocab Typing, Sentences"
        ),
        onTap: {}
    )
    .padding()
    .environment(\.palette, .vividLight)
}
#endif

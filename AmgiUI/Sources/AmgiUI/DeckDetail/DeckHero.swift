public import SwiftUI
import AmgiTheme

/// Hero block at the top of the deck-detail screen: gradient tile +
/// large title + Custom Study chip + subtitle line.
public struct DeckHero: View {
    public let title: String
    public let subtitle: String
    public let tone: Color
    public let deckName: String
    public let iconName: String?
    public let isFiltered: Bool

    @Environment(\.palette) private var palette
    @State private var wrappedTitleHeight: CGFloat = 0
    @State private var singleLineTitleHeight: CGFloat = 0

    private var titleFontSize: CGFloat {
        guard singleLineTitleHeight > 0 else { return 32 }
        let lines = Int(((wrappedTitleHeight + 2) / (singleLineTitleHeight + 2)).rounded())
        switch lines {
        case ...1: return 32
        case 2: return 28
        case 3: return 24
        default: return 22
        }
    }

    public init(
        title: String,
        subtitle: String,
        tone: Color,
        deckName: String,
        iconName: String? = nil,
        isFiltered: Bool
    ) {
        self.title = title
        self.subtitle = subtitle
        self.tone = tone
        self.deckName = deckName
        self.iconName = iconName
        self.isFiltered = isFiltered
    }

    public var body: some View {
        #if os(iOS)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                DeckHeroTile(tone: tone, deckName: deckName, iconName: iconName, size: 48)
                inlineTitleRow
            }
            subtitleText
        }
        #else
        VStack(alignment: .leading, spacing: 4) {
            DeckHeroTile(tone: tone, deckName: deckName, iconName: iconName)
                .padding(.bottom, 8)
            titleRow
            subtitleText
        }
        #endif
    }

    private var inlineTitleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .amgiFont(size: titleFontSize, weight: .bold)
                .lineSpacing(2)
                .foregroundStyle(palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(alignment: .topLeading) {
                    titleMeasurement
                }
            if isFiltered { customStudyChip }
        }
    }

    // Measure at a fixed base size so shrinking the visible title cannot change its size tier.
    private var titleMeasurement: some View {
        Text(title)
            .amgiFont(size: 32, weight: .bold)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                wrappedTitleHeight = height
            }
            .background(alignment: .topLeading) {
                Text(title)
                    .amgiFont(size: 32, weight: .bold)
                    .lineLimit(1)
                    .fixedSize()
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { height in
                        singleLineTitleHeight = height
                    }
            }
            .hidden()
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }

    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .amgiFont(size: 32, weight: .bold)
                .lineSpacing(2)
                .foregroundStyle(palette.textPrimary)
            if isFiltered {
                customStudyChip
            }
        }
        .padding(.top, 4)
    }

    private var customStudyChip: some View {
        HStack(spacing: 4) {
            Image(systemName: "bolt.fill")
                .font(.caption.weight(.semibold))
            Text("Custom Study")
                .amgiFont(size: 11, weight: .semibold)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(palette.customStudyBadge, in: Capsule())
        .accessibilityLabel("Custom study deck")
    }

    private var subtitleText: some View {
        Text(subtitle)
            .amgiFont(size: 15, weight: .regular, tracking: -0.24)
            .foregroundStyle(palette.textSecondary)
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Hero — standard") {
    DeckHero(
        title: "한국어",
        subtitle: "Last studied today · 32-day streak",
        tone: .red,
        deckName: "🇰🇷 한국어",
        isFiltered: false
    )
    .padding()
    .environment(\.palette, .vividLight)
}

#Preview("Hero — filtered chip") {
    DeckHero(
        title: "한국어",
        subtitle: "Last studied today · 32-day streak",
        tone: .red,
        deckName: "🇰🇷 한국어",
        isFiltered: true
    )
    .padding()
    .environment(\.palette, .vividLight)
}

#Preview("Hero — empty deck copy") {
    DeckHero(
        title: "Fresh deck",
        subtitle: "No cards yet · Add some to start studying",
        tone: .blue,
        deckName: "📚 Fresh deck",
        isFiltered: false
    )
    .padding()
    .environment(\.palette, .vividLight)
}
#endif

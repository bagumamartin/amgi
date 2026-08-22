public import SwiftUI
import AmgiTheme

/// Bridge letting hosts supply deck-icon glyphs without linking an icon
/// library. The app registers a provider at startup that maps a persisted
/// icon name (Phosphor camelCase case name, e.g. "airTrafficControl") to a
/// SwiftUI `Image`; the watch app leaves it nil and keeps letter tiles.
///
/// Kept as a registration hook instead of a dependency because Phosphor's
/// package doesn't declare watchOS support and `AmgiUI` builds for it.
@MainActor
public enum DeckIconRendering {
    /// Maps a persisted icon name to a renderable glyph, or nil when the
    /// name is unknown / no host registered.
    public static var provider: ((_ iconName: String) -> Image?)?

    /// True when the deck name starts with an emoji-presentation character
    /// (e.g. "🇰🇷 한국어"). Containers use this to let a user's deliberate
    /// emoji prefix keep the legacy tile instead of an auto-suggested icon.
    public static func hasLeadingEmoji(in name: String) -> Bool {
        guard let first = name.trimmingCharacters(in: .whitespacesAndNewlines).first,
              let scalar = first.unicodeScalars.first,
              scalar.properties.isEmoji
        else { return false }
        return scalar.properties.isEmojiPresentation
            || first.unicodeScalars.contains(where: { $0 == "\u{FE0F}" })
    }
}

/// The deck-icon tile style used everywhere an explicit icon is shown:
/// **subtly tinted background + prominently tinted glyph** — the monogram
/// treatment from `DeckTileGlyph`, not the solid-fill letter tile. One view
/// so Library rows, the detail hero, Study rows, and subdeck rows stay
/// pixel-consistent.
public struct DeckIconTile: View {
    let iconName: String
    let deckName: String
    let size: CGFloat
    let cornerRadius: CGFloat

    @Environment(\.palette) private var palette

    public init(
        iconName: String,
        deckName: String,
        size: CGFloat,
        cornerRadius: CGFloat
    ) {
        self.iconName = iconName
        self.deckName = deckName
        self.size = size
        self.cornerRadius = cornerRadius
    }

    public var body: some View {
        Group {
            if let glyph = DeckIconRendering.provider?(iconName) {
                glyph
            } else {
                // Unknown name (catalog drift): degrade to the stack glyph
                // rather than rendering an empty tile.
                Image(systemName: "rectangle.stack")
            }
        }
        .font(.system(size: size * 0.5))
        .foregroundStyle(DeckTileGlyph.tint(for: deckName, palette: palette))
        .frame(width: size, height: size)
        .background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(DeckTileGlyph.tint(for: deckName, palette: palette).opacity(0.11))
        )
    }
}

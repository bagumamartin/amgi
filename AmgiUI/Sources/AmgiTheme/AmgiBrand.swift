public import SwiftUI

/// Amgi's brand violet. Theme-independent — the per-theme `accent` in
/// `Resources/themes/*.json` is picked from this ramp (or toned from it for
/// Muted/Sepia). Use `palette.accent` in UI; reach for these only where a
/// colour must not follow the theme (marketing surfaces, avatars, icons).
public enum AmgiBrand {
    public static let violet50  = Color(hex: 0xF3F0FF)
    public static let violet100 = Color(hex: 0xE6E0FF)
    public static let violet200 = Color(hex: 0xCCC0FF)
    public static let violet300 = Color(hex: 0xA592FF)
    public static let violet400 = Color(hex: 0x8A72F5)
    public static let violet500 = Color(hex: 0x6E52E8)
    public static let violet600 = Color(hex: 0x5B3FD9)
    public static let violet700 = Color(hex: 0x4A30B8)
    public static let violet800 = Color(hex: 0x3A2590)
    public static let violet900 = Color(hex: 0x2A1B66)
}

// MARK: - Hex helper (file-private)

private extension Color {
    /// Same body as `Palette.swift`'s `hex` helper, which is private to its
    /// own file. Deliberately not named `fromHex` — that one parses the
    /// `"#RRGGBB"` strings the theme JSONs carry, not a `UInt32` literal.
    init(hex value: UInt32) {
        let r = Double((value >> 16) & 0xFF) / 255.0
        let g = Double((value >> 8) & 0xFF) / 255.0
        let b = Double(value & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}

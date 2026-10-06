public import SwiftUI

/// Anki packs the flag into the low three bits of a card's `flags` field.
public enum CardFlag {
    /// `0` is "no flag"; 1–7 are the seven colours, in Anki's order.
    public static let all: [UInt32] = [0, 1, 2, 3, 4, 5, 6, 7]

    public static func name(_ value: UInt32) -> String {
        switch value & 0b111 {
        case 1: return L10n.text("Red")
        case 2: return L10n.text("Orange")
        case 3: return L10n.text("Green")
        case 4: return L10n.text("Blue")
        case 5: return L10n.text("Pink")
        case 6: return L10n.text("Cyan")
        case 7: return L10n.text("Purple")
        default: return L10n.text("No flag")
        }
    }

    public static func color(_ value: UInt32) -> Color {
        switch value & 0b111 {
        case 1: return .red
        case 2: return .orange
        case 3: return .green
        case 4: return .blue
        case 5: return .pink
        case 6: return .cyan
        case 7: return .purple
        default: return .secondary
        }
    }

    public static func symbol(_ value: UInt32) -> String {
        value & 0b111 == 0 ? "flag.slash.fill" : "flag.fill"
    }
}

import SwiftUI
import AmgiUI
import AmgiTheme

/// Which card states are present in a sidebar deck or tag — presence only,
/// not counts. A parked 4k-card deck and a deck with one suspended card
/// both light the pause glyph.
struct SourcePresence: Equatable, Sendable {
    static let empty = SourcePresence()

    var suspended = false
    var buried = false
    /// Bit *n* set means flag *n* is present (1…7).
    var flagBits: UInt8 = 0

    var isEmpty: Bool { !suspended && !buried && flagBits == 0 }

    var presentFlags: [UInt32] {
        (1...7).compactMap { flagBits & (1 << $0) != 0 ? UInt32($0) : nil }
    }

    mutating func apply(suspended hit: Bool) { if hit { suspended = true } }
    mutating func apply(buried hit: Bool) { if hit { buried = true } }
    mutating func apply(flag: UInt32, hit: Bool) {
        guard hit, flag >= 1, flag <= 7 else { return }
        flagBits |= 1 << flag
    }

    var accessibilityLabel: String {
        var parts: [String] = []
        if suspended { parts.append("Suspended") }
        if buried { parts.append("Buried") }
        let names = presentFlags.map { flagName(for: $0) }
        if names.count == 1 {
            parts.append("\(names[0]) flag")
        } else if names.count > 1 {
            let listed = names.dropLast().joined(separator: ", ")
            parts.append("\(listed) and \(names.last!) flags")
        }
        return parts.joined(separator: ", ")
    }

    private func flagName(for value: UInt32) -> String {
        switch value {
        case 1: "Red"
        case 2: "Orange"
        case 3: "Green"
        case 4: "Blue"
        case 5: "Pink"
        case 6: "Turquoise"
        case 7: "Purple"
        default: "Flag \(value)"
        }
    }
}

/// Trailing cluster for deck and tag rows. Hidden when nothing is present.
struct BrowsePresenceGlyphs: View {
    @Environment(\.palette) private var palette
    let presence: SourcePresence

    var body: some View {
        if !presence.isEmpty {
            HStack(spacing: 3) {
                if presence.suspended {
                    Image(systemName: "pause.circle")
                        .amgiFont(.micro)
                        .foregroundStyle(palette.cardStateSuspended)
                }
                if presence.buried {
                    Image(systemName: "archivebox")
                        .amgiFont(.micro)
                        .foregroundStyle(palette.warning)
                }
                ForEach(presence.presentFlags, id: \.self) { flag in
                    if let color = BrowseFlagSwatch.color(for: flag) {
                        Circle()
                            .fill(color)
                            .frame(width: 8, height: 8)
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(presence.accessibilityLabel)
        }
    }
}

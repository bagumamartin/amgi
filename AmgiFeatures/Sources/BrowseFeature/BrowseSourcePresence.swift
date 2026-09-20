import SwiftUI
import AmgiUI
import AmgiTheme

/// How much of a sidebar scope matches a card state.
enum PresenceLevel: Equatable, Sendable {
    case none, partial, full

    var isPresent: Bool { self != .none }

    static func comparing(_ count: Int, to total: Int) -> PresenceLevel {
        guard count > 0, total > 0 else { return .none }
        return count >= total ? .full : .partial
    }
}

/// Suspended / buried / flag coverage for a deck or tag. `.full` means every
/// card in the row's query is in that state; `.partial` means some are.
struct SourcePresence: Equatable, Sendable {
    static let empty = SourcePresence()

    var suspended: PresenceLevel = .none
    var buried: PresenceLevel = .none
    /// Index 1…7; unused slot 0 stays `.none`.
    var flags: [PresenceLevel] = Array(repeating: .none, count: 8)

    var isEmpty: Bool {
        !suspended.isPresent && !buried.isPresent && presentFlags.isEmpty
    }

    var presentFlags: [UInt32] {
        (1...7).compactMap { flags[Int($0)].isPresent ? $0 : nil }
    }

    func flagLevel(_ value: UInt32) -> PresenceLevel {
        guard value >= 1, value <= 7 else { return .none }
        return flags[Int(value)]
    }

    var accessibilityLabel: String {
        var parts: [String] = []
        if let text = phrase(suspended, full: "Fully suspended", partial: "Partially suspended") {
            parts.append(text)
        }
        if let text = phrase(buried, full: "Fully buried", partial: "Partially buried") {
            parts.append(text)
        }
        for flag in presentFlags {
            let name = flagName(for: flag)
            switch flagLevel(flag) {
            case .full: parts.append("All \(name) flags")
            case .partial: parts.append("Some \(name) flags")
            case .none: break
            }
        }
        return parts.joined(separator: ", ")
    }

    private func phrase(_ level: PresenceLevel, full: String, partial: String) -> String? {
        switch level {
        case .none: nil
        case .full: full
        case .partial: partial
        }
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
/// Filled glyphs are the whole group; outlined / washed glyphs are mixed.
struct BrowsePresenceGlyphs: View {
    @Environment(\.palette) private var palette
    let presence: SourcePresence

    var body: some View {
        if !presence.isEmpty {
            HStack(spacing: 3) {
                if presence.suspended.isPresent {
                    Image(systemName: presence.suspended == .full ? "pause.circle.fill" : "pause.circle")
                        .amgiFont(.micro)
                        .foregroundStyle(palette.cardStateSuspended.opacity(presence.suspended == .full ? 1 : 0.55))
                }
                if presence.buried.isPresent {
                    Image(systemName: presence.buried == .full ? "archivebox.fill" : "archivebox")
                        .amgiFont(.micro)
                        .foregroundStyle(palette.warning.opacity(presence.buried == .full ? 1 : 0.55))
                }
                ForEach(presence.presentFlags, id: \.self) { flag in
                    if let color = BrowseFlagSwatch.color(for: flag) {
                        flagDot(level: presence.flagLevel(flag), color: color)
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(presence.accessibilityLabel)
        }
    }

    @ViewBuilder
    private func flagDot(level: PresenceLevel, color: Color) -> some View {
        if level == .full {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
        } else {
            Circle()
                .strokeBorder(color.opacity(0.85), lineWidth: 1.5)
                .frame(width: 8, height: 8)
        }
    }
}

import Foundation
public import SwiftUI
public import PhosphorSwift

// Trivial no-associated-value enum from another module; Sendable is factual.
// `@retroactive`: drop this extension if upstream ever declares it itself.
extension Ph: @retroactive @unchecked Sendable {}


/// Bridges the Phosphor catalog to this feature's persistence + suggestion
/// conventions.
///
/// - Icon names are persisted and embedded as **camelCase Swift case
///   names** (`"airTrafficControl"`) — the same keys used by the tag
///   manifest that produced `IconEmbeddings.json`.
/// - `Ph` raw values are kebab-case asset names (`"air-traffic-control"`),
///   so plain `Ph(rawValue:)` only works for single-word icons. The index
///   below converts kebab → camel to cover all cases, including ``Ph.`repeat```
///   (a Swift keyword, backticked at use sites).
public extension Ph {
    /// The camelCase identifier for this icon (persistence format).
    var amgiCaseName: String {
        Self.camelCaseName(fromRawValue: rawValue)
    }

    /// Resolves a camelCase (or kebab-case) icon name back to an icon.
    static func amgi(named name: String) -> Ph? {
        amgiIndex[name] ?? Ph(rawValue: name)
    }

    /// All cases indexed by their camelCase identifier.
    static let amgiIndex: [String: Ph] = Dictionary(
        uniqueKeysWithValues: allCases.map { ($0.amgiCaseName, $0) }
    )

    private static func camelCaseName(fromRawValue rawValue: String) -> String {
        let parts = rawValue.split(separator: "-").map(String.init)
        guard let first = parts.first else { return rawValue }
        return first + parts.dropFirst().map { $0.capitalized }.joined()
    }

    // MARK: Curated top picks

    /// Hand-picked subject-relevant subset shown as the picker's default
    /// browse view. 1,512 icons is unwieldy as a landing grid; searching
    /// falls through to the full set.
    static let deckTopPicks: [Ph] = [
        // Study & school
        .book, .books, .bookOpen, .bookmark, .brain, .graduationCap,
        .chalkboardTeacher, .exam, .notebook, .note, .pencil, .lightbulb,
        .translate, .quotes, .article, .newspaper,
        // Science
        .atom, .flask, .testTube, .microscope, .dna, .pill, .firstAid,
        .stethoscope, .heartbeat,
        // Math & data
        .calculator, .function, .chartLineUp, .chartPie, .chartDonut,
        .database, .binary,
        // Tech
        .code, .bracketsCurly, .keyboard, .cpu, .robot,
        // Arts & media
        .musicNotes, .guitar, .pianoKeys, .microphone, .palette,
        .paintBrush, .camera, .filmReel, .gameController, .puzzlePiece,
        // Sports
        .soccerBall, .basketball, .tennisBall, .bicycle,
        // Nature & life
        .leaf, .tree, .flower, .bug, .cat, .dog, .bird, .fish,
        .mountains, .campfire, .globe,
        // Places & travel
        .mapTrifold, .mapPin, .compass, .airplane, .car,
        // Society
        .scales, .gavel, .bank, .creditCard, .coins, .piggyBank,
        .briefcase, .users, .user,
        // Misc
        .heart, .star, .fire, .clock, .calendar, .listChecks, .tag,
        .archive, .folder, .envelope, .chat, .coffee, .pizza,
    ]

    /// Plain-text fallback used when the semantic match is below threshold:
    /// finds an icon whose name tokens overlap the deck name's words
    /// (e.g. "Music Theory" → `musicNotes` via "music").
    static func bestByNameToken(in text: String) -> Ph? {
        let folded = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: nil
        )
        let words = Set(
            folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
                .filter { $0.count >= 3 }
        )
        guard !words.isEmpty else { return nil }

        var best: (tokenLength: Int, icon: Ph)?
        for icon in allCases {
            for token in iconNameTokens(icon.amgiCaseName) where words.contains(token) {
                if best == nil || token.count > best!.tokenLength {
                    best = (token.count, icon)
                }
            }
        }
        return best?.icon
    }

    private static func iconNameTokens(_ name: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        for ch in name {
            if ch.isUppercase, !current.isEmpty {
                tokens.append(current.lowercased())
                current = String(ch)
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { tokens.append(current.lowercased()) }
        return tokens
    }
}

// MARK: - Host-facing glyph helper

/// Single entry point hosts need to render a persisted icon name — keeps
/// app targets from importing PhosphorSwift directly.
public enum DeckIconGlyph {
    /// SwiftUI image for a camelCase icon name, or nil when unknown.
    public static func image(for iconName: String) -> Image? {
        Ph.amgi(named: iconName)?.regular
    }
}

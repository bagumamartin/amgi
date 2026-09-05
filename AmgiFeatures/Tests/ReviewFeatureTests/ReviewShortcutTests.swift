import Testing
import SwiftUI
@testable import ReviewFeature

@Suite struct ReviewShortcutTests {
    @Test func functionKeyArrowsMapToSwiftUIArrowEquivalents() {
        let up = ReviewShortcut(key: "\u{F700}", modifiers: [])
        let down = ReviewShortcut(key: "\u{F701}", modifiers: [])
        let left = ReviewShortcut(key: "\u{F702}", modifiers: [])
        let right = ReviewShortcut(key: "\u{F703}", modifiers: [])
        #expect(up.keyEquivalent == .upArrow)
        #expect(down.keyEquivalent == .downArrow)
        #expect(left.keyEquivalent == .leftArrow)
        #expect(right.keyEquivalent == .rightArrow)
    }

    @Test func arrowGlyphsRecordedInSettingsStillMatch() {
        #expect(ReviewShortcut.keysMatch(.upArrow, stored: "↑"))
        #expect(ReviewShortcut.keysMatch(.downArrow, stored: "↓"))
        #expect(ReviewShortcut.keysMatch(.leftArrow, stored: "←"))
        #expect(ReviewShortcut.keysMatch(.rightArrow, stored: "→"))
        #expect(ReviewShortcut.keysMatch(.upArrow, stored: "\u{F700}"))
    }

    @Test func spaceAndLettersMatchCaseInsensitively() {
        #expect(ReviewShortcut.keysMatch(.space, stored: " "))
        let undo = ReviewShortcut(key: "z", modifiers: .command)
        #expect(undo.keyEquivalent == KeyEquivalent("z"))
    }

    @Test func displayStringShowsArrowGlyphs() {
        #expect(ReviewShortcut(key: "\u{F700}", modifiers: []).displayString == "↑")
        #expect(ReviewShortcut(key: " ", modifiers: []).displayString == "Space")
    }
}

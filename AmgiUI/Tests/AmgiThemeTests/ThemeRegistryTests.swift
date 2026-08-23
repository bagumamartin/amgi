// AmgiUI/Tests/AmgiThemeTests/ThemeRegistryTests.swift
import Testing
import SwiftUI
@testable import AmgiTheme

@Suite("ThemeRegistry")
struct ThemeRegistryTests {
    @Test(arguments: ["vivid", "muted", "sepia"])
    func bootLoadsBundledTheme(id: String) {
        #expect(ThemeRegistry.shared.allThemes().map(\.id).contains(id))
    }

    @Test func paletteForKnownThemeLight() {
        let palette = ThemeRegistry.shared.palette(id: .vivid, scheme: .light)
        #expect(palette.accent != palette.background)
    }

    @Test func paletteFallsBackToMinimalWhenIDUnknown() {
        let palette = ThemeRegistry.shared.palette(id: ThemeID(rawValue: "no-such-theme"), scheme: .light)
        #expect(palette.accent == ThemeRegistry.shared.palette(id: .minimal, scheme: .light).accent)
    }

    @Test func sepiaDarkSchemeReadsFromJSON() {
        // Sepia.json's dark section duplicates Vivid Dark's values. The
        // registry doesn't fall back at runtime — it reads what JSON says.
        let sepiaDark = ThemeRegistry.shared.palette(id: .sepia, scheme: .dark)
        let vividDark = ThemeRegistry.shared.palette(id: .vivid, scheme: .dark)
        #expect(sepiaDark.background == vividDark.background)
    }
}

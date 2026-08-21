import XCTest
import SwiftUI
@testable import AmgiTheme

@MainActor
final class ThemeManagerTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    // The `async throws` overrides, not the plain ones: `ThemeManager` is
    // @MainActor, so the class is too, and only these variants inherit that
    // isolation — the synchronous ones stay nonisolated and can't touch the
    // stored properties.
    override func setUp() async throws {
        try await super.setUp()
        suiteName = "test-suite-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    func testDefaultValuesOnEmptyStore() {
        let manager = ThemeManager(defaults: defaults)
        XCTAssertEqual(manager.themeID, .minimal)
        XCTAssertEqual(manager.appearance, .system)
    }

    func testSettingThemeIDPersists() {
        let m1 = ThemeManager(defaults: defaults)
        m1.themeID = .sepia
        m1.appearance = .dark

        let m2 = ThemeManager(defaults: defaults)
        XCTAssertEqual(m2.themeID, .sepia)
        XCTAssertEqual(m2.appearance, .dark)
    }

    func testPaletteResolvesThroughRegistry() {
        let manager = ThemeManager(defaults: defaults)
        manager.themeID = .sepia
        let palette = manager.palette(for: .light)
        let expected = ThemeRegistry.shared.palette(id: .sepia, scheme: .light)
        XCTAssertEqual(palette.background, expected.background)
        XCTAssertEqual(palette.accent, expected.accent)
    }

    func testAppearanceLightOverridesSystemScheme() {
        let manager = ThemeManager(defaults: defaults)
        manager.appearance = .light
        // Even with systemScheme=.dark, .light appearance should pick the light palette
        let palette = manager.palette(for: .dark)
        let expected = ThemeRegistry.shared.palette(id: .minimal, scheme: .light)
        XCTAssertEqual(palette.background, expected.background)
    }

    func testReadsLegacyThemeKeyOnFirstUpgrade() {
        // Pre-populate the suite with only the legacy key
        defaults.set("muted", forKey: "theme.selection")
        let manager = ThemeManager(defaults: defaults)
        XCTAssertEqual(manager.themeID, .muted)
    }
}

public import Foundation
public import SwiftUI

@Observable
public final class ThemeManager: @unchecked Sendable {
    public static let shared = ThemeManager()

    public var themeID: ThemeID {
        didSet { defaults.set(themeID.rawValue, forKey: Keys.themeID) }
    }

    public var appearance: Appearance {
        didSet { defaults.set(appearance.rawValue, forKey: Keys.appearance) }
    }

    private let defaults: UserDefaults
    private let registry: ThemeRegistry

    public init(defaults: UserDefaults = .amgiAppGroup, registry: ThemeRegistry = .shared) {
        self.defaults = defaults
        self.registry = registry
        // First-upgrade backfill: read the legacy "theme.selection" key when
        // the new "theme.id" key isn't present yet. The didSet on themeID
        // will write the new key on the next change, so this only fires once.
        self.themeID = Self.storedThemeID(in: defaults) ?? .minimal
        self.appearance = Self.storedAppearance(in: defaults) ?? .system
    }

    public func palette(for systemScheme: ColorScheme) -> Palette {
        let resolved: ColorScheme
        switch appearance {
        case .system: resolved = systemScheme
        case .light: resolved = .light
        case .dark: resolved = .dark
        }
        return registry.palette(id: themeID, scheme: resolved)
    }

    /// Re-reads theme + appearance from defaults. Widget extensions and
    /// other long-lived out-of-process readers must call this per timeline
    /// reload — a widget process can serve several reloads, and the cached
    /// `themeID` would otherwise keep a theme the user changed in the app.
    public func refreshFromDefaults() {
        themeID = Self.storedThemeID(in: defaults) ?? themeID
        appearance = Self.storedAppearance(in: defaults) ?? appearance
    }

    private static func storedThemeID(in defaults: UserDefaults) -> ThemeID? {
        let storedRaw = defaults.string(forKey: Keys.themeID)
            ?? defaults.string(forKey: Keys.legacyTheme)
        return storedRaw.flatMap(ThemeID.init(rawValue:))
    }

    private static func storedAppearance(in defaults: UserDefaults) -> Appearance? {
        defaults.string(forKey: Keys.appearance).flatMap(Appearance.init(rawValue:))
    }

    /// Resolve the active theme for an *explicit* scheme, ignoring the user's
    /// appearance override. Used by surfaces that must match a specific
    /// light/dark background (like the review chrome adopting a card's own
    /// background colour) rather than the system appearance.
    public func palette(forExplicitScheme scheme: ColorScheme) -> Palette {
        registry.palette(id: themeID, scheme: scheme)
    }

    private enum Keys {
        static let themeID = "theme.id"
        static let legacyTheme = "theme.selection"
        static let appearance = "theme.appearance"
    }
}

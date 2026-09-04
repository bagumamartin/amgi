public import Foundation

public extension UserDefaults {
    /// App Group store shared across the iOS app, widget extension, and watch app.
    /// Falls back to `.standard` if the App Group entitlement is missing
    /// (e.g. running unit tests outside the app sandbox), so callers can always
    /// read/write something. Tests should pass in their own `UserDefaults` instance.
    ///
    /// Marked `nonisolated(unsafe)` because `UserDefaults` is documented thread-safe
    /// but not `Sendable`-conforming on this SDK. Required so the widget extension
    /// and watch app (non-main contexts) can read the same store.
    nonisolated(unsafe) static let amgiAppGroup: UserDefaults = {
        // Must match AmgiAppCore.AppGroup.identifier and both .entitlements
        // files. AmgiTheme is dependency-free on purpose, so it cannot
        // import the canonical constant — `AppGroup.identifier` is the
        // local copy (personal team `group.com.bagumamartin.AmgiApp`).
        let defaults = UserDefaults(suiteName: AppGroup.identifier) ?? .standard
        // One-time migration: copy values the previous suites still hold
        // (selected theme, etc.) so preferences survive an ID rename.
        // HEAD used the unprefixed `group.com.amgiapp`; the macOS branch
        // used the Team-ID-prefixed personal-team ID.
        migrateLegacySuite("group.com.amgiapp", into: defaults)
        migrateLegacySuite(AppGroup.legacyIdentifier, into: defaults)
        return defaults
    }()

    /// Copies keys from `suiteName` that are missing on `defaults`.
    private static func migrateLegacySuite(_ suiteName: String, into defaults: UserDefaults) {
        guard suiteName != AppGroup.identifier,
              let legacy = UserDefaults(suiteName: suiteName)
        else { return }
        let current = defaults.dictionaryRepresentation()
        for (key, value) in legacy.dictionaryRepresentation() where current[key] == nil {
            defaults.set(value, forKey: key)
        }
    }
}

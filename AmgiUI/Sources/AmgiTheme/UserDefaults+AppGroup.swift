public import Foundation

public extension UserDefaults {
    /// App Group store shared across the iOS/iPadOS app, Mac app, widgets, and watch.
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
        // local copy.
        let defaults = UserDefaults(suiteName: AppGroup.identifier) ?? .standard
        // One-time migration: copy values previous suites still hold so
        // preferences survive both the original app-group rename and the
        // later Amgi -> Ijuka rebrand. Missing values never overwrite newer
        // state, and each suite is consulted oldest-first.
        for legacyID in [
            "group.com.amgiapp",
            "group.com.bagumamartin.AmgiApp",
            "39557WW39R.group.com.bagumamartin.AmgiApp",
        ] {
            migrateLegacySuite(legacyID, into: defaults)
        }
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

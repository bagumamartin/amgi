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
        let defaults = UserDefaults(suiteName: AppGroup.identifier) ?? .standard
        // One-time migration: when the App Group gained its Team-ID prefix
        // (required by macOS), the container moved to a new directory. Copy
        // any values the previous suite still holds (e.g. the selected theme)
        // so preferences survive the switch.
        if let legacy = UserDefaults(suiteName: AppGroup.legacyIdentifier) {
            let current = defaults.dictionaryRepresentation()
            for (key, value) in legacy.dictionaryRepresentation() where current[key] == nil {
                defaults.set(value, forKey: key)
            }
        }
        return defaults
    }()
}

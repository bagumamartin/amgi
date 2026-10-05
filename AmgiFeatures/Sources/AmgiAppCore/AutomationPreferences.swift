import Foundation

/// User-controlled privacy and availability choices shared by App Intents,
/// Spotlight, and the in-app Study Assistant. Defaults are deliberately
/// conservative: deck names are searchable, private note titles are not shown
/// by system surfaces unless explicitly enabled, and generation can always be
/// turned off without disabling deterministic study features.
public enum AutomationPreferences: Sendable {
    public static let spotlightDeckNamesKey = "automation.spotlight.deckNames"
    public static let exposeNoteTitlesKey = "automation.system.exposeNoteTitles"
    public static let foundationModelsEnabledKey = "automation.foundationModels.enabled"

    public static var spotlightDeckNames: Bool {
        get { bool(forKey: spotlightDeckNamesKey, default: true) }
        set { UserDefaults.standard.set(newValue, forKey: spotlightDeckNamesKey) }
    }

    public static var exposesNoteTitles: Bool {
        get { bool(forKey: exposeNoteTitlesKey, default: false) }
        set { UserDefaults.standard.set(newValue, forKey: exposeNoteTitlesKey) }
    }

    public static var foundationModelsEnabled: Bool {
        get { bool(forKey: foundationModelsEnabledKey, default: true) }
        set { UserDefaults.standard.set(newValue, forKey: foundationModelsEnabledKey) }
    }

    private static func bool(forKey key: String, default defaultValue: Bool) -> Bool {
        guard UserDefaults.standard.object(forKey: key) != nil else { return defaultValue }
        return UserDefaults.standard.bool(forKey: key)
    }
}

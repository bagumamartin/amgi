import Foundation

/// One-time continuity for installations that predate the Ijuka rebrand.
/// Bundle-ID changes give the app a fresh standard defaults/container, while
/// the historical app groups remain entitled long enough to recover profile
/// and appearance state. Collection files are migrated separately by
/// `CollectionLayout`.
public enum LegacyAmgiMigration {
    public static func run() {
        let standard = UserDefaults.standard
        var current = standard.dictionaryRepresentation()

        // The current app group may already contain the canonical profile
        // selection written by a widget or a pre-rebrand build. Recover it
        // before consulting older groups.
        let sources = [AppGroup.defaults] + AppGroup.legacyIdentifiers.compactMap {
            UserDefaults(suiteName: $0)
        }
        for source in sources {
            for (key, value) in source.dictionaryRepresentation() where current[key] == nil {
                standard.set(value, forKey: key)
                current[key] = value
            }
        }
    }
}

public import Sharing

public enum NavigationPreferences {
    public static let rootSection = "amgi_root_section"
    public static let legacyRootSection = "amgi.root.section"
    public static let deckSortOrder = "amgi_deck_sort_order"
    /// Pre-rename key. Dotted keys break `@Shared`'s key-value observation,
    /// so this is kept only for a one-time migration.
    public static let legacyDeckSortOrder = "amgi.deck_sort_order"
}

public enum SyncMode: String, Sendable, RawRepresentable {
    case local
    case custom
}

extension SharedReaderKey where Self == AppStorageKey<Bool>.Default {
    public static var onboardingCompleted: Self {
        Self[.appStorage("onboardingCompleted"), default: false]
    }
}

extension SharedReaderKey where Self == AppStorageKey<SyncMode>.Default {
    public static var syncMode: Self {
        Self[.appStorage("syncMode"), default: .local]
    }
}

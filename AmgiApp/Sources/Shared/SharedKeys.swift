import Sharing

enum NavigationPreferences {
    static let rootSection = "amgi_root_section"
    static let legacyRootSection = "amgi.root.section"
    static let deckSortOrder = "amgi_deck_sort_order"
    /// Pre-rename key. Dotted keys break `@Shared`'s key-value observation,
    /// so this is kept only for a one-time migration.
    static let legacyDeckSortOrder = "amgi.deck_sort_order"
}

enum SyncMode: String, Sendable, RawRepresentable {
    case local
    case custom
}

extension SharedReaderKey where Self == AppStorageKey<Bool>.Default {
    static var onboardingCompleted: Self {
        Self[.appStorage("onboardingCompleted"), default: false]
    }
}

extension SharedReaderKey where Self == AppStorageKey<SyncMode>.Default {
    static var syncMode: Self {
        Self[.appStorage("syncMode"), default: .local]
    }
}

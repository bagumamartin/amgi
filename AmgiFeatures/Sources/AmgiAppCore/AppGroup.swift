public import Foundation

/// The App Group container shared by the app, the widget extension, and the
/// watch.
///
/// Canonical for everything that can see `AmgiAppCore`. Two copies of the
/// identifier live outside that reach and must be kept in sync by hand:
/// `AmgiTheme/AppGroup.swift` (AmgiTheme is deliberately dependency-free, so
/// it cannot import this) and the `.entitlements` files. A mismatch silently
/// splits the container in two, and the symptom — the widget reading an empty
/// store — looks nothing like a typo.
///
/// The ID is platform-dependent, mirroring the `[sdk=macosx*]` override of
/// `APP_GROUP_IDENTIFIER` in project.yml. iOS/watchOS require `group.`-prefixed
/// IDs; macOS sandboxed processes whose profile only carries the Team-ID
/// wildcard need the `39557WW39R.` prefix.
public enum AppGroup: Sendable {
    public static var identifier: String {
        #if os(macOS)
        "39557WW39R.group.com.bagumamartin.AmgiApp"
        #else
        "group.com.bagumamartin.AmgiApp"
        #endif
    }

    /// Shared defaults, falling back to `.standard` when the entitlement is
    /// missing, which is the case in previews and unit tests.
    public static var defaults: UserDefaults {
        UserDefaults(suiteName: identifier) ?? .standard
    }
}

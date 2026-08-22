/// Shared App Group container identifier used by the app, widget extension,
/// and watch app to exchange data (widget snapshots, shared preferences).
///
/// Kept as a single constant rather than derived from
/// `Bundle.main.bundleIdentifier` because the group is shared across targets
/// whose bundle IDs differ (`…AmgiApp`, `…AmgiApp.widget`, `…AmgiApp.watch`).
/// Must match the `com.apple.security.application-groups` entries in the app
/// and widget entitlements (`$(APP_GROUP_IDENTIFIER)` in project.yml).
///
/// The ID is platform-dependent, mirroring the `[sdk=macosx*]` override of
/// `APP_GROUP_IDENTIFIER` in project.yml — keep the two in sync. iOS requires
/// `group.`-prefixed IDs (Apple's signing server rejects anything else); macOS
/// requires the Team-ID prefix for sandboxed processes whose provisioning
/// profile doesn't list the ID explicitly (the widget extension's profile only
/// carries the `39557WW39R.*` wildcard, so the unprefixed ID was rejected and
/// the widget fell back to the empty snapshot).
public enum AppGroup {
    public static var identifier: String {
        #if os(macOS)
        return "39557WW39R.group.com.bagumamartin.AmgiApp"
        #else
        return "group.com.bagumamartin.AmgiApp"
        #endif
    }

    /// The unprefixed ID, kept so `UserDefaults.amgiAppGroup` can migrate
    /// preferences written to the old container before the macOS rename.
    public static let legacyIdentifier = "group.com.bagumamartin.AmgiApp"
}

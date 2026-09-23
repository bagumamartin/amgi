/// Shared App Group container identifier used by the app, widget extension,
/// and watch app to exchange data (widget snapshots, shared preferences).
///
/// Kept as a single constant rather than derived from
/// `Bundle.main.bundleIdentifier` because the group is shared across targets
/// whose bundle IDs differ (`…ijuka`, `…ijuka.widget`, `…ijuka.watch`).
/// Must match the `com.apple.security.application-groups` entries in the app
/// and widget entitlements (`$(APP_GROUP_IDENTIFIER)` in project.yml).
public enum AppGroup {
    public static let identifier = "group.com.bagumamartin.ijuka"
}

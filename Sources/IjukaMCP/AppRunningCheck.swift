import AppKit

/// Detects whether Ijuka.app is currently running. Backs the
/// `blockWritesWhileAppRunning` policy: the check runs per mutating tool
/// call (cheap — NSWorkspace caches the app list), so the gate reflects
/// live state even across long MCP sessions.
enum AppRunningCheck {
    static let appBundleID = "com.bagumamartin.ijuka"

    static var isIjukaRunning: Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == appBundleID
        }
    }
}

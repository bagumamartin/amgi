// AmgiApp/Sources/AmgiAppApp.swift
import SwiftUI
import RootFeature
#if os(macOS)
import AppKit
#endif

/// The iOS app target holds only `@main`. Dependency composition lives in
/// `AmgiRoot.bootstrap()` and view composition in `RootView`, both in the
/// `RootFeature` package target — which is what lets every other feature
/// module drop from `public` to `package`.
@main
struct AnkiAppApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AmgiAppDelegate.self) private var appDelegate
    #endif

    init() { AmgiRoot.bootstrap() }
    var body: some Scene { AmgiRoot.scenes }
}

#if os(macOS)
/// macOS single-instance guard for URL (widget-click) launches.
///
/// Clicking a widget delivers `amgi://study` through LaunchServices. When the
/// URL scheme is registered to a different copy of the app than the one
/// currently running (e.g. the Xcode-launched build in DerivedData vs. a copy
/// in /Applications), LaunchServices can start a second process. Detect that
/// here and hand off to the running instance instead of showing a duplicate
/// window. Normal launches (Run in Xcode, Dock, Finder) carry no URL and are
/// untouched.
///
/// Lives in the app target (not RootFeature): AppKit can only appear in
/// public API through a `public import`, which the feature module avoids.
@MainActor
private final class AmgiAppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let firstURL = urls.first, firstURL.scheme == "amgi" else { return }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let bundleID = Bundle.main.bundleIdentifier ?? "com.bagumamartin.AmgiApp"
        guard let existing = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .first(where: { $0.processIdentifier != ownPID })
        else { return } // First instance — SwiftUI's onOpenURL handles the URL.
        if #available(macOS 14.0, *) {
            existing.activate(options: [.activateAllWindows])
        } else {
            existing.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        }
        NSApp.terminate(nil)
    }
}
#endif

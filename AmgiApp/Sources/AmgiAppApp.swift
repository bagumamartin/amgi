// AmgiApp/Sources/AmgiAppApp.swift
import SwiftUI
import RootFeature
import WidgetFeature
import AppIntents
import AppIntentsFeature
#if os(macOS)
import AppKit
#endif
#if os(iOS)
import UIKit
#endif

struct IjukaAppIntents: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] {
        [
            IjukaRootIntentsPackage.self,
            IjukaAutomationIntentsPackage.self,
            IjukaWidgetIntentsPackage.self,
        ]
    }
}

/// The iOS app target holds only `@main`. Dependency composition lives in
/// `AmgiRoot.bootstrap()` and view composition in `RootView`, both in the
/// `RootFeature` package target — which is what lets every other feature
/// module drop from `public` to `package`.
@main
struct AnkiAppApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AmgiAppDelegate.self) private var appDelegate
    #endif
    #if os(iOS)
    @UIApplicationDelegateAdaptor(AmgiIOSAppDelegate.self) private var appDelegate
    #endif

    init() { AmgiRoot.bootstrap() }
    var body: some Scene { AmgiRoot.scenes }
}

#if os(iOS)
@MainActor
private final class AmgiIOSAppDelegate: NSObject, UIApplicationDelegate {
    private static var orientationMask: UIInterfaceOrientationMask =
        UIDevice.current.userInterfaceIdiom == .pad ? .all : .portrait
    private var orientationObserver: NSObjectProtocol?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        orientationObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("amgi.epub.orientationLockChanged"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let rawValue = notification.userInfo?["orientationMask"] as? UInt else { return }
            Task { @MainActor in self?.applyOrientationMask(UIInterfaceOrientationMask(rawValue: rawValue)) }
        }
        return true
    }

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        Self.orientationMask
    }

    private func applyOrientationMask(_ mask: UIInterfaceOrientationMask) {
        Self.orientationMask = mask
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
        }
    }
}
#endif

#if os(macOS)
/// macOS single-instance guard for URL and document launches.
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
        let forwardable = urls.filter { $0.scheme == "amgi" || $0.isFileURL }
        guard !forwardable.isEmpty else { return }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let bundleID = Bundle.main.bundleIdentifier ?? "com.bagumamartin.ijuka"
        guard let existing = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .first(where: { $0.processIdentifier != ownPID })
        else { return } // First instance — SwiftUI's onOpenURL handles the URL.

        // Activation alone does not replay LaunchServices' payload into the
        // already-running process. Forward every URL explicitly before this
        // duplicate exits so widget, deep-link, Finder, and Files opens keep
        // their destination and multi-file selections.
        for url in forwardable {
            DistributedNotificationCenter.default().post(
                name: Notification.Name("com.ijuka.app.forwarded-url"),
                object: nil,
                userInfo: ["url": url.absoluteString]
            )
        }
        if #available(macOS 14.0, *) {
            existing.activate(options: [.activateAllWindows])
        } else {
            existing.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        }
        NSApp.terminate(nil)
    }
}
#endif

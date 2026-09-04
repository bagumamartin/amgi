public import SwiftUI
import AmgiTheme
import ReviewFeature
import SettingsFeature

extension AmgiRoot {
    /// The host target's `App.body`. Extra macOS scenes (review windows,
    /// Settings) live here so `AmgiAppApp` stays a one-line composition root.
    @MainActor
    @SceneBuilder
    public static var scenes: some Scene {
        WindowGroup { RootView() }
        #if os(macOS)
        WindowGroup("Study", id: "review") {
            ReviewWindowHost()
                .frame(minWidth: 640, minHeight: 480)
                .themedRoot()
                .formStyle(.grouped)
        }
        .defaultSize(width: 820, height: 640)
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.suppressed)

        Window("Settings", id: "settings") {
            SettingsWindowHost(onSwitchProfile: { await switchProfile(to: $0) })
                .frame(minWidth: 640, minHeight: 440)
                .themedRoot()
                .formStyle(.grouped)
        }
        .defaultSize(width: 780, height: 560)
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.suppressed)
        #endif
    }
}

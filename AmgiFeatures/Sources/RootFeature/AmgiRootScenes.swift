public import SwiftUI
import AmgiAppCore
import AmgiAppShared
import AmgiTheme
import ReviewFeature
import SettingsFeature
import Sharing

extension AmgiRoot {
    /// The host target's `App.body`. Extra macOS scenes (review windows,
    /// Settings) live here so `AmgiAppApp` stays a one-line composition root.
    @MainActor
    @SceneBuilder
    public static var scenes: some Scene {
#if os(macOS)
        WindowGroup {
            // Widget clicks deliver `amgi://study`. SwiftUI's default on
            // macOS is to spawn a NEW WindowGroup window for every external
            // event before onOpenURL runs. `preferring` makes an existing
            // main window claim the event instead (activated + navigated in
            // place); the scene-level `matching` below only creates a window
            // when none exists.
            RootView()
                .handlesExternalEvents(preferring: ["study"], allowing: ["*"])
        }
        .defaultSize(width: 1180, height: 800)
        // Scene half of the widget-click reuse pair (see `preferring` on the
        // root view): only creates a main window when none exists.
        .handlesExternalEvents(matching: ["study"])
        .commands {
            AmgiCommands()
        }

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
#else
        WindowGroup {
            RootView()
        }
#endif
    }
}

#if os(macOS)
/// macOS menu-bar commands. A `Commands` struct (rather than an inline
/// `.commands {}` closure) so `@FocusedValue(ReviewActions.self)` has a
/// property host — the review window publishes its actions as a focused
/// scene value and these menus drive whichever review is focused.
private struct AmgiCommands: Commands {
    @FocusedValue(ReviewActions.self) private var reviewActions
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { reviewActions?.undo() }
                .keyboardShortcut(
                    AmgiCommands.shortcut(.undo).keyEquivalent,
                    modifiers: AmgiCommands.shortcut(.undo).modifiers
                )
                .disabled(reviewActions == nil)
        }
        CommandMenu("Card") {
            Button("Edit Note") { reviewActions?.editNote() }
                .keyboardShortcut(
                    AmgiCommands.shortcut(.editNote).keyEquivalent,
                    modifiers: AmgiCommands.shortcut(.editNote).modifiers
                )
                .disabled(reviewActions == nil)
            Divider()
            Button("Look Up") { reviewActions?.lookup() }
                .keyboardShortcut(
                    AmgiCommands.shortcut(.lookup).keyEquivalent,
                    modifiers: AmgiCommands.shortcut(.lookup).modifiers
                )
                .disabled(reviewActions == nil)
            Button("Replay Audio") { reviewActions?.replayAudio() }
                .keyboardShortcut(
                    AmgiCommands.shortcut(.replayAudio).keyEquivalent,
                    modifiers: AmgiCommands.shortcut(.replayAudio).modifiers
                )
                .disabled(reviewActions == nil)
        }
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { openWindow(id: "settings") }
                .keyboardShortcut(",", modifiers: .command)
        }
        CommandMenu("Go") {
            Button("Library") { AmgiCommands.setSection(.library) }
                .keyboardShortcut("1", modifiers: .command)
            if AmgiCommands.showReaderTab {
                Button("Read") { AmgiCommands.setSection(.read) }
                    .keyboardShortcut("2", modifiers: .command)
            }
            Button("Study") { AmgiCommands.setSection(.study) }
                .keyboardShortcut("3", modifiers: .command)
            Button("Stats") { AmgiCommands.setSection(.stats) }
                .keyboardShortcut("4", modifiers: .command)
            Button("Browse") { AmgiCommands.setSection(.browse) }
                .keyboardShortcut("5", modifiers: .command)
        }
        CommandGroup(after: .toolbar) {
            Button("Sync Now") {
                // The sync flow presents the sheet, which performs the
                // endpoint/credential preflight and can show Login.
                NotificationCenter.default.post(name: .amgiPresentSync, object: nil)
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
        }
    }

    private static func shortcut(_ action: ReviewShortcutAction) -> ReviewShortcut {
        @Shared(.reviewShortcuts) var bindings: [String: ReviewShortcut] = [:]
        return bindings[action.rawValue] ?? action.defaultShortcut
    }

    /// Writes MainTabView's persisted selection directly. `@Shared`
    /// appStorage observes UserDefaults, so this propagates to the tab
    /// binding without holding a property wrapper in static context.
    private static func setSection(_ section: MainSection) {
        UserDefaults.standard.set(section.rawValue, forKey: NavigationPreferences.rootSection)
    }

    private static var showReaderTab: Bool {
        UserDefaults.standard.object(forKey: ReaderPreferences.Keys.showTab) as? Bool ?? true
    }
}
#endif

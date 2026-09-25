public import SwiftUI
import AmgiAppCore
import AmgiAppShared
import AmgiTheme
import AppIntentsFeature
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
        WindowGroup("Ijuka", id: "main") {
            // Widget clicks deliver `amgi://study`. SwiftUI's default on
            // macOS is to spawn a NEW WindowGroup window for every external
            // event before onOpenURL runs. `preferring` makes an existing
            // main window claim the event instead (activated + navigated in
            // place); the scene-level `matching` below only creates a window
            // when none exists.
            RootView()
                .frame(minWidth: 960, minHeight: 600)
                .handlesExternalEvents(preferring: ["study"], allowing: ["*"])
        }
        .defaultSize(width: 1180, height: 800)
        .windowResizability(.contentMinSize)
        // Scene half of the widget-click reuse pair (see `preferring` on the
        // root view): only creates a main window when none exists.
        .handlesExternalEvents(matching: ["study"])
        .commands {
            AmgiCommands()
        }

        // The engine's current-deck selection, learn-ahead override, and undo
        // stack are collection-global. A single scene is therefore the safe Mac
        // presentation until those services become genuinely session-scoped.
        Window("Study", id: "review") {
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
    @FocusedValue(RootSceneActions.self) private var rootSceneActions
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .undoRedo) {
            Button("Undo") { reviewActions?.undo() }
                .keyboardShortcut(
                    AmgiCommands.shortcut(.undo).keyEquivalent,
                    modifiers: AmgiCommands.shortcut(.undo).modifiers
                )
                .disabled(reviewActions?.canUndo != true)
            Button("Redo") { reviewActions?.redo() }
                .keyboardShortcut(
                    AmgiCommands.shortcut(.redo).keyEquivalent,
                    modifiers: AmgiCommands.shortcut(.redo).modifiers
                )
                .disabled(reviewActions?.canRedo != true)
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
        CommandGroup(after: .newItem) {
            Button("Import…") { rootSceneActions?.importFile() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(rootSceneActions == nil)
            Button("Export Collection…") { rootSceneActions?.exportCollection() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(rootSceneActions == nil)
        }
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { openWindow(id: "settings") }
                .keyboardShortcut(",", modifiers: .command)
        }
        CommandMenu("Go") {
            Button("Library") { rootSceneActions?.select(.library) }
                .keyboardShortcut("1", modifiers: .command)
                .disabled(rootSceneActions == nil)
            if rootSceneActions?.isReaderEnabled != false {
                Button("Read") { rootSceneActions?.select(.read) }
                    .keyboardShortcut("2", modifiers: .command)
                    .disabled(rootSceneActions == nil)
            }
            Button("Study") { rootSceneActions?.select(.study) }
                .keyboardShortcut("3", modifiers: .command)
                .disabled(rootSceneActions == nil)
            Button("Stats") { rootSceneActions?.select(.stats) }
                .keyboardShortcut("4", modifiers: .command)
                .disabled(rootSceneActions == nil)
            Button("Browse") { rootSceneActions?.select(.browse) }
                .keyboardShortcut("5", modifiers: .command)
                .disabled(rootSceneActions == nil)
        }
        CommandGroup(after: .toolbar) {
            Button("Study Assistant…") {
                rootSceneActions?.studyAssistant()
            }
            .keyboardShortcut("a", modifiers: [.command, .shift])
            .disabled(rootSceneActions == nil)
            Divider()
            Button("Sync Now") {
                rootSceneActions?.sync()
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(rootSceneActions == nil)
        }
    }

    private static func shortcut(_ action: ReviewShortcutAction) -> ReviewShortcut {
        @Shared(.reviewShortcuts) var bindings: [String: ReviewShortcut] = [:]
        return bindings[action.rawValue] ?? action.defaultShortcut
    }

}
#endif

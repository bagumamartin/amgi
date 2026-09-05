#if os(macOS)
import AmgiAppShared
import Dependencies
import Foundation

/// Refreshes the widget snapshot every 15 minutes for as long as the app
/// process is alive, independent of window focus. Skipped under XCTest via
/// the same guard `writeWidgetSnapshot()` uses internally.
///
/// macOS has no BGTaskScheduler, but it also doesn't suspend a running
/// app the way iOS does when it's not frontmost — the process keeps
/// running until the user quits it. A simple in-process polling loop
/// is the native-feeling equivalent of iOS's BGAppRefreshTask: it keeps
/// the desktop widget fresh (new due counts, midnight rollover, streak)
/// without requiring the app window to be active.
func startMacWidgetRefreshLoop() {
    // An inheriting `Task` (not `Task.detached`) so the loop carries the
    // dependency context set up by `prepareDependencies` — i.e. the opened
    // `AnkiBackend`. `Task.detached` would start a fresh task tree with
    // default dependencies (a fresh, unopened backend), making every
    // `writeWidgetSnapshot()` fail at runtime.
    Task(priority: .background) {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(15 * 60))
            await writeWidgetSnapshot()
        }
    }
}

/// Observes the amgi-mcp helper's change notification. Every agent
/// mutation lands in the SAME collection.anki2 this app has open; the
/// notification just tells us to bump `CollectionStore`'s generation so
/// all generation-keyed screens reload and show the agent's edits
/// immediately. Sync propagation rides the normal automatic-sync cycle.
func observeHelperMutations() {
    let observer = DistributedNotificationCenter.default().addObserver(
        forName: Notification.Name("com.amgi.collection.changed"),
        object: nil,
        queue: nil
    ) { _ in
        Task { @MainActor in
            @Dependency(\.collectionStore) var store
            store.invalidateAll(origin: .helperMutation)
        }
    }
    // Process-lifetime observer; no removal needed.
    _ = observer
}
#endif

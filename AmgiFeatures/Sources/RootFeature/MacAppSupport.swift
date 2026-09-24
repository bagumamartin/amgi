#if os(macOS)
import AmgiAppShared
import Dependencies
import Foundation
import SyncFeature

/// Runs the macOS fallback loop while the app process is alive. Local
/// mutations still refresh immediately through CollectionStore; this loop is
/// only a recovery path for remote changes and elapsed-time forecast data.
///
/// macOS has no BGTaskScheduler, so this cannot run after the user quits the
/// app. It deliberately uses a quiet 15-minute period rather than hammering
/// WidgetKit with reload requests.
@MainActor
func startMacWidgetRefreshLoop() {
    // An inheriting `Task` (not `Task.detached`) so the loop carries the
    // dependency context set up by `prepareDependencies` — i.e. the opened
    // `AnkiBackend`. `Task.detached` would start a fresh task tree with
    // default dependencies (a fresh, unopened backend), making every
    // snapshot query fail at runtime.
    @Dependency(\.syncCoordinator) var coordinator
    Task(priority: .background) {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(15 * 60))
            } catch {
                return
            }
            await WidgetRefreshCoordinator.shared.refreshNow()
            _ = await coordinator.runScheduledCollectionSync()
        }
    }
}

/// Observes the ijuka-mcp helper's change notification. Every agent
/// mutation lands in the SAME collection.anki2 this app has open; the
/// notification just tells us to bump `CollectionStore`'s generation so
/// all generation-keyed screens reload and show the agent's edits
/// immediately. Sync propagation rides the normal automatic-sync cycle.
func observeHelperMutations() {
    let observer = DistributedNotificationCenter.default().addObserver(
        forName: Notification.Name("com.ijuka.collection.changed"),
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

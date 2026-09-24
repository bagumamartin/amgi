#if os(iOS)
import AmgiAppShared
import BackgroundTasks
import Dependencies
import Foundation
import SyncFeature

/// Background task identifiers, derived from the app's bundle identifier
/// rather than hardcoded. Keeps registration + scheduling in sync with
/// `BGTaskSchedulerPermittedIdentifiers` (which uses
/// `$(PRODUCT_BUNDLE_IDENTIFIER).<suffix>` in Info.plist) even if the bundle
/// ID changes.
enum BackgroundTaskID {
    static let widgetRefresh = "\(bundleID).widget-refresh"
    static let automaticSync = "\(bundleID).automatic-sync"

    private static var bundleID: String {
        Bundle.main.bundleIdentifier ?? "com.amgi.app"
    }
}

private final class BackgroundTaskHandle: @unchecked Sendable {
    let task: BGTask

    init(_ task: BGTask) {
        self.task = task
    }
}

private final class BackgroundTaskCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    /// Returns true only for the caller that completed the BGTask. The
    /// expiration handler and the work continuation can race at the end of a
    /// refresh; BGTask must receive exactly one completion call.
    @discardableResult
    func finish(_ handle: BackgroundTaskHandle, success: Bool) -> Bool {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return false
        }
        completed = true
        lock.unlock()
        handle.task.setTaskCompleted(success: success)
        return true
    }
}

/// Widget snapshot refresh via BGTaskScheduler is iOS-only: the
/// BackgroundTasks framework doesn't exist on macOS. macOS gets its own
/// refresh strategy (`startMacWidgetRefreshLoop`), since unlike iOS it
/// doesn't suspend the process while unfocused.
func registerBackgroundTasks() {
    BGTaskScheduler.shared.register(
        forTaskWithIdentifier: BackgroundTaskID.widgetRefresh,
        using: nil
    ) { @Sendable task in
        handleWidgetRefreshTask(task)
    }
    BGTaskScheduler.shared.register(
        forTaskWithIdentifier: BackgroundTaskID.automaticSync,
        using: nil
    ) { @Sendable task in
        handleAutomaticSyncTask(task)
    }
    scheduleWidgetRefreshTask()
    scheduleAutomaticSyncTask()
}

private func handleWidgetRefreshTask(_ task: BGTask) {
    let handle = BackgroundTaskHandle(task)
    let gate = BackgroundTaskCompletionGate()
    let work = Task { @MainActor in
        let success = await WidgetRefreshCoordinator.shared.refreshNow()
        guard !Task.isCancelled else { return }
        if gate.finish(handle, success: success) {
            scheduleWidgetRefreshTask()
        }
    }
    task.expirationHandler = {
        work.cancel()
        let didFinish = gate.finish(handle, success: false)
        Task { @MainActor in
            WidgetRefreshCoordinator.shared.cancelPendingWork(preserveQueuedRefresh: true)
            if didFinish {
                scheduleWidgetRefreshTask()
            }
        }
    }
}

private func handleAutomaticSyncTask(_ task: BGTask) {
    let handle = BackgroundTaskHandle(task)
    let gate = BackgroundTaskCompletionGate()
    let work = Task { @MainActor in
        @Dependency(\.syncCoordinator) var coordinator
        let result = await coordinator.runScheduledCollectionSync()
        guard !Task.isCancelled else { return }
        let success: Bool
        if case .success = result {
            success = true
        } else {
            success = false
        }
        if gate.finish(handle, success: success) {
            scheduleAutomaticSyncTask()
        }
    }
    task.expirationHandler = {
        work.cancel()
        if gate.finish(handle, success: false) {
            scheduleAutomaticSyncTask()
        }
    }
}

/// Schedules a BGAppRefreshTask shortly after Anki's default 4 AM day
/// rollover. The system may defer it, but asking for the correct boundary
/// avoids a stale midnight snapshot.
private func scheduleWidgetRefreshTask() {
    let request = BGAppRefreshTaskRequest(identifier: BackgroundTaskID.widgetRefresh)
    let calendar = Calendar.current
    let now = Date()
    let today = calendar.date(bySettingHour: 4, minute: 5, second: 0, of: now) ?? now
    request.earliestBeginDate = today > now
        ? today
        : calendar.date(byAdding: .day, value: 1, to: today) ?? now
    try? BGTaskScheduler.shared.submit(request)
}

private func scheduleAutomaticSyncTask() {
    let request = BGAppRefreshTaskRequest(identifier: BackgroundTaskID.automaticSync)
    request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
    try? BGTaskScheduler.shared.submit(request)
}
#endif

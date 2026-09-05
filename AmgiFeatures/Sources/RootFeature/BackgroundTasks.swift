#if os(iOS)
import AmgiAppShared
import BackgroundTasks
import Foundation

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

private struct UncheckedSendableBox<T>: @unchecked Sendable { let value: T }

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
    let box = UncheckedSendableBox(value: task)
    let work = Task {
        await writeWidgetSnapshot()
        box.value.setTaskCompleted(success: true)
        scheduleWidgetRefreshTask()
    }
    task.expirationHandler = {
        work.cancel()
        box.value.setTaskCompleted(success: false)
    }
}

private func handleAutomaticSyncTask(_ task: BGTask) {
    let box = UncheckedSendableBox(value: task)
    let work = Task { @MainActor in
        NotificationCenter.default.post(name: .amgiPerformBackgroundSync, object: nil)
        try? await Task.sleep(for: .seconds(20))
        box.value.setTaskCompleted(success: !Task.isCancelled)
        scheduleAutomaticSyncTask()
    }
    task.expirationHandler = {
        work.cancel()
        box.value.setTaskCompleted(success: false)
    }
}

/// Schedules a BGAppRefreshTask to fire shortly after the next midnight.
/// The task writes a fresh widget snapshot so the widget shows today's counts
/// even if the user hasn't opened the app yet.
private func scheduleWidgetRefreshTask() {
    let request = BGAppRefreshTaskRequest(identifier: BackgroundTaskID.widgetRefresh)
    let cal = Calendar.current
    let tomorrow = cal.startOfDay(for: cal.date(byAdding: .day, value: 1, to: Date()) ?? Date())
    // Fire 5 minutes after midnight so Anki's day rollover has settled.
    request.earliestBeginDate = cal.date(byAdding: .minute, value: 5, to: tomorrow) ?? tomorrow
    try? BGTaskScheduler.shared.submit(request)
}

private func scheduleAutomaticSyncTask() {
    let request = BGAppRefreshTaskRequest(identifier: BackgroundTaskID.automaticSync)
    request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
    try? BGTaskScheduler.shared.submit(request)
}
#endif

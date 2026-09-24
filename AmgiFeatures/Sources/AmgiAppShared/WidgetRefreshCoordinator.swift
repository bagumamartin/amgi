import Foundation

/// Serializes widget snapshot work and coalesces bursts of collection changes
/// into one refresh. WidgetKit still controls when the extension is rendered;
/// this coordinator only makes sure the app publishes a fresh, coherent
/// snapshot and requests a reload after the write succeeds.
@MainActor
public final class WidgetRefreshCoordinator {
    public static let shared = WidgetRefreshCoordinator()

    private var debounceTask: Task<Void, Never>?
    private var refreshTask: Task<Bool, Never>?
    private var activeRefreshID: UUID?
    private var needsRefresh = false
    private var isDraining = false
    private var drainOwnerCount = 0
    private var drainTask: Task<Void, Never>?

    private init() {}

    /// Schedules a refresh after a short quiet period. Repeated requests
    /// replace the pending debounce rather than creating a writer storm.
    public func request(reason _: String, debounce: Duration = .seconds(5)) {
        guard !isDraining else {
            needsRefresh = true
            return
        }
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: debounce)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.needsRefresh = true
            self.startRefreshLoop()
        }
    }

    /// Requests an immediate refresh and waits until the serialized writer
    /// has finished. This is used for lifecycle boundaries such as profile
    /// switches and successful syncs, where stale data is especially visible.
    @discardableResult
    public func refreshNow() async -> Bool {
        if isDraining, let drainTask {
            needsRefresh = true
            _ = await drainTask.value
            return false
        }
        if isDraining {
            needsRefresh = true
            return false
        }
        debounceTask?.cancel()
        debounceTask = nil
        needsRefresh = true
        startRefreshLoop()
        guard let refreshTask else { return false }
        return await refreshTask.value
    }

    /// Cancels pending work. Primarily useful during teardown and tests; the
    /// app normally lets the coordinator live for the process lifetime.
    public func cancelPendingWork(preserveQueuedRefresh: Bool = false) {
        let hadPendingRefresh = needsRefresh || debounceTask != nil
        debounceTask?.cancel()
        debounceTask = nil
        if preserveQueuedRefresh && hadPendingRefresh {
            needsRefresh = true
        } else {
            needsRefresh = false
        }
        // Leave refreshTask installed until its cleanup continuation observes
        // cancellation; clearing it here would allow a second writer to race
        // the in-flight FFI query.
        refreshTask?.cancel()
    }

    /// Starts a lifecycle barrier before a caller closes or replaces the
    /// collection. New widget requests are rejected until the matching
    /// `endDrain()` call, so a mutation racing the close cannot start a new
    /// writer in the intermediate collection state.
    public func beginDrain() {
        drainOwnerCount += 1
        guard drainOwnerCount == 1 else { return }

        isDraining = true
        let hadPendingRefresh = needsRefresh || debounceTask != nil
        debounceTask?.cancel()
        debounceTask = nil
        if hadPendingRefresh {
            needsRefresh = true
        }
        refreshTask?.cancel()
        drainTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if let refreshTask = self.refreshTask {
                _ = await refreshTask.value
                while self.activeRefreshID != nil {
                    await Task.yield()
                }
            }
        }
    }

    public func endDrain() {
        guard drainOwnerCount > 0 else { return }
        drainOwnerCount -= 1
        guard drainOwnerCount == 0 else { return }
        isDraining = false
        drainTask = nil
        if needsRefresh {
            startRefreshLoop()
        }
    }

    /// Cancels and drains the writer before a collection lifecycle operation
    /// closes or replaces the database.
    public func cancelAndWait() async {
        if let drainTask {
            await drainTask.value
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            self.isDraining = true
            let hadPendingRefresh = self.needsRefresh || self.debounceTask != nil
            self.cancelPendingWork()
            if hadPendingRefresh { self.needsRefresh = true }
            if let refreshTask = self.refreshTask {
                _ = await refreshTask.value
                while self.activeRefreshID != nil {
                    await Task.yield()
                }
            }
            self.drainTask = nil
            self.isDraining = false
        }
        drainTask = task
        await task.value
    }

    private func startRefreshLoop() {
        guard refreshTask == nil, !isDraining else { return }

        let refreshID = UUID()
        activeRefreshID = refreshID
        let task = Task { @MainActor [weak self] () -> Bool in
            guard let self else { return false }

            var allSucceeded = true
            while self.needsRefresh {
                guard !Task.isCancelled else { return allSucceeded }
                self.needsRefresh = false
                let succeeded = await writeWidgetSnapshot()
                allSucceeded = allSucceeded && succeeded
                // Give a burst of answer events a chance to mark the snapshot
                // dirty again before the writer enters its next iteration.
                await Task.yield()
            }
            return allSucceeded
        }
        refreshTask = task

        Task { @MainActor [weak self] in
            _ = await task.value
            guard let self, self.activeRefreshID == refreshID else { return }
            self.refreshTask = nil
            self.activeRefreshID = nil
            // A request can arrive after the loop's final condition check but
            // before this cleanup task runs. Start one more pass rather than
            // dropping that last change on the floor.
            if self.needsRefresh {
                self.startRefreshLoop()
            }
        }
    }
}

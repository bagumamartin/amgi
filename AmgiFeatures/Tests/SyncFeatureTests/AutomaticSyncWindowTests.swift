import Testing
import Foundation
import Dependencies
import Sharing
import AmgiAppCore
import AmgiReviewCore
import AnkiKit
import AnkiClients
import AnkiSync
@testable import SyncFeature

/// Pins the automatic-sync launch gates: a review session must never compete
/// with sync for the backend lock, and continuous editing must still flush.
///
/// Uses a shrunken `AutomaticSyncTuning` so no test pays real debounce,
/// stability-window, or wait-cap delays. Manual syncs (`startSync`) bypass
/// every gate here by design and are covered by `SyncCoordinatorTests`.
@Suite("Automatic sync launch window", .serialized)
struct AutomaticSyncWindowTests {

    private func fastTuning() -> SyncCoordinator.AutomaticSyncTuning {
        var tuning = SyncCoordinator.AutomaticSyncTuning()
        tuning.assumeInteractiveApp = true
        tuning.debounceAfterMutation = .milliseconds(5)
        tuning.debounceOnResume = .milliseconds(5)
        tuning.maxWaitContinuousEditing = 30
        tuning.syncWindowWaitCap = .milliseconds(300)
        tuning.networkStabilityWindow = .milliseconds(5)
        tuning.syncWindowPollInterval = .milliseconds(5)
        return tuning
    }

    /// Stages dummy credentials so automatic launches pass the
    /// endpoint/host-key guards and reach the stubbed client.
    private func stageCredentials() -> (endpoint: String?, hostKey: String?) {
        let snapshot = (KeychainHelper.loadEndpoint(), KeychainHelper.loadHostKey())
        saveTestCredentials()
        return snapshot
    }

    /// Unconditional save with no snapshot. Sibling suites in this target
    /// transiently delete and restore the same process-wide credentials, so
    /// a single staging at test start can be wiped mid-test; re-saving
    /// before each launch attempt keeps the guards satisfied. Only ever
    /// writes test values, which every suite here stages for itself anyway.
    private func saveTestCredentials() {
        try? KeychainHelper.saveEndpoint("https://test.invalid")
        try? KeychainHelper.saveHostKey("test-host-key")
    }

    private func restoreCredentials(_ snapshot: (endpoint: String?, hostKey: String?)) {
        if let endpoint = snapshot.endpoint {
            try? KeychainHelper.saveEndpoint(endpoint)
        } else {
            KeychainHelper.deleteEndpoint()
        }
        if let hostKey = snapshot.hostKey {
            try? KeychainHelper.saveHostKey(hostKey)
        } else {
            KeychainHelper.deleteHostKey()
        }
    }

    @MainActor
    private func acquireTestLease() throws -> ReviewSessionLease {
        try ReviewSessionCoordinator.shared.acquireSession(
            sessionID: UUID(),
            profile: ProfileContext(
                id: "sync-window-test",
                displayName: "Sync Window Test",
                selectionID: UUID()
            )
        )
    }

    /// Holds a review lease for the duration of `work`, releasing it
    /// afterwards so later tests start fence-free. A plain `defer` cannot do
    /// this: the `withDependencies` operation closure is nonisolated, and a
    /// nonisolated `defer` cannot call the MainActor-isolated release.
    @MainActor
    private func withTestLease<T>(
        _ work: @MainActor (ReviewSessionLease) async throws -> T
    ) async throws -> T {
        let lease = try acquireTestLease()
        defer { ReviewSessionCoordinator.shared.releaseSession(lease) }
        return try await work(lease)
    }

    /// The backstop is synchronous in `beginSync`: with a review lease held,
    /// an automatic launch is refused without ever touching the client.
    /// Needs no credentials — the review check runs before every guard that
    /// would require them.
    @Test @MainActor
    func automaticSyncRefusedWhileReviewActive() async throws {
        try await withDependencies {
            $0.appStorageKeyFormatWarningEnabled = false
            $0.syncClient.syncCollection = {
                Issue.record("sync client must not be called while a review is active")
                return SyncSummary()
            }
        } operation: {
            let coordinator = SyncCoordinator(automaticSyncTuning: fastTuning())
            try await withTestLease { _ in
                let result = await coordinator.startSyncAndWait(includeMedia: false)
                guard case .cancelled = result else {
                    Issue.record("expected .cancelled, got \(result)")
                    return
                }
                #expect(coordinator.logEntries.contains { $0.message.contains("review in progress") })
            }
        }
    }

    /// End-to-end through the debounce waiter: dirty while a review is active
    /// stays pending (no launch), and releasing the lease lets it through.
    ///
    /// The post-release poll re-issues the request while waiting: sibling
    /// suites in this target transiently flip process-global sync state
    /// (full-sync flag, keychain credentials), and a single launch attempt
    /// that lands in such a window would fail for reasons unrelated to the
    /// gate under test. Retrying emulates what production does — dirty
    /// persists, so the next trigger retries.
    @Test @MainActor
    func requestAutomaticSyncWaitsForReviewEnd() async throws {
        let credentials = stageCredentials()
        defer { restoreCredentials(credentials) }
        UserDefaults.standard.set(false, forKey: SyncPreferences.Keys.needsFullSyncForCurrentUser())
        let syncCalls = SyncCallCounter()
        try await withDependencies {
            $0.appStorageKeyFormatWarningEnabled = false
            $0.syncClient.syncCollection = {
                await syncCalls.increment()
                return SyncSummary()
            }
        } operation: {
            let coordinator = SyncCoordinator(automaticSyncTuning: fastTuning())
            try await withTestLease { lease in
                #expect(ReviewSessionCoordinator.shared.hasActiveSession)
                await coordinator.requestAutomaticSync(reason: "test rating")
                // Debounce (5ms) plus several wait-loop polls elapse here; the
                // launch must still be held back by the active lease.
                try await Task.sleep(for: .milliseconds(80))
                #expect(await syncCalls.count == 0)

                ReviewSessionCoordinator.shared.releaseSession(lease)
                #expect(!ReviewSessionCoordinator.shared.hasActiveSession)
                // Prompt attempts (dirty is long past every debounce by now),
                // re-staging credentials each time: sibling suites
                // transiently delete/restore the shared credentials, so an
                // attempt can only rely on state saved immediately before it.
                let deadline = ContinuousClock.now.advanced(by: .seconds(8))
                while await syncCalls.count == 0, ContinuousClock.now < deadline {
                    saveTestCredentials()
                    await coordinator.requestAutomaticSync(reason: "test rating retry")
                    try await Task.sleep(for: .milliseconds(500))
                }
                if await syncCalls.count == 0 {
                    let trail = await coordinator.logEntries.map(\.message).joined(separator: " | ")
                    Issue.record("never launched; coordinator trail: \(trail)")
                }
                #expect(await syncCalls.count == 1)
            }
        }
    }

    /// Continuous mutations reset the debounce forever; the staleness cap
    /// forces a launch anyway. The 30s debounce here can never elapse, so a
    /// launch proves the cap fired. Retried like above: a single attempt may
    /// land in a sibling suite's transient credential/flag window.
    @Test @MainActor
    func continuousEditingForcesSyncDespiteDebounce() async throws {
        let credentials = stageCredentials()
        defer { restoreCredentials(credentials) }
        UserDefaults.standard.set(false, forKey: SyncPreferences.Keys.needsFullSyncForCurrentUser())
        var tuning = fastTuning()
        tuning.debounceAfterMutation = .seconds(30)
        tuning.maxWaitContinuousEditing = 0.01
        let syncCalls = SyncCallCounter()
        try await withDependencies {
            $0.appStorageKeyFormatWarningEnabled = false
            $0.syncClient.syncCollection = {
                await syncCalls.increment()
                return SyncSummary()
            }
        } operation: {
            let coordinator = SyncCoordinator(automaticSyncTuning: tuning)
            saveTestCredentials()
            await coordinator.requestAutomaticSync(reason: "test edit 1")
            // Past the 10ms cap: further mutations must launch immediately
            // instead of sleeping out the 30s debounce.
            try await Task.sleep(for: .milliseconds(50))

            let deadline = ContinuousClock.now.advanced(by: .seconds(8))
            while await syncCalls.count == 0, ContinuousClock.now < deadline {
                saveTestCredentials()
                await coordinator.requestAutomaticSync(reason: "test edit retry")
                try await Task.sleep(for: .milliseconds(500))
            }
            if await syncCalls.count == 0 {
                let trail = await coordinator.logEntries.map(\.message).joined(separator: " | ")
                Issue.record("never launched; coordinator trail: \(trail)")
            }
            #expect(await syncCalls.count == 1)
        }
    }

    /// Cancelling a pending automatic sync drops the launch but keeps the
    /// dirty marker: a later resume still flushes. Review starts use this so
    /// a queued post-review flush can't block first paint on the backend lock.
    @Test @MainActor
    func cancelPendingAutomaticSyncKeepsDirtyState() async throws {
        let credentials = stageCredentials()
        defer { restoreCredentials(credentials) }
        UserDefaults.standard.set(false, forKey: SyncPreferences.Keys.needsFullSyncForCurrentUser())
        var tuning = fastTuning()
        tuning.debounceAfterMutation = .seconds(30)
        let syncCalls = SyncCallCounter()
        try await withDependencies {
            $0.appStorageKeyFormatWarningEnabled = false
            $0.syncClient.syncCollection = {
                await syncCalls.increment()
                return SyncSummary()
            }
        } operation: {
            let coordinator = SyncCoordinator(automaticSyncTuning: tuning)
            saveTestCredentials()
            await coordinator.requestAutomaticSync(reason: "test mutation")
            await coordinator.cancelPendingAutomaticSync()
            // The 30s debounce could never elapse here; anything launched
            // would prove the cancel missed its waiter.
            try await Task.sleep(for: .milliseconds(150))
            #expect(await syncCalls.count == 0)

            let deadline = ContinuousClock.now.advanced(by: .seconds(8))
            while await syncCalls.count == 0, ContinuousClock.now < deadline {
                saveTestCredentials()
                coordinator.resumeAutomaticSyncIfNeeded(reason: "test retry")
                try await Task.sleep(for: .milliseconds(500))
            }
            #expect(await syncCalls.count == 1)
        }
    }
}

private actor SyncCallCounter {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}

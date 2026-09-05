import Testing
import Foundation
import Dependencies
import Sharing
import AmgiAppCore
import AnkiKit
import AnkiClients
import AnkiSync
@testable import SyncFeature

/// startSync refuses to run without a configured sync server (.noServer),
/// so every test that exercises the sync path stages a dummy endpoint first
/// and restores the ambient keychain afterwards. The snapshot/restore matters
/// on macOS, where tests share the login keychain with the real app: without
/// it a test run would depend on — or delete — the user's real credentials.
/// Uses an invalid host so a stubbed client can never reach the network.
private struct CredentialSnapshot: Sendable {
    let endpoint: String?
    let hostKey: String?
    let username: String?
}

private func stageTestEndpoint() -> CredentialSnapshot {
    let snapshot = CredentialSnapshot(
        endpoint: KeychainHelper.loadEndpoint(),
        hostKey: KeychainHelper.loadHostKey(),
        username: KeychainHelper.loadUsername()
    )
    try? KeychainHelper.saveEndpoint("https://test.invalid")
    return snapshot
}

private func restoreCredentials(_ snapshot: CredentialSnapshot) {
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
    if let username = snapshot.username {
        try? KeychainHelper.saveUsername(username)
    } else {
        KeychainHelper.deleteUsername()
    }
}

/// The full-sync flag persists in UserDefaults and outlives any one test:
/// `needsFullSyncRequiresUserChoice` sets it and never clears it, so a
/// later `startSync` in the same simulator would open `.needsFullSync`
/// instead of `.syncing` (order-dependent flake in full runs; invisible in
/// single-suite runs where the order happens to be safe). Snapshot/restore
/// around the writer — same pattern as CredentialSnapshot for the keychain.
private struct FullSyncFlagSnapshot: Sendable {
    let value: Bool
}

private func stageFullSyncFlag() -> FullSyncFlagSnapshot {
    FullSyncFlagSnapshot(
        value: UserDefaults.standard.bool(forKey: SyncPreferences.Keys.needsFullSyncForCurrentUser())
    )
}

private func restoreFullSyncFlag(_ snapshot: FullSyncFlagSnapshot) {
    UserDefaults.standard.set(
        snapshot.value,
        forKey: SyncPreferences.Keys.needsFullSyncForCurrentUser()
    )
}

@Suite("SyncCoordinator state machine")
struct SyncCoordinatorTests {

    @Test @MainActor
    func startSyncWaitsForMediaCompletion() async throws {
        let summary = SyncSummary(cardsPushed: 5, cardsPulled: 3)
        let statuses = MediaStatusQueue([
            MediaSyncStatus(
                active: true,
                progress: MediaSyncProgress(
                    checked: "Checked: 12",
                    added: "Added: 7\u{2191} 0\u{2193}",
                    removed: "Removed: 0\u{2191} 0\u{2193}"
                )
            ),
            MediaSyncStatus(active: false, progress: nil),
        ])
        let credentials = stageTestEndpoint()
        defer { restoreCredentials(credentials) }
        try await withDependencies {
            $0.appStorageKeyFormatWarningEnabled = false
            $0.syncClient.sync = { summary }
            $0.syncClient.mediaSyncStatus = { await statuses.next() }
        } operation: {
            let coordinator = SyncCoordinator(mediaPollInterval: .milliseconds(20))
            await coordinator.startSync()
            // Media arrives on the 20ms poll; a fixed sleep flakes under
            // load (10ms can land before the first poll fires). Poll for the
            // in-flight state instead — the assertion below still pins that
            // the flow passes THROUGH syncingMedia before succeeding.
            let expectedMedia: SyncCoordinator.SyncState =
                .syncingMedia("Checked: 12 \u{00B7} Added: 7\u{2191} 0\u{2193}")
            let mediaDeadline = ContinuousClock.now.advanced(by: .seconds(2))
            while coordinator.state != expectedMedia {
                if ContinuousClock.now >= mediaDeadline { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(coordinator.state == expectedMedia)
            try await Task.sleep(for: .milliseconds(60))
            guard case .success(let resultSummary) = coordinator.state else {
                Issue.record("expected .success, got \(coordinator.state)")
                return
            }
            #expect(resultSummary == summary)
            #expect(coordinator.lastSuccessfulSync != nil)
        }
    }

    /// A media failure is a *partial* failure: the collection half already
    /// committed, so the timestamp has to survive it. Reporting `.error` and
    /// rolling the timestamp back made the sync look entirely lost.
    @Test @MainActor
    func mediaSyncErrorSurfacesButKeepsTheCollectionSyncRecord() async throws {
        try await withDependencies {
            $0.appStorageKeyFormatWarningEnabled = false
            $0.syncClient.sync = { SyncSummary() }
            $0.syncClient.mediaSyncStatus = {
                throw SyncError(message: "Media checksum mismatch")
            }
        } operation: {
            // `lastSyncedAtUnix` is process-wide UserDefaults that other
            // tests also write, so pin it to a timestamp rather than testing
            // for non-nil.
            let before = Date()
            let coordinator = SyncCoordinator(mediaPollInterval: .milliseconds(1))
            await coordinator.startSync()
            try await Task.sleep(for: .milliseconds(50))
            guard case .error(let message) = coordinator.state else {
                Issue.record("expected .error, got \(coordinator.state)")
                return
            }
            #expect(message.contains("Media checksum mismatch"))
            #expect((coordinator.lastSuccessfulSync ?? .distantPast) >= before)
        }
    }

    @Test @MainActor
    func cancelDuringMediaSyncAbortsBackendTask() async throws {
        let abortRecorder = AsyncFlag()
        try await withDependencies {
            $0.appStorageKeyFormatWarningEnabled = false
            $0.syncClient.sync = { SyncSummary() }
            $0.syncClient.mediaSyncStatus = {
                MediaSyncStatus(
                    active: true,
                    progress: MediaSyncProgress(
                        checked: "Checked: 4",
                        added: "Added: 1\u{2191} 0\u{2193}",
                        removed: "Removed: 0\u{2191} 0\u{2193}"
                    )
                )
            }
            $0.syncClient.abortMediaSync = { await abortRecorder.set() }
        } operation: {
            let coordinator = SyncCoordinator(mediaPollInterval: .seconds(1))
            await coordinator.startSync()
            try await Task.sleep(for: .milliseconds(50))
            #expect(coordinator.state == .syncingMedia("Checked: 4 \u{00B7} Added: 1\u{2191} 0\u{2193}"))
            coordinator.cancel()
            try await Task.sleep(for: .milliseconds(50))
            #expect(coordinator.state == .idle)
            #expect(await abortRecorder.value)
        }
    }

    @Test @MainActor
    func startSyncErrorTransitions() async throws {
        let credentials = stageTestEndpoint()
        defer { restoreCredentials(credentials) }
        try await withDependencies {
            $0.appStorageKeyFormatWarningEnabled = false
            $0.syncClient.sync = {
                throw SyncError(message: "Network unreachable")
            }
        } operation: {
            let coordinator = SyncCoordinator()
            await coordinator.startSync()
            try await Task.sleep(for: .milliseconds(100))
            guard case .error(let message) = coordinator.state else {
                Issue.record("expected .error, got \(coordinator.state)")
                return
            }
            #expect(message.contains("Network unreachable"))
            #expect(coordinator.logEntries.contains { $0.level == .error })
        }
    }

    @Test @MainActor
    func needsFullSyncRequiresUserChoice() async throws {
        let credentials = stageTestEndpoint()
        defer { restoreCredentials(credentials) }
        let flag = stageFullSyncFlag()
        defer { restoreFullSyncFlag(flag) }
        try await withDependencies {
            $0.appStorageKeyFormatWarningEnabled = false
            $0.syncClient.sync = { throw SyncError.fullSyncRequired }
        } operation: {
            let coordinator = SyncCoordinator()
            await coordinator.startSync()
            try await Task.sleep(for: .milliseconds(100))
            guard case .needsFullSync = coordinator.state else {
                Issue.record("expected .needsFullSync, got \(coordinator.state)")
                return
            }
        }
    }

    @Test @MainActor
    func confirmFullSyncUpload() async throws {
        let credentials = stageTestEndpoint()
        defer { restoreCredentials(credentials) }
        let flag = stageFullSyncFlag()
        defer { restoreFullSyncFlag(flag) }
        try await withDependencies {
            $0.appStorageKeyFormatWarningEnabled = false
            $0.syncClient.sync = { throw SyncError.fullSyncRequired }
            $0.syncClient.fullSync = { _ in /* success */ }
            $0.syncClient.mediaSyncStatus = { MediaSyncStatus(active: false, progress: nil) }
        } operation: {
            let coordinator = SyncCoordinator()
            await coordinator.startSync()
            try await Task.sleep(for: .milliseconds(100))
            await coordinator.confirmFullSync(direction: .upload)
            try await Task.sleep(for: .milliseconds(100))
            guard case .success = coordinator.state else {
                Issue.record("expected .success after upload, got \(coordinator.state)")
                return
            }
        }
    }

    @Test @MainActor
    func logEntriesCappedAt100() {
        withDependencies {
            $0.appStorageKeyFormatWarningEnabled = false
        } operation: {
            let coordinator = SyncCoordinator()
            for i in 0..<200 {
                coordinator.appendLog("entry \(i)")
            }
            #expect(coordinator.logEntries.count == 100)
            #expect(coordinator.logEntries.first?.message == "entry 100")
            #expect(coordinator.logEntries.last?.message == "entry 199")
        }
    }

    @Test @MainActor
    func signOutClearsStateAndCancelsActive() async throws {
        // Staged so startSync enters the real .syncing path (and can be
        // cancelled); signOut deletes it on the way to .noServer.
        let credentials = stageTestEndpoint()
        defer { restoreCredentials(credentials) }
        try await withDependencies {
            $0.appStorageKeyFormatWarningEnabled = false
            $0.syncClient.sync = {
                try await Task.sleep(for: .milliseconds(500))
                return SyncSummary()
            }
        } operation: {
            let coordinator = SyncCoordinator()
            await coordinator.startSync()
            try await Task.sleep(for: .milliseconds(20))
            await coordinator.signOut()
            try await Task.sleep(for: .milliseconds(100))
            #expect(coordinator.state == .noServer)
            #expect(coordinator.requiresLogin == false)
        }
    }

    @Test @MainActor
    func cancelMidSync() async throws {
        let credentials = stageTestEndpoint()
        defer { restoreCredentials(credentials) }
        let flag = stageFullSyncFlag()
        defer { restoreFullSyncFlag(flag) }
        // Fresh slate: a leftover flag from an earlier run would open
        // .needsFullSync instead of the .syncing this test cancels.
        UserDefaults.standard.set(false, forKey: SyncPreferences.Keys.needsFullSyncForCurrentUser())
        try await withDependencies {
            $0.appStorageKeyFormatWarningEnabled = false
            $0.syncClient.sync = {
                try await Task.sleep(for: .milliseconds(500))
                return SyncSummary()
            }
        } operation: {
            let coordinator = SyncCoordinator()
            await coordinator.startSync()
            try await Task.sleep(for: .milliseconds(20))
            coordinator.cancel()
            // `cancel()` is advisory: the Rust FFI call has no cancellation
            // hook, so the coordinator stays `.syncing` and keeps `activeTask`
            // set — clearing it here re-opened the `startSync` re-entry gate
            // and allowed two concurrent syncs. The terminal `.idle` arrives
            // later, from `finishCancellationIfNeeded`.
            #expect(coordinator.state == .syncing(message: "Connecting…"))
            #expect(coordinator.logEntries.contains { $0.message.contains("Cancelling") })

            try await Task.sleep(for: .milliseconds(100))
            #expect(coordinator.state == .idle)
            #expect(coordinator.logEntries.contains { $0.message.contains("cancelled") })
        }
    }

    @Test @MainActor
    func appendLogIncrementsAndOrders() {
        withDependencies {
            $0.appStorageKeyFormatWarningEnabled = false
        } operation: {
            let coordinator = SyncCoordinator()
            coordinator.appendLog("first")
            coordinator.appendLog("second", level: .warning)
            coordinator.appendLog("third", level: .error)
            #expect(coordinator.logEntries.count == 3)
            #expect(coordinator.logEntries[0].message == "first")
            #expect(coordinator.logEntries[0].level == .info)
            #expect(coordinator.logEntries[2].level == .error)
        }
    }
}

private actor MediaStatusQueue {
    private var statuses: [MediaSyncStatus]

    init(_ statuses: [MediaSyncStatus]) {
        self.statuses = statuses
    }

    /// Repeats the last entry rather than trapping — the coordinator polls
    /// on its own clock, so the call count isn't fixed.
    func next() -> MediaSyncStatus {
        statuses.count > 1 ? statuses.removeFirst() : statuses[0]
    }
}

private actor AsyncFlag {
    private(set) var value = false

    func set() {
        value = true
    }
}

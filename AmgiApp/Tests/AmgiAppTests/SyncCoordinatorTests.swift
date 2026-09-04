import Testing
import Foundation
import Dependencies
import Sharing
import AnkiKit
import AnkiClients
import AnkiSync
@testable import AmgiApp

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

@Suite("SyncCoordinator state machine")
struct SyncCoordinatorTests {

    @Test @MainActor
    func startSyncSuccessTransitions() async throws {
        let summary = SyncSummary(cardsPushed: 5, cardsPulled: 3)
        let credentials = stageTestEndpoint()
        defer { restoreCredentials(credentials) }
        try await withDependencies {
            $0.appStorageKeyFormatWarningEnabled = false
            $0.syncClient.sync = { summary }
        } operation: {
            let coordinator = SyncCoordinator()
            await coordinator.startSync()
            try await Task.sleep(for: .milliseconds(100))
            guard case .success(let resultSummary) = coordinator.state else {
                Issue.record("expected .success, got \(coordinator.state)")
                return
            }
            #expect(resultSummary == summary)
            #expect(coordinator.lastSuccessfulSync != nil)
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
        try await withDependencies {
            $0.appStorageKeyFormatWarningEnabled = false
            $0.syncClient.sync = { throw SyncError.fullSyncRequired }
            $0.syncClient.fullSync = { _ in /* success */ }
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

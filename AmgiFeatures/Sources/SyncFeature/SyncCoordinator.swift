public import Foundation
import SwiftUI
import UIKit
import AmgiAppCore
import AmgiAppShared
import AnkiClients
public import AnkiKit
import AnkiSync
public import Dependencies

@Observable @MainActor
public final class SyncCoordinator {
    public enum SyncState: Sendable, Equatable {
        case idle
        case syncing(message: String)
        case syncingMedia(total: Int, downloaded: Int)
        case success(SyncSummary)
        case error(String)
        case needsFullSync(SyncFullSyncRequirement)
        case noServer
    }

    public private(set) var state: SyncState = .idle
    private(set) var logEntries: [SyncLogEntry] = []
    private(set) var requiresLogin: Bool = false

    var lastSuccessfulSync: Date? {
        lastSyncedAtUnix > 0 ? Date(timeIntervalSince1970: lastSyncedAtUnix) : nil
    }

    @ObservationIgnored @Dependency(\.syncClient) var syncClient
    @ObservationIgnored private var activeTask: Task<Void, Never>?
    @ObservationIgnored private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    // Profile-scoped persisted state. Computed per access — the key embeds
    // the active profile id, and this coordinator is a singleton that
    // outlives in-app profile switches, so the key must never be captured.
    private var lastSyncedAtUnix: Double {
        get { UserDefaults.standard.double(forKey: SyncPreferences.Keys.lastCollectionSyncedAtForCurrentUser()) }
        set { UserDefaults.standard.set(newValue, forKey: SyncPreferences.Keys.lastCollectionSyncedAtForCurrentUser()) }
    }

    private var needsFullSyncFlag: Bool {
        get { UserDefaults.standard.bool(forKey: SyncPreferences.Keys.needsFullSyncForCurrentUser()) }
        set { UserDefaults.standard.set(newValue, forKey: SyncPreferences.Keys.needsFullSyncForCurrentUser()) }
    }

    private static let logCap = 100

    public init() {
        registerLifecycleObservers()
    }

    // MARK: - Public surface (stubs filled in Phase B)

    public func startSync() async {
        guard activeTask == nil else {
            appendLog("Sync already in progress", level: .warning)
            return
        }

        clearLog()
        state = .syncing(message: "Connecting…")
        appendLog("Starting sync")

        let task = Task { [weak self] in
            guard let self else { return }
            let client = self.syncClient
            do {
                let summary = try await client.sync()
                await MainActor.run {
                    self.appendLog("Sync complete: \(summary.cardsPushed) pushed, \(summary.cardsPulled) pulled")
                    self.state = .success(summary)
                    self.lastSyncedAtUnix = Date().timeIntervalSince1970
                    self.needsFullSyncFlag = false
                    self.activeTask = nil
                }
                // Sync can change counts without any review — refresh widgets
                // or they keep showing the pre-sync collection.
                await writeWidgetSnapshot()
            } catch let error as SyncError where error == .fullSyncRequired {
                await MainActor.run {
                    self.appendLog("Server requires a full sync", level: .warning)
                    self.state = .needsFullSync(SyncFullSyncRequirement(
                        reason: "Schema mismatch — choose upload or download",
                        localIsEmpty: false
                    ))
                    self.needsFullSyncFlag = true
                    self.activeTask = nil
                }
            } catch let error as SyncError where error == .authFailed {
                await MainActor.run {
                    self.appendLog("Authentication failed", level: .error)
                    self.requiresLogin = true
                    self.state = .error("Authentication failed — please sign in again")
                    self.activeTask = nil
                }
            } catch {
                await MainActor.run {
                    // If activeTask is nil the sync was cancelled — don't overwrite state.
                    guard self.activeTask != nil else { return }
                    self.appendLog("Sync failed: \(error.localizedDescription)", level: .error)
                    self.state = .error(error.localizedDescription)
                    self.activeTask = nil
                }
            }
        }
        activeTask = task
    }

    func confirmFullSync(direction: SyncDirection) async {
        guard case .needsFullSync = state else {
            appendLog("Cannot confirm full sync — not in needsFullSync state", level: .warning)
            return
        }

        let label = direction == .upload ? "Uploading collection" : "Downloading collection"
        state = .syncing(message: label)
        appendLog("Full sync started: \(direction == .upload ? "upload" : "download")")

        let task = Task { [weak self] in
            guard let self else { return }
            let client = self.syncClient
            do {
                try await client.fullSync(direction)
                await MainActor.run {
                    self.appendLog("Full sync complete")
                    self.state = .success(SyncSummary())
                    self.lastSyncedAtUnix = Date().timeIntervalSince1970
                    self.needsFullSyncFlag = false
                    self.activeTask = nil
                }
                // A full download replaces the whole collection — widgets are
                // guaranteed stale without a rewrite.
                await writeWidgetSnapshot()
            } catch {
                await MainActor.run {
                    guard self.activeTask != nil else { return }
                    self.appendLog("Full sync failed: \(error.localizedDescription)", level: .error)
                    self.state = .error(error.localizedDescription)
                    self.activeTask = nil
                }
            }
        }
        activeTask = task
    }

    func signOut() async {
        cancel()
        KeychainHelper.deleteEndpoint()
        KeychainHelper.deleteHostKey()
        KeychainHelper.deleteUsername()
        appendLog("Signed out")
        state = .noServer
        requiresLogin = false
    }

    /// Called after an in-app profile switch, once the scoping anchor has
    /// flipped: drop the old profile's transient state and re-derive from
    /// the new profile's persisted flags.
    public func resetForProfileSwitch() {
        cancel()
        clearLog()
        requiresLogin = false
        if needsFullSyncFlag {
            state = .needsFullSync(SyncFullSyncRequirement(
                reason: "A full sync was requested previously and not yet completed",
                localIsEmpty: false
            ))
        } else {
            state = .idle
        }
    }

    public func cancel() {
        activeTask?.cancel()
        activeTask = nil
        if case .syncing = state {
            appendLog("Sync cancelled", level: .warning)
            state = .idle
        } else if case .syncingMedia = state {
            appendLog("Media sync cancelled", level: .warning)
            state = .idle
        }
    }

    // MARK: - Log helpers (used by all behaviors)

    func appendLog(_ message: String, level: SyncLogEntry.Level = .info) {
        let entry = SyncLogEntry(message: message, level: level)
        logEntries.append(entry)
        if logEntries.count > Self.logCap {
            logEntries.removeFirst(logEntries.count - Self.logCap)
        }
    }

    func clearLog() {
        logEntries.removeAll()
    }
}

private extension SyncCoordinator {
    func registerLifecycleObservers() {
        let center = NotificationCenter.default
        center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.beginBackgroundExecutionIfNeeded()
            }
        }
        center.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.endBackgroundExecutionIfNeeded()
            }
        }

        if needsFullSyncFlag {
            state = .needsFullSync(SyncFullSyncRequirement(
                reason: "A full sync was requested previously and not yet completed",
                localIsEmpty: false
            ))
        }
    }

    func beginBackgroundExecutionIfNeeded() {
        let isSyncing: Bool
        switch state {
        case .syncing, .syncingMedia: isSyncing = true
        default: isSyncing = false
        }
        guard isSyncing, backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "AmgiSync") { [weak self] in
            // System forced expiration — end task and let cancel() handle state.
            Task { @MainActor in
                self?.endBackgroundExecutionIfNeeded()
                self?.cancel()
            }
        }
        appendLog("Backgrounded mid-sync — extending execution window")
    }

    func endBackgroundExecutionIfNeeded() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
        appendLog("Foreground resumed — released BG task")
    }
}

private enum SyncCoordinatorKey: DependencyKey {
    static let liveValue: SyncCoordinator = MainActor.assumeIsolated { SyncCoordinator() }
    static let testValue: SyncCoordinator = MainActor.assumeIsolated { SyncCoordinator() }
}

extension DependencyValues {
    public var syncCoordinator: SyncCoordinator {
        get { self[SyncCoordinatorKey.self] }
        set { self[SyncCoordinatorKey.self] = newValue }
    }
}

import Foundation
import Network
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
import AnkiClients
import AnkiKit
import AnkiSync
import Dependencies
import Sharing

@Observable @MainActor
final class SyncCoordinator {
    enum SyncState: Sendable, Equatable {
        case idle
        case syncing(message: String)
        case syncingMedia(total: Int, downloaded: Int)
        case success(SyncSummary)
        case error(String)
        case needsFullSync(SyncFullSyncRequirement)
        case noServer
    }

    private(set) var state: SyncState = .idle
    private(set) var logEntries: [SyncLogEntry] = []
    private(set) var requiresLogin: Bool = false
    private(set) var shouldPresentAttention = false

    var lastSuccessfulSync: Date? {
        lastSyncedAtUnix > 0 ? Date(timeIntervalSince1970: lastSyncedAtUnix) : nil
    }

    @ObservationIgnored @Dependency(\.syncClient) var syncClient
    @ObservationIgnored private var activeTask: Task<Void, Never>?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var periodicTask: Task<Void, Never>?
    @ObservationIgnored private var isApplicationActive = true
    @ObservationIgnored private var automaticFailurePending = false
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    @ObservationIgnored private var currentPath: NWPath?
    // iOS-only: extends the execution window when the app is backgrounded
    // mid-sync. Desktop sync runs while the app is active, so macOS needs
    // no equivalent.
    #if os(iOS)
    @ObservationIgnored private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    #endif

    @ObservationIgnored
    @Shared(.appStorage(SyncPreferences.Keys.lastCollectionSyncedAtForCurrentUser()))
    private var lastSyncedAtUnix: Double = 0

    @ObservationIgnored
    @Shared(.appStorage(SyncPreferences.Keys.needsFullSyncForCurrentUser()))
    private var needsFullSyncFlag: Bool = false

    @ObservationIgnored
    @Shared(.appStorage(SyncPreferences.Keys.autoSyncEnabledForCurrentUser()))
    private var autoSyncEnabled: Bool = true

    @ObservationIgnored
    @Shared(.appStorage(SyncPreferences.Keys.autoSyncNetworkPolicyForCurrentUser()))
    private var autoSyncNetworkPolicyRaw: String = SyncPreferences.NetworkPolicy.wifiOnly.rawValue

    private static let logCap = 100

    init() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in self?.currentPath = path }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.amgiapp.sync-network"))
        registerLifecycleObservers()
    }

    // MARK: - Public surface (stubs filled in Phase B)

    func startSync(isAutomatic: Bool = false) async {
        guard activeTask == nil else {
            return
        }

        guard KeychainHelper.loadEndpoint() != nil else {
            state = .noServer
            return
        }

        if isAutomatic && !networkAllowsAutomaticSync {
            return
        }

        clearLog()
        state = .syncing(message: "Connecting…")
        appendLog("Starting sync")
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: SyncPreferences.Keys.autoSyncLastAttemptForCurrentUser())

        let task = Task { [weak self] in
            guard let self else { return }
            let client = self.syncClient
            do {
                let summary = try await client.sync()
                await MainActor.run {
                    self.appendLog("Sync complete: \(summary.cardsPushed) pushed, \(summary.cardsPulled) pulled")
                    self.state = .success(summary)
                    self.$lastSyncedAtUnix.withLock { $0 = Date().timeIntervalSince1970 }
                    self.$needsFullSyncFlag.withLock { $0 = false }
                    UserDefaults.standard.removeObject(forKey: SyncPreferences.Keys.autoSyncLastErrorForCurrentUser())
                    self.automaticFailurePending = false
                    self.shouldPresentAttention = false
                    self.activeTask = nil
                }
            } catch let error as SyncError where error == .fullSyncRequired {
                await MainActor.run {
                    self.appendLog("Server requires a full sync", level: .warning)
                    self.state = .needsFullSync(SyncFullSyncRequirement(
                        reason: "Schema mismatch — choose upload or download",
                        localIsEmpty: false
                    ))
                    self.$needsFullSyncFlag.withLock { $0 = true }
                    self.automaticFailurePending = isAutomatic
                    self.shouldPresentAttention = !isAutomatic
                    self.activeTask = nil
                }
            } catch let error as SyncError where error == .authFailed {
                await MainActor.run {
                    self.appendLog("Authentication failed", level: .error)
                    self.requiresLogin = true
                    self.state = .error("Authentication failed — please sign in again")
                    self.recordAutomaticFailure(error.localizedDescription, isAutomatic: isAutomatic)
                    self.activeTask = nil
                }
            } catch {
                await MainActor.run {
                    // If activeTask is nil the sync was cancelled — don't overwrite state.
                    guard self.activeTask != nil else { return }
                    self.appendLog("Sync failed: \(error.localizedDescription)", level: .error)
                    self.state = .error(error.localizedDescription)
                    self.recordAutomaticFailure(error.localizedDescription, isAutomatic: isAutomatic)
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
                    self.$lastSyncedAtUnix.withLock { $0 = Date().timeIntervalSince1970 }
                    self.$needsFullSyncFlag.withLock { $0 = false }
                    self.activeTask = nil
                }
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
        $autoSyncEnabled.withLock { $0 = false }
        debounceTask?.cancel()
        periodicTask?.cancel()
        KeychainHelper.deleteEndpoint()
        KeychainHelper.deleteHostKey()
        KeychainHelper.deleteUsername()
        appendLog("Signed out")
        state = .noServer
        requiresLogin = false
        shouldPresentAttention = false
        automaticFailurePending = false
    }

    func cancel() {
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

    // MARK: - Automatic sync

    func requestAutomaticSync(reason: String) {
        guard autoSyncEnabled, KeychainHelper.loadEndpoint() != nil else { return }
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            appendLog("Automatic sync requested: \(reason)")
            await startSync(isAutomatic: true)
        }
    }

    func setApplicationActive(_ active: Bool) {
        isApplicationActive = active
        if active {
            startAutomaticScheduling()
            if automaticFailurePending {
                automaticFailurePending = false
                shouldPresentAttention = true
            }
        } else {
            periodicTask?.cancel()
            periodicTask = nil
        }
    }

    func startAutomaticScheduling() {
        guard autoSyncEnabled, isApplicationActive, periodicTask == nil else { return }
        periodicTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15 * 60))
                guard !Task.isCancelled, let self else { return }
                await startSync(isAutomatic: true)
            }
        }
    }

    func enableAutomaticSync() {
        $autoSyncEnabled.withLock { $0 = true }
        startAutomaticScheduling()
        requestAutomaticSync(reason: "Sync server configured")
    }

    func disableAutomaticSync() {
        $autoSyncEnabled.withLock { $0 = false }
        debounceTask?.cancel()
        periodicTask?.cancel()
        periodicTask = nil
    }

    func dismissAttention() {
        shouldPresentAttention = false
    }
}

private extension SyncCoordinator {
    var networkPolicy: SyncPreferences.NetworkPolicy {
        SyncPreferences.NetworkPolicy(rawValue: autoSyncNetworkPolicyRaw) ?? .wifiOnly
    }

    var networkAllowsAutomaticSync: Bool {
        switch networkPolicy {
        case .disabled: return false
        case .any: return true
        case .wifiOnly:
            guard let currentPath else { return true }
            return currentPath.status == .satisfied && currentPath.usesInterfaceType(.wifi)
        }
    }

    func recordAutomaticFailure(_ message: String, isAutomatic: Bool) {
        guard isAutomatic else {
            shouldPresentAttention = true
            return
        }
        UserDefaults.standard.set(message, forKey: SyncPreferences.Keys.autoSyncLastErrorForCurrentUser())
        automaticFailurePending = true
        shouldPresentAttention = false
    }

    func registerLifecycleObservers() {
        // iOS background/foreground transitions only: they bracket the
        // beginBackgroundTask window that keeps a mid-flight sync alive
        // after the app leaves the foreground. macOS stays resident while
        // syncing, so there is nothing to observe.
        #if os(iOS)
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
        #endif

        if needsFullSyncFlag {
            state = .needsFullSync(SyncFullSyncRequirement(
                reason: "A full sync was requested previously and not yet completed",
                localIsEmpty: false
            ))
        }
    }

    #if os(iOS)
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
    #endif
}

private enum SyncCoordinatorKey: DependencyKey {
    static let liveValue: SyncCoordinator = MainActor.assumeIsolated { SyncCoordinator() }
    static let testValue: SyncCoordinator = MainActor.assumeIsolated { SyncCoordinator() }
}

extension DependencyValues {
    var syncCoordinator: SyncCoordinator {
        get { self[SyncCoordinatorKey.self] }
        set { self[SyncCoordinatorKey.self] = newValue }
    }
}

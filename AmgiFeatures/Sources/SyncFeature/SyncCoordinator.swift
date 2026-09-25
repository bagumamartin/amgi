public import Foundation
import SwiftUI
#if os(iOS)
import UIKit
#endif
import AmgiAppCore
import AmgiAppShared
import AnkiClients
import AnkiKit
import AnkiSync
package import Dependencies

@Observable @MainActor
package final class SyncCoordinator {
    enum SyncState: Sendable, Equatable {
        case idle
        case syncing(message: String)
        /// Assigned only from `waitForMediaCompletion`, carrying the engine's
        /// own localized progress line. It was previously declared and never
        /// assigned — a progress state that could not occur — and was
        /// removed for that reason; the engine can supply real progress now.
        case syncingMedia(String)
        case success(SyncSummary)
        case error(String)
        case needsFullSync(SyncFullSyncRequirement)
        case noServer
    }

    private(set) var state: SyncState = .idle
    private(set) var logEntries: [SyncLogEntry] = []
    private(set) var requiresLogin: Bool = false

    var lastSuccessfulSync: Date? {
        lastSyncedAtUnix > 0 ? Date(timeIntervalSince1970: lastSyncedAtUnix) : nil
    }

    @ObservationIgnored @Dependency(\.syncClient) var syncClient
    @ObservationIgnored @Dependency(\.collectionStore) private var collectionStore
    @ObservationIgnored private var activeTask: Task<SyncExecutionResult, Never>?
    /// Set by `cancel()`. Distinct from `activeTask` because cancellation is
    /// advisory — the in-flight FFI call still runs to completion, so the
    /// task handle has to stay put to keep the re-entry gate shut.
    @ObservationIgnored private var isCancelling = false
    #if os(iOS)
    @ObservationIgnored private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    #endif
    @ObservationIgnored private var lifecycleObservers: [any NSObjectProtocol] = []
    /// How often `waitForMediaCompletion` re-reads the engine's media
    /// status. Injectable so tests don't pay the real interval.
    @ObservationIgnored private let mediaPollInterval: Duration
    @ObservationIgnored private var automaticSyncDebounce: Task<Void, Never>?
    @ObservationIgnored private var scheduledSyncTask: Task<Void, Never>?
    @ObservationIgnored private var mediaAbortTask: Task<Void, Never>?
    @ObservationIgnored private var mergeProgressID: UUID?
    @ObservationIgnored private var collectionLifecycleDepth = 0
    @ObservationIgnored private var activeSyncIncludesMedia = false
    private var isCollectionLifecycleBlocked: Bool { collectionLifecycleDepth > 0 }

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

    /// Monotonic local-mutation marker. It is persisted per profile so a
    /// dirty collection survives suspension, app termination, and profile
    /// switches without relying on an in-memory timer.
    private var dirtyGeneration: Int {
        get { UserDefaults.standard.integer(forKey: SyncPreferences.Keys.dirtyGenerationForCurrentUser()) }
        set { UserDefaults.standard.set(newValue, forKey: SyncPreferences.Keys.dirtyGenerationForCurrentUser()) }
    }

    private static let logCap = 100

    /// Nonisolated so `SyncCoordinatorKey`'s lazy statics can be initialized
    /// from any thread — a `static let` is initialized by whichever thread
    /// touches it first, so the old `MainActor.assumeIsolated` would abort
    /// the process on first resolution from a detached task or background
    /// test. Observer registration is main-actor work, so it hops.
    package nonisolated init(mediaPollInterval: Duration = .milliseconds(250)) {
        self.mediaPollInterval = mediaPollInterval
        Task { @MainActor [self] in registerLifecycleObservers() }
    }

    /// `isolated deinit` so the observer tokens can be plain main-actor state
    /// instead of `nonisolated(unsafe)` — a nonisolated `deinit` was the only
    /// thing reading them from off the actor, and it is the only reason the
    /// array carried an unchecked escape hatch.
    ///
    /// Tokens from addObserver(forName:object:queue:) were previously
    /// discarded, so the observers outlived any non-singleton instance
    /// and kept calling into a dead coordinator.
    isolated deinit {
        for token in lifecycleObservers {
            NotificationCenter.default.removeObserver(token)
        }
    }

    /// Consumes a pending cancellation: resets state to idle and returns
    /// true if `cancel()` was called while this operation was in flight.
    private func finishCancellationIfNeeded() -> Bool {
        guard isCancelling else { return false }
        isCancelling = false
        appendLog("Sync cancelled", level: .warning)
        // Not over `.noServer`: `signOut()` cancels the in-flight sync and
        // *then* sets `.noServer`, so this completion lands afterwards and
        // would otherwise report a signed-out coordinator as merely idle —
        // i.e. as still having a server configured.
        if case .noServer = state {} else { state = .idle }
        return true
    }

    // MARK: - Public surface (stubs filled in Phase B)

    /// Starts a user-visible sync. The task remains asynchronous for the
    /// existing toolbar/sheet callers; `startSyncAndWait` below is used by
    /// background work that must observe the real completion.
    package func startSync(includeMedia: Bool = true) async {
        _ = beginSync(includeMedia: includeMedia, automatic: false)
    }

    package func startSyncAndWait(includeMedia: Bool = true) async -> SyncExecutionResult {
        guard !Task.isCancelled else { return .cancelled }
        guard activeTask == nil, mediaAbortTask == nil else { return .cancelled }
        let task = beginSync(includeMedia: includeMedia, automatic: true)
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel()
            }
        }
    }

    /// Runs a quiet, collection-only check for lifecycle/background callers.
    /// Unlike `requestAutomaticSync`, this also pulls remote changes when the
    /// local profile is clean.
    package func runScheduledCollectionSync() async -> SyncExecutionResult {
        await startSyncAndWait(includeMedia: false)
    }

    /// Foreground-friendly variant that avoids a network request on every
    /// scene activation. The OS still decides when the actual background task
    /// runs; this is only the inexpensive in-process recovery path.
    package func runScheduledCollectionSyncIfNeeded(after interval: TimeInterval = 15 * 60) {
        guard !isCollectionLifecycleBlocked,
              !needsFullSyncFlag,
              !(KeychainHelper.loadEndpoint() ?? "").isEmpty,
              !(KeychainHelper.loadHostKey() ?? "").isEmpty
        else { return }
        if let lastSuccessfulSync,
           Date().timeIntervalSince(lastSuccessfulSync) < interval {
            return
        }
        guard scheduledSyncTask == nil, activeTask == nil else { return }
        let profileID = AccountStore.shared.selectedID
        scheduledSyncTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.scheduledSyncTask = nil }
            guard AccountStore.shared.selectedID == profileID else { return }
            _ = await self.runScheduledCollectionSync()
        }
    }

    private func beginSync(
        includeMedia: Bool,
        automatic: Bool
    ) -> Task<SyncExecutionResult, Never> {
        guard !isCollectionLifecycleBlocked else {
            return Task<SyncExecutionResult, Never> { .cancelled }
        }
        guard activeTask == nil, mediaAbortTask == nil else {
            appendLog("Sync already in progress", level: .warning)
            return Task<SyncExecutionResult, Never> { .cancelled }
        }

        NetworkMonitor.shared.start()
        if automatic && !NetworkMonitor.shared.isSatisfied {
            appendLog("Automatic sync skipped: network unavailable", level: .warning)
            return Task<SyncExecutionResult, Never> { .failed("Network unavailable") }
        }
        let hasEndpoint = !(KeychainHelper.loadEndpoint() ?? "").isEmpty
        let hasHostKey = !(KeychainHelper.loadHostKey() ?? "").isEmpty
        if automatic && !hasEndpoint {
            appendLog("Automatic sync skipped: no sync server", level: .warning)
            return Task<SyncExecutionResult, Never> { .noServer }
        }
        if automatic && !hasHostKey {
            requiresLogin = true
            appendLog("Automatic sync skipped: authentication required", level: .warning)
            return Task<SyncExecutionResult, Never> { .needsLogin }
        }
        if needsFullSyncFlag {
            if !automatic {
                state = .needsFullSync(SyncFullSyncRequirement(
                    reason: "A full sync was requested previously and not yet completed",
                    localIsEmpty: false
                ))
            }
            return Task<SyncExecutionResult, Never> { .needsFullSync }
        }

        let profileID = AccountStore.shared.selectedID
        let expectedDirtyGeneration = dirtyGeneration
        activeSyncIncludesMedia = includeMedia
        let client = syncClient
        if !automatic {
            clearLog()
            state = .syncing(message: "Connecting…")
        }
        appendLog(automatic ? "Automatic collection sync requested" : "Starting sync")

        let task = Task { [weak self] () -> SyncExecutionResult in
            guard let self else { return .cancelled }
            defer {
                self.activeSyncIncludesMedia = false
                if self.mediaAbortTask == nil {
                    self.endBackgroundExecutionIfNeeded()
                }
            }
            var collectionCommitted = false
            do {
                try Task.checkCancellation()
                collectionCommitted = true
                let summary: SyncSummary
                if includeMedia {
                    summary = try await client.sync()
                } else {
                    summary = try await client.syncCollection()
                }
                collectionCommitted = true
                // `sync()` kicks media off in the background and returns
                // immediately; without this the sheet claimed success while
                // media was still downloading. Collection-only background
                // sync deliberately skips this wait and never starts media.
                let mediaFailure = includeMedia
                    ? try await self.awaitMediaCompletion(using: client)
                    : nil
                try Task.checkCancellation()

                guard AccountStore.shared.selectedID == profileID else {
                    self.activeTask = nil
                    self.isCancelling = false
                    self.state = .idle
                    return .cancelled
                }
                try Task.checkCancellation()

                // Recorded even when media failed: the collection is already
                // committed by this point, and letting one bad media file roll
                // the timestamp back made the next sync look overdue.
                self.lastSyncedAtUnix = Date().timeIntervalSince1970
                self.requiresLogin = false
                self.needsFullSyncFlag = false
                self.clearDirty(through: expectedDirtyGeneration)
                self.collectionStore.invalidateAll(origin: .remoteSync)
                if automatic {
                    self.appendLog(
                        mediaFailure.map { "Automatic collection sync complete; media skipped (\($0))" }
                            ?? "Automatic collection sync complete"
                    )
                } else {
                    self.report(mediaFailure: mediaFailure, otherwise: summary)
                }
                // Keep activeTask installed until the snapshot write finishes;
                // profile switching and collection replacement must not close
                // the database while this task still reads it.
                await WidgetRefreshCoordinator.shared.refreshNow()
                try Task.checkCancellation()
                self.activeTask = nil
                self.isCancelling = false
                if self.dirtyGeneration > expectedDirtyGeneration {
                    self.resumeAutomaticSyncIfNeeded(reason: "Changes arrived during sync")
                }
                if let mediaFailure {
                    return .failed("Collection synced, but media failed: \(mediaFailure)")
                }
                return .success(summary)
            } catch is CancellationError {
                let wasCancellationRequested = self.isCancelling
                if collectionCommitted {
                    self.collectionStore.invalidateAll(origin: .remoteSync)
                    WidgetRefreshCoordinator.shared.request(reason: "Cancelled sync committed collection")
                }
                _ = self.finishCancellationIfNeeded()
                self.activeTask = nil
                if !wasCancellationRequested, case .syncing = self.state {
                    self.state = .idle
                } else if !wasCancellationRequested, case .syncingMedia = self.state {
                    self.state = .idle
                }
                return .cancelled
            } catch let error as SyncError where error == .fullSyncRequired {
                self.appendLog("Server requires a full sync", level: .warning)
                self.state = .needsFullSync(SyncFullSyncRequirement(
                    reason: "Schema mismatch — choose upload or download",
                    localIsEmpty: false
                ))
                self.needsFullSyncFlag = true
                self.activeTask = nil
                self.isCancelling = false
                return .needsFullSync
            } catch let error as SyncError where error == .authFailed {
                self.appendLog("Authentication failed", level: .error)
                self.requiresLogin = true
                if !automatic {
                    self.state = .error("Authentication failed — please sign in again")
                }
                self.activeTask = nil
                self.isCancelling = false
                return .needsLogin
            } catch {
                self.activeTask = nil
                if collectionCommitted {
                    self.collectionStore.invalidateAll(origin: .remoteSync)
                    WidgetRefreshCoordinator.shared.request(reason: "Sync failure refreshed collection")
                }
                // A cancelled sync shouldn't surface as a failure.
                guard !self.finishCancellationIfNeeded() else { return .cancelled }
                self.appendLog("Sync failed: \(error.localizedDescription)", level: .error)
                if !automatic {
                    self.state = .error(error.localizedDescription)
                }
                return .failed(error.localizedDescription)
            }
        }
        activeTask = task
        #if os(iOS)
        if UIApplication.shared.applicationState == .background {
            beginBackgroundExecutionIfNeeded()
        }
        #endif
        return task
    }

    func confirmFullSync(direction: SyncDirection) async {
        guard !isCollectionLifecycleBlocked, mediaAbortTask == nil else { return }
        guard case .needsFullSync = state else {
            appendLog("Cannot confirm full sync — not in needsFullSync state", level: .warning)
            return
        }

        let label = direction == .upload ? "Uploading collection" : "Downloading collection"
        state = .syncing(message: label)
        appendLog("Full sync started: \(direction == .upload ? "upload" : "download")")

        activeSyncIncludesMedia = true
        let expectedDirtyGeneration = dirtyGeneration
        let task = Task { [weak self] () -> SyncExecutionResult in
            guard let self else { return .cancelled }
            defer {
                self.activeSyncIncludesMedia = false
                if self.mediaAbortTask == nil {
                    self.endBackgroundExecutionIfNeeded()
                }
            }
            var collectionCommitted = false
            let client = self.syncClient
            do {
                try Task.checkCancellation()
                collectionCommitted = true
                try await client.fullSync(direction)
                collectionCommitted = true
                let mediaFailure = try await self.awaitMediaCompletion(using: client)
                self.lastSyncedAtUnix = Date().timeIntervalSince1970
                self.requiresLogin = false
                self.needsFullSyncFlag = false
                self.clearDirty(through: expectedDirtyGeneration)
                self.collectionStore.invalidateAll(origin: .remoteSync)
                self.report(mediaFailure: mediaFailure, otherwise: SyncSummary())
                // A full download replaces the whole collection — widgets are
                // guaranteed stale without a rewrite. Keep activeTask set
                // until this read completes so lifecycle operations wait.
                await WidgetRefreshCoordinator.shared.refreshNow()
                try Task.checkCancellation()
                self.activeTask = nil
                self.isCancelling = false
                if self.dirtyGeneration > expectedDirtyGeneration {
                    self.resumeAutomaticSyncIfNeeded(reason: "Changes arrived during full sync")
                }
                if let mediaFailure {
                    return .failed("Collection synced, but media failed: \(mediaFailure)")
                }
                return .success(SyncSummary())
            } catch is CancellationError {
                let wasCancellationRequested = self.isCancelling
                if collectionCommitted {
                    self.collectionStore.invalidateAll(origin: .remoteSync)
                    WidgetRefreshCoordinator.shared.request(reason: "Cancelled full sync committed collection")
                }
                _ = self.finishCancellationIfNeeded()
                self.activeTask = nil
                if !wasCancellationRequested { self.state = .idle }
                return .cancelled
            } catch {
                self.activeTask = nil
                if collectionCommitted {
                    self.collectionStore.invalidateAll(origin: .remoteSync)
                    WidgetRefreshCoordinator.shared.request(reason: "Full sync failure refreshed collection")
                }
                guard !self.finishCancellationIfNeeded() else { return .cancelled }
                self.appendLog("Full sync failed: \(error.localizedDescription)", level: .error)
                self.state = .error(error.localizedDescription)
                return .failed(error.localizedDescription)
            }
        }
        activeTask = task
        #if os(iOS)
        if UIApplication.shared.applicationState == .background {
            beginBackgroundExecutionIfNeeded()
        }
        #endif
    }

    /// Performs the destructive download/import/upload merge through the same
    /// operation gate as ordinary sync. The UI action remains manual, but it
    /// can no longer race profile changes, exports, or another sync.
    func mergeFullSync() {
        guard !isCollectionLifecycleBlocked, mediaAbortTask == nil else { return }
        guard case .needsFullSync = state else {
            appendLog("Cannot merge — not in needsFullSync state", level: .warning)
            return
        }

        state = .syncing(message: "Preparing merge…")
        appendLog("Full sync merge started")
        activeSyncIncludesMedia = true
        let expectedDirtyGeneration = dirtyGeneration
        let profileID = AccountStore.shared.selectedID
        let progressID = UUID()
        mergeProgressID = progressID

        let task = Task { [weak self] () -> SyncExecutionResult in
            guard let self else { return .cancelled }
            defer {
                self.activeSyncIncludesMedia = false
                if self.mediaAbortTask == nil {
                    self.endBackgroundExecutionIfNeeded()
                }
            }
            var collectionCommitted = false
            let client = self.syncClient
            do {
                try Task.checkCancellation()
                // The merge workflow is destructive once it starts. Treat any
                // failure after this point as potentially partially committed
                // so the shared cache and widget are refreshed conservatively.
                collectionCommitted = true
                try await client.merge { [weak self] message in
                    Task { @MainActor [weak self] in
                        guard let self, self.mergeProgressID == progressID else { return }
                        self.state = .syncing(message: message)
                    }
                }
                collectionCommitted = true
                try Task.checkCancellation()
                let mediaFailure = try await self.awaitMediaCompletion(using: client)
                try Task.checkCancellation()
                guard AccountStore.shared.selectedID == profileID else {
                    self.mergeProgressID = nil
                    self.activeTask = nil
                    self.isCancelling = false
                    return .cancelled
                }

                self.lastSyncedAtUnix = Date().timeIntervalSince1970
                self.requiresLogin = false
                self.needsFullSyncFlag = false
                self.clearDirty(through: expectedDirtyGeneration)
                self.collectionStore.invalidateAll(origin: .remoteSync)
                self.mergeProgressID = nil
                self.report(mediaFailure: mediaFailure, otherwise: SyncSummary())
                await WidgetRefreshCoordinator.shared.refreshNow()
                try Task.checkCancellation()
                self.activeTask = nil
                self.isCancelling = false
                if self.dirtyGeneration > expectedDirtyGeneration {
                    self.resumeAutomaticSyncIfNeeded(reason: "Changes arrived during merge")
                }
                if let mediaFailure {
                    return .failed("Collection synced, but media failed: \(mediaFailure)")
                }
                return .success(SyncSummary())
            } catch is CancellationError {
                let wasCancellationRequested = self.isCancelling
                if collectionCommitted {
                    self.collectionStore.invalidateAll(origin: .remoteSync)
                    WidgetRefreshCoordinator.shared.request(reason: "Cancelled merge committed collection")
                }
                _ = self.finishCancellationIfNeeded()
                self.mergeProgressID = nil
                self.activeTask = nil
                if !wasCancellationRequested { self.state = .idle }
                return .cancelled
            } catch {
                self.mergeProgressID = nil
                self.activeTask = nil
                if collectionCommitted {
                    self.collectionStore.invalidateAll(origin: .remoteSync)
                    WidgetRefreshCoordinator.shared.request(reason: "Merge failure refreshed collection")
                }
                guard !self.finishCancellationIfNeeded() else { return .cancelled }
                self.appendLog("Merge failed: \(error.localizedDescription)", level: .error)
                self.state = .error(error.localizedDescription)
                return .failed(error.localizedDescription)
            }
        }
        activeTask = task
        #if os(iOS)
        if UIApplication.shared.applicationState == .background {
            beginBackgroundExecutionIfNeeded()
        }
        #endif
    }

    package func signOut() async {
        cancel()
        KeychainHelper.deleteEndpoint()
        KeychainHelper.deleteHostKey()
        KeychainHelper.deleteUsername()
        appendLog("Signed out")
        state = .noServer
        requiresLogin = false
    }

    /// Debounced collection-only sync after a confirmed local mutation.
    /// The dirty marker is recorded even when no server is configured, so a
    /// later sign-in or foreground pass can still catch up safely.
    package func requestAutomaticSync(reason: String) {
        let profileID = AccountStore.shared.selectedID
        dirtyGeneration &+= 1
        guard !(KeychainHelper.loadEndpoint() ?? "").isEmpty else { return }
        guard !needsFullSyncFlag, !isCollectionLifecycleBlocked else { return }

        automaticSyncDebounce?.cancel()
        automaticSyncDebounce = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                return
            }
            guard !Task.isCancelled,
                  let self,
                  AccountStore.shared.selectedID == profileID
            else { return }
            self.appendLog("Automatic sync requested: \(reason)")
            _ = await self.startSyncAndWait(includeMedia: false)
        }
    }

    /// Resumes a pending collection sync without creating a new dirty event.
    /// Used when the app returns to the foreground or a profile is reopened.
    package func resumeAutomaticSyncIfNeeded(reason: String) {
        guard dirtyGeneration > 0,
              !isCollectionLifecycleBlocked,
              !(KeychainHelper.loadEndpoint() ?? "").isEmpty,
              !(KeychainHelper.loadHostKey() ?? "").isEmpty,
              !needsFullSyncFlag
        else { return }

        let profileID = AccountStore.shared.selectedID
        automaticSyncDebounce?.cancel()
        automaticSyncDebounce = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            guard !Task.isCancelled,
                  let self,
                  AccountStore.shared.selectedID == profileID
            else { return }
            self.appendLog("Pending automatic sync resumed: \(reason)")
            _ = await self.startSyncAndWait(includeMedia: false)
        }
    }

    /// Prevents new sync operations while the caller closes, replaces, or
    /// resets the collection. Call `cancelAndWait()` immediately after this
    /// method, then pair it with `endCollectionLifecycle()` in a defer.
    @discardableResult
    package func beginCollectionLifecycle() -> Bool {
        guard collectionLifecycleDepth == 0 else { return false }
        collectionLifecycleDepth = 1
        WidgetRefreshCoordinator.shared.beginDrain()
        cancel()
        return true
    }

    package func endCollectionLifecycle() {
        guard collectionLifecycleDepth > 0 else { return }
        collectionLifecycleDepth -= 1
        if collectionLifecycleDepth == 0 {
            WidgetRefreshCoordinator.shared.endDrain()
        }
    }

    /// Called after an in-app profile switch, once the scoping anchor has
    /// flipped: drop the old profile's transient state and re-derive from
    /// the new profile's persisted flags.
    package func resetForProfileSwitch() {
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

    /// Requests cancellation. Advisory only.
    ///
    /// The engine call is synchronous Rust FFI with no cancellation hook, so
    /// the RPC runs to completion regardless. What matters is that
    /// `activeTask` is *not* cleared here: doing so re-opened the re-entry
    /// gate in `startSync`, letting a second sync start while the first was
    /// still mutating the collection. Both then serialized behind the
    /// backend lock and a stale full-download could land after a newer
    /// operation — collection-level data loss. The task clears itself when
    /// the in-flight work actually finishes.
    package func cancel() {
        automaticSyncDebounce?.cancel()
        automaticSyncDebounce = nil
        scheduledSyncTask?.cancel()
        mergeProgressID = nil
        guard activeTask != nil, !isCancelling else { return }
        isCancelling = true
        activeTask?.cancel()
        if activeSyncIncludesMedia, case .syncingMedia = state {
            appendLog("Media sync cancelled", level: .warning)
            let client = syncClient
            mediaAbortTask = Task { [weak self] in
                do {
                    try await client.abortMediaSync()
                } catch {
                    self?.appendLog(
                        "Failed to request media abort: \(error.localizedDescription)",
                        level: .error
                    )
                }
                guard let self else { return }
                // `abort_media_sync` acknowledges the request but does
                // not itself join the engine worker. Poll until the worker
                // is actually idle before lifecycle work closes the
                // collection. Status errors are retried rather than treated
                // as proof that the worker stopped.
                await self.drainMediaCompletion(using: client)
                self.mediaAbortTask = nil
                self.endBackgroundExecutionIfNeeded()
            }
            // Media polling may wait on a long backend interval. Reflect the
            // cancellation immediately while keeping activeTask installed as
            // the re-entry gate until the FFI call unwinds.
            state = .idle
        } else if case .syncing = state {
            appendLog("Cancelling — finishing the current step in the background", level: .warning)
        }
    }

    /// Cancels an active sync and waits until its task has actually released
    /// the backend before a collection-lifecycle operation begins. The waiter
    /// is deliberately non-cancellable: a caller losing its own task must not
    /// release a lifecycle barrier while the engine operation is still live.
    package func cancelAndWait() async {
        cancel()
        let waiter = Task { @MainActor [weak self] in
            guard let self else { return }
            while self.activeTask != nil || self.mediaAbortTask != nil || self.scheduledSyncTask != nil {
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        await waiter.value
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
    func clearDirty(through generation: Int) {
        guard dirtyGeneration == generation else { return }
        dirtyGeneration = 0
    }

    /// Waits out the media sync and *returns* its failure rather than
    /// throwing it. The collection sync has already committed by the time
    /// this runs, so a media error is a partial failure, not a failed sync,
    /// and must not unwind the caller's success bookkeeping. Cancellation
    /// still propagates — a cancelled sync is not a completed one.
    /// Returns the failure's description, not the error itself — `any Error`
    /// is not `Sendable`, and this result crosses into `MainActor.run`.
    func awaitMediaCompletion(using client: SyncClient) async throws -> String? {
        do {
            try await waitForMediaCompletion(using: client)
            return nil
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let message = error.localizedDescription
            // A media status error can leave the engine worker alive. Abort
            // and join it before allowing the active collection task to
            // clear, otherwise a lifecycle operation could close underneath
            // that worker.
            do {
                try await client.abortMediaSync()
            } catch {
                appendLog("Failed to request media abort after error: \(error.localizedDescription)", level: .error)
            }
            await drainMediaCompletion(using: client)
            return message
        }
    }

    /// Terminal state for a sync whose collection half succeeded.
    func report(mediaFailure: String?, otherwise summary: SyncSummary) {
        guard let mediaFailure else {
            appendLog("Sync complete: \(summary.cardsPushed) pushed, \(summary.cardsPulled) pulled")
            state = .success(summary)
            return
        }
        appendLog("Collection synced; media sync failed: \(mediaFailure)", level: .error)
        state = .error("Collection synced, but media failed: \(mediaFailure)")
    }

    /// The engine localizes its own progress lines, so they are shown as-is.
    /// Nil until the background task publishes its first snapshot.
    static func mediaProgressMessage(_ progress: MediaSyncProgress?) -> String {
        guard let progress else { return "Syncing media\u{2026}" }
        return "\(progress.checked) \u{00B7} \(progress.added)"
    }

    /// Polls the engine until its background media task reports idle,
    /// publishing each progress snapshot as `.syncingMedia`.
    func waitForMediaCompletion(
        using client: SyncClient,
        publishProgress: Bool = true
    ) async throws {
        while true {
            try Task.checkCancellation()
            let status = try await client.mediaSyncStatus()
            guard status.active else { return }

            if publishProgress {
                state = .syncingMedia(Self.mediaProgressMessage(status.progress))
            }
            try await Task.sleep(for: mediaPollInterval)
        }
    }

    func drainMediaCompletion(using client: SyncClient) async {
        while true {
            do {
                try await waitForMediaCompletion(using: client, publishProgress: false)
                return
            } catch is CancellationError {
                return
            } catch {
                appendLog("Media drain status failed: \(error.localizedDescription)", level: .error)
                do {
                    try await Task.sleep(for: mediaPollInterval)
                } catch {
                    return
                }
            }
        }
    }

    func registerLifecycleObservers() {
        #if os(iOS)
        let center = NotificationCenter.default
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.beginBackgroundExecutionIfNeeded()
            }
        })
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.endBackgroundExecutionIfNeeded()
            }
        })
        #endif

        if needsFullSyncFlag {
            state = .needsFullSync(SyncFullSyncRequirement(
                reason: "A full sync was requested previously and not yet completed",
                localIsEmpty: false
            ))
        }
    }

    func beginBackgroundExecutionIfNeeded() {
        #if os(iOS)
        guard activeTask != nil, backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "AmgiSync") { [weak self] in
            // System forced expiration — end task and let cancel() handle state.
            Task { @MainActor in
                self?.cancel()
                self?.endBackgroundExecutionIfNeeded()
            }
        }
        appendLog("Background sync started — extending execution window")
        #endif
    }

    func endBackgroundExecutionIfNeeded() {
        #if os(iOS)
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
        appendLog("Foreground resumed — released BG task")
        #endif
    }
}

private enum SyncCoordinatorKey: DependencyKey {
    static let liveValue = SyncCoordinator()
    static let testValue = SyncCoordinator()
}

extension DependencyValues {
    package var syncCoordinator: SyncCoordinator {
        get { self[SyncCoordinatorKey.self] }
        set { self[SyncCoordinatorKey.self] = newValue }
    }
}

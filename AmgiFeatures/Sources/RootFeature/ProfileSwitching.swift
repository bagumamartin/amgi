import AmgiAppCore
import AmgiAppShared
import AmgiReviewCore
import AnkiBackend
import BrowseFeature
import Dependencies
import Foundation
import SyncFeature
import os

/// Creates the profile's directory layout if needed and opens its collection
/// on `backend`. Shared by the bootstrap and in-app profile switching.
@MainActor
func openCollection(for profileID: String, backend: AnkiBackend) throws {
    try AppSignpost.measure("OpenCollection") {
        let ankiDir = AccountStore.profileDirectory(for: profileID)
        try FileManager.default.createDirectory(at: ankiDir, withIntermediateDirectories: true)
        let mediaPath = ankiDir.appendingPathComponent("media").path
        try FileManager.default.createDirectory(atPath: mediaPath, withIntermediateDirectories: true)
        try backend.openCollection(
            collectionPath: ankiDir.appendingPathComponent("collection.anki2").path,
            mediaFolderPath: mediaPath,
            mediaDbPath: ankiDir.appendingPathComponent("media.db").path
        )
    }
}

/// In-app profile switch: cancels any running sync, swaps the open collection
/// on the shared backend, flips the scoping anchor (sync prefs + keychain
/// identity), resets sync state, and refreshes widgets. The root view re-ids
/// on the runtime selection epoch, so the whole UI rebuilds against the new collection.
@MainActor
private var profileSwitchInProgress = false

@MainActor
func switchProfile(to account: AmgiAccount) async {
    let accountStore = AccountStore.shared
    guard account.id != accountStore.selectedID, !profileSwitchInProgress else { return }
    profileSwitchInProgress = true
    defer { profileSwitchInProgress = false }
    let previous = accountStore.current

    @Dependency(\.ankiBackend) var backend
    @Dependency(\.collectionStore) var store
    @Dependency(\.syncCoordinator) var syncCoordinator

    guard syncCoordinator.beginCollectionLifecycle() else { return }
    await ReviewSessionActivity.shared.drain()
    defer { ReviewSessionActivity.shared.endDrain() }
    await syncCoordinator.cancelAndWait()
    await WidgetRefreshCoordinator.shared.cancelAndWait()
    ReviewSessionContext.shared.clear()
    try? backend.closeCollection()
    accountStore.select(account)
    do {
        try openCollection(for: account.id, backend: backend)
    } catch {
        // Roll back rather than leave the app with no open collection.
        accountStore.select(previous)
        do {
            try openCollection(for: previous.id, backend: backend)
        } catch let rollbackError {
            // Both the switch and the rollback failed, so nothing is open.
            // Discarding this left every screen failing its fetch with no
            // explanation — the app looked empty rather than broken.
            Log.decks.error("Profile switch and rollback both failed: \(rollbackError)")
            accountStore.switchFailure = """
                Couldn't open either profile's collection. Quit and reopen \
                Amgi. If that doesn't help, reset the collection from \
                Settings > Maintenance.
                """
        }
        syncCoordinator.endCollectionLifecycle()
        return
    }
    syncCoordinator.resetForProfileSwitch()
    SemanticNoteIndex.shared.resetForProfileSwitch()
    store.invalidateAll(origin: .refresh)
    WidgetSnapshotStore.removeAllSnapshots()
    await WidgetRefreshCoordinator.shared.refreshNow()
    await SystemSpotlightIndexer.shared.scheduleDeckRefresh()
    syncCoordinator.endCollectionLifecycle()
    syncCoordinator.resumeAutomaticSyncIfNeeded(reason: "Profile became active")
}

import AmgiAppCore
import AmgiAppShared
import AmgiReviewCore
import AnkiBackend
import AnkiClients
import AnkiServices
import Dependencies
import Foundation
import OSLog
import SyncFeature

/// Replaces the active profile with a `.colpkg` backup. This lifecycle belongs
/// at the composition root because the engine requires its collection lock to
/// be closed while files are replaced, unlike every merge-style importer.
@MainActor
func replaceCurrentCollection(
    with stagedPackageURL: URL,
    profileID expectedProfileID: String,
    lifecycleAlreadyHeld: Bool = false
) async throws {
    @Dependency(\.ankiBackend) var backend
    @Dependency(\.collectionStore) var collectionStore
    @Dependency(\.syncCoordinator) var syncCoordinator
    @Dependency(\.importExportService) var importExport

    guard AccountStore.shared.selectedID == expectedProfileID else {
        throw ImportReviewFailure.profileChanged
    }
    let profileID = expectedProfileID
    let profileDirectory = AccountStore.profileDirectory(for: profileID)
    let collectionPath = profileDirectory.appendingPathComponent("collection.anki2").path
    let mediaFolderPath = profileDirectory.appendingPathComponent("media", isDirectory: true).path
    let mediaDatabasePath = profileDirectory.appendingPathComponent("media.db").path

    let recoveryDirectory = profileDirectory.appendingPathComponent("Recovery", isDirectory: true)
    try FileManager.default.createDirectory(at: recoveryDirectory, withIntermediateDirectories: true)
    let recoveryURL = recoveryDirectory
        .appendingPathComponent("Amgi-Recovery-\(UUID().uuidString).colpkg")
    var preserveRecovery = false
    defer {
        if !preserveRecovery {
            try? FileManager.default.removeItem(at: recoveryURL)
        }
    }

    if !lifecycleAlreadyHeld {
        guard syncCoordinator.beginCollectionLifecycle() else {
            throw CancellationError()
        }
    }
    defer { if !lifecycleAlreadyHeld { syncCoordinator.endCollectionLifecycle() } }
    let drainsReviewActivity = !lifecycleAlreadyHeld
    if drainsReviewActivity {
        await ReviewSessionActivity.shared.drain()
    }
    defer {
        if drainsReviewActivity {
            ReviewSessionActivity.shared.endDrain()
        }
    }
    guard AccountStore.shared.selectedID == profileID else {
        throw ImportReviewFailure.profileChanged
    }
    await syncCoordinator.cancelAndWait()
    await WidgetRefreshCoordinator.shared.cancelAndWait()

    // Desktop Anki creates a backup before replacing a collection. Do the same
    // so a malformed package or interrupted media restore can be rolled back.
    // The upstream export RPC deliberately takes the collection out of the
    // backend while it writes the package, so it is already closed when this
    // returns; calling closeCollection again would fail with CollectionNotOpen.
    do {
        try await backendOffload {
            try importExport.exportCollectionPackage(recoveryURL.path, true)
        }
    } catch {
        // Export takes ownership before writing. Normalize either possible
        // outcome (still open on an early failure, already closed otherwise)
        // before returning the original error to the review screen.
        try? await backendOffload { try backend.closeCollection() }
        try? await reopenAfterReplacement(
            backend: backend,
            profileID: profileID,
            collectionPath: collectionPath,
            mediaFolderPath: mediaFolderPath,
            mediaDatabasePath: mediaDatabasePath
        )
        throw error
    }

    guard AccountStore.shared.selectedID == profileID else {
        try? await backendOffload { try backend.closeCollection() }
        try? await reopenAfterReplacement(
            backend: backend,
            profileID: profileID,
            collectionPath: collectionPath,
            mediaFolderPath: mediaFolderPath,
            mediaDatabasePath: mediaDatabasePath
        )
        throw ImportReviewFailure.profileChanged
    }

    do {
        try await importExport.importCollectionPackage(
            collectionPath,
            stagedPackageURL.path,
            mediaFolderPath,
            mediaDatabasePath
        )
    } catch {
        do {
            try await importExport.importCollectionPackage(
                collectionPath,
                recoveryURL.path,
                mediaFolderPath,
                mediaDatabasePath
            )
        } catch let recoveryError {
            try? await reopenAfterReplacement(
                backend: backend,
                profileID: profileID,
                collectionPath: collectionPath,
                mediaFolderPath: mediaFolderPath,
                mediaDatabasePath: mediaDatabasePath
            )
            preserveRecovery = true
            throw ImportCollectionReplacementError.recoveryFailed(
                importError: error.localizedDescription,
                recoveryError: recoveryError.localizedDescription,
                recoveryPath: recoveryURL.path
            )
        }
        preserveRecovery = true
        try await reopenAfterReplacement(
            backend: backend,
            profileID: profileID,
            collectionPath: collectionPath,
            mediaFolderPath: mediaFolderPath,
            mediaDatabasePath: mediaDatabasePath
        )
        preserveRecovery = false
        syncCoordinator.resetForProfileSwitch()
        throw error
    }

    // Keep the verified recovery package until the replacement collection has
    // actually reopened. If startup cannot reopen the restored database, the
    // user must still have a durable local copy to recover from.
    preserveRecovery = true
    try await reopenAfterReplacement(
        backend: backend,
        profileID: profileID,
        collectionPath: collectionPath,
        mediaFolderPath: mediaFolderPath,
        mediaDatabasePath: mediaDatabasePath
    )
    preserveRecovery = false
    syncCoordinator.resetForProfileSwitch()
    collectionStore.invalidateAll(origin: .localUser)
    WidgetSnapshotStore.removeAllSnapshots()
    await WidgetRefreshCoordinator.shared.refreshNow()

    // Restore the reader library carried in the same package, now that the
    // collection it belongs to is live again. Best-effort: a package without
    // a reader payload (an older backup, or a desktop-Anki one) is normal and
    // must not fail an otherwise-successful restore.
    await restoreReaderLibraryIfPresent(
        from: stagedPackageURL,
        profileID: profileID
    )
}

/// Re-imports the books from a backup's `ijuka/epub/` entries.
///
/// Additive and non-destructive: books already in the library are left alone
/// (they have their own extraction), and each restored file goes through the
/// same validated import pipeline as a user-picked EPUB, so a truncated or
/// mismatched entry cannot corrupt the index.
@MainActor
private func restoreReaderLibraryIfPresent(
    from packageURL: URL,
    profileID: String
) async {
    @Dependency(\.epubLibraryClient) var epubLibrary
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("AmgiReaderRestore-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: scratch) }

    do {
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        try ReaderBackupBundle.extractReaderLibrary(
            fromPackageAt: packageURL,
            to: scratch
        )
        let sources = try FileManager.default
            .contentsOfDirectory(
                at: scratch,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            .filter { $0.pathExtension.lowercased() == "epub" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        for source in sources {
            let accessed = source.startAccessingSecurityScopedResource()
            defer { if accessed { source.stopAccessingSecurityScopedResource() } }
            // Import is idempotent: the book ID is a content hash, so a book
            // already in the library is re-validated and replaced in place
            // rather than duplicated.
            _ = try? await epubLibrary.importEPUB(source)
        }
    } catch {
        // The collection restored fine; a missing reader payload is expected
        // for any backup taken before reader backups existed.
        Log.reader.error("Reader library restore skipped: \(error.localizedDescription)")
    }
}

private func reopenCollection(
    backend: AnkiBackend,
    collectionPath: String,
    mediaFolderPath: String,
    mediaDatabasePath: String
) async throws {
    try await backendOffload {
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: mediaFolderPath, isDirectory: true),
            withIntermediateDirectories: true
        )
        try backend.openCollection(
            collectionPath: collectionPath,
            mediaFolderPath: mediaFolderPath,
            mediaDbPath: mediaDatabasePath
        )
    }
}

@MainActor
private func reopenAfterReplacement(
    backend: AnkiBackend,
    profileID: String,
    collectionPath: String,
    mediaFolderPath: String,
    mediaDatabasePath: String
) async throws {
    do {
        try await reopenCollection(
            backend: backend,
            collectionPath: collectionPath,
            mediaFolderPath: mediaFolderPath,
            mediaDatabasePath: mediaDatabasePath
        )
    } catch {
        // Keep the app recoverable if the restored collection is temporarily
        // unavailable (for example, an external helper still owns the lock).
        // CollectionLaunchState will show its native busy screen and retry.
        CollectionLaunchState.shared.configure(
            backend: backend,
            profileID: profileID,
            error: error.localizedDescription
        )
        throw error
    }
}

private enum ImportCollectionReplacementError: Error, LocalizedError {
    case recoveryFailed(importError: String, recoveryError: String, recoveryPath: String)

    var errorDescription: String? {
        switch self {
        case .recoveryFailed(let importError, let recoveryError, let recoveryPath):
            return """
                The collection backup could not be imported (\(importError)). \
                Ijuka also could not restore the automatic recovery backup (\(recoveryError)). \
                The recovery copy was kept at \(recoveryPath). Quit and reopen Ijuka, then restore that copy.
                """
        }
    }
}

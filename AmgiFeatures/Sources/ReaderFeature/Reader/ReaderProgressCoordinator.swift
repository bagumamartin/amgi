import AmgiAppCore
import OSLog
import AmgiReader
import AnkiClients
import Dependencies
import Foundation

/// Bridges the local `ReaderProgressStore` (UserDefaults) and the
/// `ReaderProgressSyncClient` (per-profile iCloud Drive manifest). The library
/// and chapter views talk to this single API so save/load semantics stay
/// consistent — last-write-wins per book using `updatedAt`.
///
/// Book data stays out of the Anki collection entirely: saving a position
/// never marks the collection mutated and never triggers an Anki sync.
/// Positions reach other devices through iCloud; only cards made from books
/// travel through AnkiWeb.
///
/// All sync writes are async and fire-and-forget. A failed network round
/// trip never blocks the local save, and a failed merge never breaks the
/// reader UI.
struct ReaderProgressCoordinator: Sendable {
    let store: ReaderProgressStore

    @Dependency(\.readerProgressSyncClient) private var sync

    /// The default store is profile-scoped. Progress used to live under a
    /// single global `amgi.reader.progress` namespace, so a profile switch
    /// showed the previous profile's reading positions. Scoping the key
    /// namespace by the active profile (and falling back to the legacy
    /// namespace on read) fixes that without changing any call site —
    /// every construction in the app goes through this default argument.
    init(store: ReaderProgressStore = ReaderProgressStore.forCurrentProfile()) {
        self.store = store
    }

    /// Returns the resolved progress for a book, preferring the more
    /// recent of local vs. iCloud. If iCloud holds the newer payload, it's
    /// also written back locally so subsequent reads don't round-trip.
    func resolved(bookID: String) async -> ReaderSavedProgress? {
        let local = store.load(bookID: bookID)
        let cloud = (try? await sync.loadManifest()?.entries[bookID]) ?? nil

        let winner: ReaderSavedProgress?
        switch (local, cloud) {
        case let (l?, c?): winner = c.updatedAt > l.updatedAt ? c : l
        case let (l?, nil): winner = l
        case let (nil, c?): winner = c
        default: winner = nil
        }

        if let winner, winner != local {
            store.save(bookID: bookID, payload: winner)
        }
        return winner
    }

    /// Saves locally first, then mirrors to the iCloud Drive manifest in
    /// the background. Both sides receive the same payload so collisions
    /// resolve identically on every device.
    func save(
        bookID: String,
        chapterID: Int64,
        progress: Double,
        anchor: ReaderSourceAnchor? = nil
    ) {
        let now = Date.now
        let payload = ReaderSavedProgress(
            chapterID: chapterID,
            progress: min(max(progress, 0), 1),
            updatedAt: now,
            anchor: anchor
        )
        store.save(bookID: bookID, payload: payload)
        Task.detached(priority: .background) {
            do {
                _ = try await sync.pushBookProgress(bookID, payload)
                store.clearPendingPush(bookID: bookID)
            } catch {
                // Fire-and-forget with `try?` meant that backgrounding or
                // force-quitting right after closing a chapter dropped the
                // cloud-side write with no retry and no log, so
                // cross-device progress silently diverged. The local write
                // above always lands; mark the push pending so the next
                // launch can flush it.
                store.markPendingPush(bookID: bookID)
                Log.reader.error("Reading-progress push failed for \(bookID, privacy: .public): \(error)")
            }
        }
    }

    /// Re-pushes any progress whose cloud-side write never landed.
    /// Called at reader-library appear.
    func flushPendingPushes() async {
        for bookID in store.pendingPushBookIDs() {
            guard let payload = store.load(bookID: bookID) else {
                store.clearPendingPush(bookID: bookID)
                continue
            }
            do {
                _ = try await sync.pushBookProgress(bookID, payload)
                store.clearPendingPush(bookID: bookID)
            } catch {
                Log.reader.error("Deferred progress push still failing for \(bookID, privacy: .public): \(error)")
            }
        }
    }
}

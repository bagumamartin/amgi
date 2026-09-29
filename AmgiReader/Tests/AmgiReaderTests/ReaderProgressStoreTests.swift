import Foundation
import Testing
@testable import AmgiReader

/// Reading progress is per-profile state. The regression these lock down: a
/// single global `amgi.reader.progress` namespace meant switching profiles
/// showed the previous profile's position in every book.
@Suite("Reader progress scoping")
struct ReaderProgressStoreTests {
    private func makeDefaults(_ name: String) -> UserDefaults {
        let suite = "amgi.tests.\(name).\(UUID().uuidString)"
        return UserDefaults(suiteName: suite) ?? .standard
    }

    private func progress(_ value: Double) -> ReaderSavedProgress {
        ReaderSavedProgress(chapterID: 3, progress: value, updatedAt: .now)
    }

    @Test("two profiles do not see each other's positions")
    func profilesAreIsolated() {
        let defaults = makeDefaults("isolation")
        let a = ReaderProgressStore.scoped(to: "alice", userDefaults: defaults)
        let b = ReaderProgressStore.scoped(to: "bob", userDefaults: defaults)

        a.save(bookID: "book-1", payload: progress(0.25))
        b.save(bookID: "book-1", payload: progress(0.75))

        #expect(a.load(bookID: "book-1")?.progress == 0.25)
        #expect(b.load(bookID: "book-1")?.progress == 0.75)
    }

    @Test("reopening the same profile keeps its positions")
    func sameProfileIsStable() {
        let defaults = makeDefaults("stable")
        ReaderProgressStore.scoped(to: "alice", userDefaults: defaults)
            .save(bookID: "book-1", payload: progress(0.4))
        #expect(
            ReaderProgressStore.scoped(to: "alice", userDefaults: defaults)
                .load(bookID: "book-1")?.progress == 0.4
        )
    }

    @Test("the pre-profile value is adopted once, by the default profile only")
    func legacyValueMigratesToDefaultOnly() {
        let defaults = makeDefaults("migration")
        // The pre-profiles namespace, written by an older build.
        let legacy = ReaderProgressStore(
            userDefaults: defaults,
            keyNamespace: ReaderProgressStore.legacyKeyNamespace
        )
        legacy.save(bookID: "book-1", payload: progress(0.5))

        let defaultProfile = ReaderProgressStore.scoped(to: "default", userDefaults: defaults)
        #expect(defaultProfile.load(bookID: "book-1")?.progress == 0.5)

        // A named profile must not inherit it: the legacy value belonged to
        // whichever profile existed when it was written, and assuming that was
        // "default" would silently hand one user's position to another.
        let named = ReaderProgressStore.scoped(to: "alice", userDefaults: defaults)
        #expect(named.load(bookID: "book-1") == nil)
    }

    @Test("migration writes back so the fallback stops firing")
    func migrationWritesBack() {
        let defaults = makeDefaults("writeback")
        let legacy = ReaderProgressStore(
            userDefaults: defaults,
            keyNamespace: ReaderProgressStore.legacyKeyNamespace
        )
        legacy.save(bookID: "book-1", payload: progress(0.5))

        let scoped = ReaderProgressStore.scoped(to: "default", userDefaults: defaults)
        _ = scoped.load(bookID: "book-1")

        // Deleting the legacy key must not change what the scoped store reads.
        defaults.removeObject(
            forKey: "\(ReaderProgressStore.legacyKeyNamespace).book-1"
        )
        #expect(scoped.load(bookID: "book-1")?.progress == 0.5)
    }

    @Test("a profile id with filesystem-hostile characters is sanitised")
    func profileIDSanitised() {
        let defaults = makeDefaults("sanitise")
        // A profile slug is filesystem-safe, but a value reaching the key
        // namespace from elsewhere must not be able to inject a separator.
        let hostile = ReaderProgressStore.scoped(to: "a/../b c", userDefaults: defaults)
        let safe = ReaderProgressStore.scoped(to: "a_b_c", userDefaults: defaults)
        #expect(hostile.load(bookID: "book-1") == nil)
        #expect(safe.load(bookID: "book-1") == nil)
    }

    @Test("an empty profile id falls back to the default namespace")
    func emptyProfileUsesDefault() {
        let defaults = makeDefaults("empty")
        let empty = ReaderProgressStore.scoped(to: "", userDefaults: defaults)
        empty.save(bookID: "book-1", payload: progress(0.9))
        #expect(
            ReaderProgressStore.scoped(to: "default", userDefaults: defaults)
                .load(bookID: "book-1")?.progress == 0.9
        )
    }

    @Test("pending pushes are scoped with the positions they belong to")
    func pendingPushesAreScoped() {
        let defaults = makeDefaults("pending")
        let a = ReaderProgressStore.scoped(to: "alice", userDefaults: defaults)
        let b = ReaderProgressStore.scoped(to: "bob", userDefaults: defaults)
        a.markPendingPush(bookID: "book-1")
        #expect(a.pendingPushBookIDs() == ["book-1"])
        // Bob has nothing to retry: Alice's unflushed push is not his.
        #expect(b.pendingPushBookIDs().isEmpty)
    }
}

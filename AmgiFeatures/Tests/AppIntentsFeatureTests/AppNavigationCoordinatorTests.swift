import AmgiAppCore
import AmgiAppShared
import Foundation
import Testing
@testable import AppIntentsFeature

@Suite("App navigation coordinator")
@MainActor
struct AppNavigationCoordinatorTests {
    @Test("round-trips a profile-scoped request")
    func roundTrip() throws {
        let suite = Self.makeDefaults()
        defer { suite.removePersistentDomain(forName: Self.suiteName) }
        let coordinator = AppNavigationCoordinator(defaults: suite, storageKey: "queue")
        let profile = AccountStore.shared.selectedContext

        coordinator.submit(.openNote(noteID: 42), profile: profile)
        let request = try #require(coordinator.consume())

        #expect(request.route == .openNote(noteID: 42))
        #expect(request.profile == profile)
        #expect(coordinator.pendingCount == 0)
    }

    @Test("does not persist the runtime selection epoch")
    func doesNotPersistSelectionEpoch() throws {
        let request = AppNavigationRequest(
            profile: AccountStore.shared.selectedContext,
            route: .presentSync
        )

        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(AppNavigationRequest.self, from: data)

        #expect(decoded.profile.id == request.profile.id)
        #expect(decoded.profile.selectionID != request.profile.selectionID)
    }

    @Test("rejects a request from a stale profile activation")
    func rejectsStaleProfile() throws {
        let suite = Self.makeDefaults()
        defer { suite.removePersistentDomain(forName: Self.suiteName) }
        let coordinator = AppNavigationCoordinator(defaults: suite, storageKey: "queue")
        let stale = ProfileContext(
            id: AccountStore.shared.selectedID,
            displayName: AccountStore.shared.current.displayName,
            selectionID: UUID()
        )

        coordinator.submit(.review(deckID: 7), profile: stale)

        #expect(coordinator.consume() == nil)
        #expect(coordinator.pendingCount == 0)
    }

    @Test("skips stale requests without stranding the current one")
    func skipsStaleRequest() throws {
        let suite = Self.makeDefaults()
        defer { suite.removePersistentDomain(forName: Self.suiteName) }
        let coordinator = AppNavigationCoordinator(defaults: suite, storageKey: "queue")
        let current = AccountStore.shared.selectedContext
        let stale = ProfileContext(
            id: current.id,
            displayName: current.displayName,
            selectionID: UUID()
        )

        coordinator.submit(.presentSync, profile: stale)
        coordinator.submit(.openNote(noteID: 9), profile: current)
        let request = try #require(coordinator.consume())

        #expect(request.route == .openNote(noteID: 9))
        #expect(coordinator.pendingCount == 0)
    }

    @Test("expires parked requests")
    func expiresRequests() throws {
        let suite = Self.makeDefaults()
        defer { suite.removePersistentDomain(forName: Self.suiteName) }
        let coordinator = AppNavigationCoordinator(defaults: suite, storageKey: "queue")
        let request = AppNavigationRequest(
            createdAt: .distantPast,
            expiresAt: .distantPast.addingTimeInterval(-1),
            profile: AccountStore.shared.selectedContext,
            route: .presentSync
        )
        coordinator.discardPending()
        suite.set(
            try JSONEncoder().encode([request]),
            forKey: "queue"
        )
        let reloaded = AppNavigationCoordinator(defaults: suite, storageKey: "queue")

        #expect(reloaded.pendingCount == 0)
        #expect(reloaded.consume() == nil)
    }

    private static let suiteName = "AppNavigationCoordinatorTests.\(UUID().uuidString)"

    private static func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: Self.suiteName)!
    }
}

@Suite("Scoped entity identifiers")
struct ScopedEntityIdentifierTests {
    @Test("round-trips every entity kind")
    func roundTrip() throws {
        for kind in [ScopedEntityIdentifier.Kind.deck, .note, .notetype] {
            let raw = ScopedEntityIdentifier.make(profileID: "personal", kind: kind, localID: 42)
            let value = try #require(ScopedEntityIdentifier.parse(raw))
            #expect(value.profileID == "personal")
            #expect(value.kind == kind)
            #expect(value.localID == 42)
        }
    }

    @Test("rejects legacy collection-local identifiers")
    func rejectsLegacy() {
        #expect(ScopedEntityIdentifier.parse("42") == nil)
    }

    @Test("keeps generation-qualified profile scopes opaque")
    func parsesGenerationQualifiedScope() throws {
        let raw = ScopedEntityIdentifier.make(
            profileID: "work~g1",
            kind: .deck,
            localID: 42
        )
        let value = try #require(ScopedEntityIdentifier.parse(raw))
        #expect(value.profileID == "work~g1")
        #expect(value.localID == 42)
    }
}

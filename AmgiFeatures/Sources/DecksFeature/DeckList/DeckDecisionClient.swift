import AmgiAppCore
import AnkiBackend
import AnkiClients
import AnkiKit
import AnkiProtoBridge
import Dependencies
import Foundation

/// Collection config carries both reminder choices and pause provenance through
/// normal sync. Every edit patches a fresh value while holding lifecycle access;
/// a missing/conflicting pause record always falls back to choosing cards.
struct DeckDecisionMetadata: Codable, Equatable, Sendable {
    struct Pause: Codable, Equatable, Sendable {
        enum Status: String, Codable, Sendable { case pending, confirmed, resuming }
        var cardIDs: [Int64]
        var status: Status
    }
    struct Entry: Codable, Equatable, Sendable {
        var observedIssue: String? = nil
        var observedSince: Date? = nil
        var suppressedUntil: [String: Date] = [:]
        var pause: Pause? = nil
    }
    var entries: [String: Entry] = [:]

    func isSuppressed(id: Int64, issue: String, now: Date) -> Bool {
        (entries[String(id)]?.suppressedUntil[issue] ?? .distantPast) > now
    }
    func pastGrace(id: Int64, issue: String, now: Date) -> Bool {
        guard let entry = entries[String(id)], entry.observedIssue == issue,
              let since = entry.observedSince else { return false }
        return now.timeIntervalSince(since) >= 7 * 86_400
    }
    func canResume(id: Int64) -> Bool { entries[String(id)]?.pause?.status == .confirmed }

    mutating func observe(_ observations: [Int64: String], existingIDs: Set<Int64>, now: Date) {
        entries = entries.filter { existingIDs.contains(Int64($0.key) ?? 0) }
        for (id, issue) in observations {
            let key = String(id)
            var entry = entries[key] ?? Entry()
            if issue == "unused" || issue == "empty" {
                if entry.observedIssue != issue {
                    entry.observedIssue = issue
                    entry.observedSince = now
                }
            } else {
                entry.observedIssue = nil
                entry.observedSince = nil
            }
            entry.suppressedUntil = entry.suppressedUntil.filter { $0.value > now }
            if entry != Entry() { entries[key] = entry } else { entries.removeValue(forKey: key) }
        }
    }
}

struct DeckDecisionScope: Equatable, Sendable {
    let mediaPath: String
    let activationID: UUID
}

struct DeckDecisionFailure: LocalizedError {
    let message: String
    var collectionChanged = false
    var errorDescription: String? { message }
}

/// Synchronous operations are injected into the coordinator for failure-path
/// tests. Live calls run together off the main actor under the backend lock.
struct DeckDecisionOperations {
    var target: (DeckID) throws -> DeckTreeNode
    var search: (String) throws -> [CardID]
    var save: (DeckDecisionMetadata) throws -> Void
    var suspend: ([CardID]) throws -> Void
    var restore: ([CardID]) throws -> Void
    var delete: (DeckID) throws -> Void
}

enum DeckDecisionMutation: Sendable {
    case observe([Int64: String], existingIDs: Set<Int64>, now: Date)
    case suppress(DeckID, issue: String, until: Date)
    case pause(DeckID)
    case resume(DeckID)
    case delete(DeckID, expectedName: String, expectedCardCount: Int, expectedDescendantIDs: [DeckID] = [])
}

struct DeckDecisionResult: Sendable {
    let metadata: DeckDecisionMetadata
    var collectionChanged = false
    var metadataChanged = false
    var chooseCards = false
}

enum DeckDecisionCoordinator {
    static func perform(_ mutation: DeckDecisionMutation, metadata original: DeckDecisionMetadata,
                        using operations: DeckDecisionOperations) throws -> DeckDecisionResult {
        var metadata = original
        var changed = false
        switch mutation {
        case .observe(let observations, let existingIDs, let now):
            metadata.observe(observations, existingIDs: existingIDs, now: now)
        case .suppress(let id, let issue, let until):
            _ = try operations.target(id)
            var entry = metadata.entries[String(id.rawValue)] ?? .init()
            entry.suppressedUntil[issue] = until
            metadata.entries[String(id.rawValue)] = entry
        case .pause(let id):
            let deck = try mutableTarget(id, operations: operations)
            let cards = try operations.search("\(cardScope(deck)) -is:suspended")
            guard !cards.isEmpty else {
                throw DeckDecisionFailure(message: L10n.text("This deck has no active cards to pause."))
            }
            var entry = metadata.entries[String(id.rawValue)] ?? .init()
            // Preserve any existing confirmed provenance during a repeated
            // pause, e.g. after the user adds cards to a paused deck.
            let previous = entry.pause?.status == .confirmed ? (entry.pause?.cardIDs ?? []) : []
            entry.pause = .init(cardIDs: Array(Set(previous + cards.map(\.rawValue))).sorted(), status: .pending)
            metadata.entries[String(id.rawValue)] = entry
            try operations.save(metadata) // failure here must prevent suspension
            do { try operations.suspend(cards) } catch {
                // The pending record is intentionally retained. The caller
                // refreshes it so an old confirmed mirror cannot be reused.
                throw DeckDecisionFailure(message: error.localizedDescription, collectionChanged: true)
            }
            changed = true
            entry.pause?.status = .confirmed
            metadata.entries[String(id.rawValue)] = entry
            do { try operations.save(metadata) } catch {
                throw DeckDecisionFailure(message: L10n.text("The deck is paused, but direct Resume could not be recorded. Use Choose cards in Archived."), collectionChanged: true)
            }
        case .resume(let id):
            let deck = try mutableTarget(id, operations: operations)
            guard var entry = metadata.entries[String(id.rawValue)], let pause = entry.pause,
                  pause.status == .confirmed else {
                return DeckDecisionResult(metadata: metadata, chooseCards: true)
            }
            let suspended = Set(try operations.search("\(cardScope(deck)) is:suspended").map(\.rawValue))
            let cards = pause.cardIDs.filter { suspended.contains($0) }.map { CardID($0) }
            entry.pause?.status = .resuming
            metadata.entries[String(id.rawValue)] = entry
            try operations.save(metadata)
            if !cards.isEmpty {
                do { try operations.restore(cards) } catch {
                    throw DeckDecisionFailure(message: error.localizedDescription, collectionChanged: true)
                }
                changed = true
            }
            entry.pause = nil
            // Resume already expresses a study commitment. Give it a week
            // before asking the inactive-deck question again.
            if changed { entry.suppressedUntil["inactive"] = Date().addingTimeInterval(7 * 86_400) }
            metadata.entries[String(id.rawValue)] = entry
            do { try operations.save(metadata) } catch {
                throw DeckDecisionFailure(message: L10n.text("Cards were restored, but the Resume record could not be cleared. Review the deck in Browse."), collectionChanged: changed)
            }
        case .delete(let id, let expectedName, let expectedCount, let expectedDescendants):
            let deck = try mutableTarget(id, operations: operations)
            guard deck.fullName == expectedName, deck.cardCount == expectedCount,
                  Set(deck.flattened().map(\.id)) == Set(expectedDescendants) else {
                throw DeckDecisionFailure(message: L10n.text("The deck changed. Review it again before deleting."))
            }
            try operations.delete(id)
            changed = true
            metadata.entries.removeValue(forKey: String(id.rawValue))
            do { try operations.save(metadata) } catch {
                throw DeckDecisionFailure(message: L10n.text("The deck was deleted, but its decision record could not be cleared."), collectionChanged: true)
            }
        }
        let metadataChanged = metadata != original
        if metadataChanged {
            // Pause and Resume save their recovery stages explicitly.
            switch mutation {
            case .pause, .resume, .delete: break
            default: try operations.save(metadata)
            }
        }
        return DeckDecisionResult(metadata: metadata, collectionChanged: changed, metadataChanged: metadataChanged)
    }

    private static func mutableTarget(_ id: DeckID, operations: DeckDecisionOperations) throws -> DeckTreeNode {
        let deck = try operations.target(id)
        guard id.rawValue != 1, !deck.isFiltered, !deck.flattened().contains(where: { $0.id.rawValue == 1 }) else {
            throw DeckDecisionFailure(message: L10n.text("This action is unavailable for this deck."))
        }
        return deck
    }

    /// Names can contain Anki wildcard operators. An explicit ID list also
    /// pins the descendant scope to the tree revalidated under this lock.
    private static func cardScope(_ deck: DeckTreeNode) -> String {
        let ids = ([deck.id] + deck.flattened().map(\.id)).map(\.rawValue).sorted()
        // Anki expands `did:` to current-deck OR original-deck matches.
        // Group it before adding the suspended-card predicate.
        return "(did:" + ids.map(String.init).joined(separator: ",") + ")"
    }
}

struct DeckDecisionClient: Sendable {
    static let configKey = "amgi.deckDecisions.v1"
    var scope: @Sendable () -> DeckDecisionScope?
    var read: @Sendable (DeckDecisionScope) async throws -> DeckDecisionMetadata
    var target: @Sendable (DeckDecisionScope, DeckID) async throws -> DeckTreeNode
    var mutate: @Sendable (DeckDecisionScope, DeckDecisionMutation) async throws -> DeckDecisionResult
}

extension DeckDecisionClient: DependencyKey {
    static let liveValue: Self = {
        @Dependency(\.ankiBackend) var backend
        return live(backend: backend)
    }()

    static func live(backend: AnkiBackend) -> Self {
        Self(
            scope: {
                backend.withLifecycleAccess {
                    guard let path = backend.currentMediaFolderPath, let activation = backend.collectionActivationID else { return nil }
                    return DeckDecisionScope(mediaPath: path, activationID: activation)
                }
            },
            read: { scope in
                try await backendOffload {
                    try backend.withLifecycleAccess {
                        try Task.checkCancellation()
                        try validate(scope, backend: backend)
                        return try backend.getConfigJSONValue(for: configKey) ?? DeckDecisionMetadata()
                    }
                }
            },
            target: { scope, id in
                try await backendOffload {
                    try backend.withLifecycleAccess {
                        try Task.checkCancellation()
                        try validate(scope, backend: backend)
                        return try target(id, backend: backend)
                    }
                }
            },
            mutate: { scope, mutation in
                try await backendOffload {
                    try backend.withLifecycleAccess {
                        try Task.checkCancellation()
                        try validate(scope, backend: backend)
                        let metadata: DeckDecisionMetadata = try backend.getConfigJSONValue(for: configKey) ?? .init()
                        return try DeckDecisionCoordinator.perform(mutation, metadata: metadata, using: DeckDecisionOperations(
                            target: { try target($0, backend: backend) },
                            search: { try backend.invoke(.searchCardIds(query: $0, order: nil)) },
                            save: { try backend.setConfigJSONValue($0, for: configKey) },
                            suspend: { try backend.invoke(.suspendCards(cardIds: $0)) },
                            restore: { try backend.invoke(.restoreBuriedAndSuspendedCards(cardIds: $0)) },
                            delete: { _ = try backend.invoke(.removeDecks(deckIds: [$0])) }
                        ))
                    }
                }
            }
        )
    }

    static let testValue = Self(
        scope: { DeckDecisionScope(mediaPath: "test", activationID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!) },
        read: { _ in .init() },
        target: { _, _ in throw DeckDecisionFailure(message: "No test target") },
        mutate: { _, mutation in
            var metadata = DeckDecisionMetadata()
            if case .observe(let observations, let IDs, let now) = mutation {
                metadata.observe(observations, existingIDs: IDs, now: now)
            }
            return DeckDecisionResult(metadata: metadata)
        }
    )

    private static func validate(_ scope: DeckDecisionScope, backend: AnkiBackend) throws {
        guard backend.currentMediaFolderPath == scope.mediaPath, backend.collectionActivationID == scope.activationID else {
            throw DeckDecisionFailure(message: L10n.text("The active profile changed. Try again in the current profile."))
        }
    }
    private static func target(_ id: DeckID, backend: AnkiBackend) throws -> DeckTreeNode {
        let tree: [DeckTreeNode] = try backend.invoke(.deckTree())
        func find(_ nodes: [DeckTreeNode]) -> DeckTreeNode? {
            for node in nodes {
                if node.id == id { return node }
                if let child = find(node.children) { return child }
            }
            return nil
        }
        guard let deck = find(tree) else { throw DeckDecisionFailure(message: L10n.text("This deck no longer exists.")) }
        return deck
    }
}

extension DependencyValues {
    var deckDecisionClient: DeckDecisionClient {
        get { self[DeckDecisionClient.self] }
        set { self[DeckDecisionClient.self] = newValue }
    }
}

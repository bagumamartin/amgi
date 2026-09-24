// AmgiFeatures/Sources/WidgetFeature/WidgetConfiguration.swift
public import AppIntents
import WidgetKit
import Foundation
import AmgiAppCore

struct WidgetDeckEntity: AppEntity {
    /// Opaque, profile-qualified configuration ID. The deck's numeric ID is
    /// derived for the timeline provider and is never exposed as the
    /// persisted App Entity identifier.
    let id: String
    let name: String

    /// Numeric deck ID is derived from the opaque configuration ID. Keeping
    /// it computed means App Intents can reconstruct an entity from `id` and
    /// display name without a second persisted property.
    var deckID: Int64 {
        id.split(separator: "|").last.flatMap { Int64($0) } ?? 0
    }

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    init(id: String, deckID: Int64, name: String) {
        self.init(id: "\(id)|\(deckID)", name: name)
    }

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Deck"
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    static let defaultQuery = WidgetDeckEntityQuery()
}

struct WidgetDeckEntityQuery: EntityQuery {
    private static var currentProfileID: String? {
        AppGroup.defaults.string(forKey: AppGroup.selectedProfileScopeKey)
    }

    private static func currentSnapshots() -> [(profileID: String, snapshot: WidgetSnapshot)] {
        guard let profileID = currentProfileID else { return [] }
        return WidgetSnapshotStore.allSnapshots().compactMap { snapshot in
            guard snapshot.profileID == profileID else { return nil }
            return (profileID, snapshot)
        }
    }

    private static func entityID(profileID: String, deckID: Int64) -> String {
        "\(profileID)|\(deckID)"
    }

    private static func entity(
        profileID: String,
        snapshot: WidgetSnapshot
    ) -> WidgetDeckEntity {
        WidgetDeckEntity(
            id: entityID(profileID: profileID, deckID: snapshot.deckId),
            name: snapshot.deckName
        )
    }

    func entities(for identifiers: [String]) async throws -> [WidgetDeckEntity] {
        let requested = Set(identifiers)
        return Self.currentSnapshots().compactMap { profileID, snapshot in
            let id = Self.entityID(profileID: profileID, deckID: snapshot.deckId)
            guard requested.contains(id) else { return nil }
            return Self.entity(profileID: profileID, snapshot: snapshot)
        }
    }

    func suggestedEntities() async throws -> [WidgetDeckEntity] {
        Self.currentSnapshots().map { profileID, snapshot in
            Self.entity(profileID: profileID, snapshot: snapshot)
        }
    }

    func defaultResult() async -> WidgetDeckEntity? {
        guard let profileID = Self.currentProfileID else { return nil }
        // Prefer the "All Decks" aggregate; fall back to the first current
        // profile snapshot. Legacy unscoped IDs are intentionally not reused.
        let snapshots = Self.currentSnapshots()
        if let allDecks = snapshots.first(where: { $0.snapshot.deckId == 0 }) {
            return Self.entity(profileID: profileID, snapshot: allDecks.snapshot)
        }
        if let first = snapshots.first {
            return Self.entity(profileID: profileID, snapshot: first.snapshot)
        }
        return WidgetDeckEntity(
            id: Self.entityID(profileID: profileID, deckID: 0),
            name: "All Decks"
        )
    }
}

struct AmgiWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Choose Deck"
    static let description = IntentDescription("Select which deck to display.")

    @Parameter(title: "Deck")
    var deck: WidgetDeckEntity?
}

/// Exposes the package's widget configuration intent to the app and extension.
public struct IjukaWidgetIntentsPackage: AppIntentsPackage {}

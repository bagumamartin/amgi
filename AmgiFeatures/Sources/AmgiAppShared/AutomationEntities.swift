public import AppIntents
public import CoreSpotlight
public import CoreTransferable
public import AmgiAppCore
import AmgiCardWeb
import AnkiClients
public import AnkiKit
import Dependencies
import Foundation
import UniformTypeIdentifiers

// MARK: - Stable scoped identifiers

/// App Entity IDs are opaque to the system and persisted by Shortcuts,
/// Spotlight, and Siri. Collection-local Anki IDs therefore must never be
/// exposed directly: the profile's generation-qualified scope is part of every
/// identifier so a saved value cannot silently resolve against another
/// collection—or against a newly recreated profile with the same slug.
public enum ScopedEntityIdentifier: Sendable {
    public enum Kind: String, Sendable {
        case deck
        case note
        case notetype
    }

    public struct Value: Hashable, Sendable {
        public let profileID: String
        public let kind: Kind
        public let localID: Int64
    }

    public static func make(profileID: String, kind: Kind, localID: Int64) -> String {
        "v1.\(profileID).\(kind.rawValue).\(localID)"
    }

    public static func parse(_ rawValue: String) -> Value? {
        let parts = rawValue.split(separator: ".", maxSplits: 3).map(String.init)
        guard parts.count == 4,
              parts[0] == "v1",
              !parts[1].isEmpty,
              let kind = Kind(rawValue: parts[2]),
              let localID = Int64(parts[3])
        else { return nil }
        return Value(profileID: parts[1], kind: kind, localID: localID)
    }
}

public enum AutomationEntityError: LocalizedError, Sendable {
    case invalidEntity(String)
    case wrongProfile
    case profileChanged

    public var errorDescription: String? {
        switch self {
        case .invalidEntity(let type):
            "That \(type) is no longer available. Choose it again in Ijuka."
        case .wrongProfile:
            "That item belongs to a different Ijuka profile."
        case .profileChanged:
            "The active Ijuka profile changed. Try the action again."
        }
    }
}

// MARK: - Profile

public struct ProfileEntity: AppEntity, Hashable, Sendable, Identifiable {
    public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Profile")
    public static let defaultQuery = ProfileQuery()

    public let id: String
    public let name: String
    public let isActive: Bool

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: isActive ? "Active Profile" : "Profile",
            image: .init(systemName: isActive ? "person.crop.circle.fill" : "person.crop.circle")
        )
    }

    public init(id: String, name: String, isActive: Bool) {
        self.id = id
        self.name = name
        self.isActive = isActive
    }

    public struct ProfileQuery: EntityQuery {
        public init() {}

        @MainActor
        public func entities(for identifiers: [String]) async throws -> [ProfileEntity] {
            let store = AccountStore.shared
            return identifiers.compactMap { id in
                guard let account = store.accounts.first(where: {
                    store.scopeID(for: $0) == id
                }) else { return nil }
                return ProfileEntity(
                    id: id,
                    name: account.displayName,
                    isActive: account.id == store.selectedID
                )
            }
        }

        @MainActor
        public func suggestedEntities() async throws -> [ProfileEntity] {
            let store = AccountStore.shared
            return store.accounts.map {
                ProfileEntity(
                    id: store.scopeID(for: $0),
                    name: $0.displayName,
                    isActive: $0.id == store.selectedID
                )
            }
        }
    }
}

// MARK: - Deck

public struct DeckEntity: IndexedEntity, Hashable, Sendable, Identifiable {
    public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Deck")
    public static let defaultQuery = DeckQuery()

    public let id: String
    public let name: String
    public let profileID: String
    public let profileName: String

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(profileName)",
            image: .init(systemName: "rectangle.stack.fill")
        )
    }

    public var attributeSet: CSSearchableItemAttributeSet {
        let attributes = CSSearchableItemAttributeSet(contentType: UTType.content)
        attributes.title = name
        attributes.contentDescription = "Flashcard deck in \(profileName)"
        attributes.keywords = ["flashcards", "deck", profileName]
        return attributes
    }

    public init(id: String, name: String, profileID: String, profileName: String) {
        self.id = id
        self.name = name
        self.profileID = profileID
        self.profileName = profileName
    }

    public init?(context: ProfileContext, deckID: DeckID, name: String) {
        self.init(
            id: ScopedEntityIdentifier.make(profileID: context.id, kind: .deck, localID: deckID.rawValue),
            name: name,
            profileID: context.id,
            profileName: context.displayName
        )
    }

    public func resolvedDeckID(currentProfileID: String) throws -> DeckID {
        guard let value = ScopedEntityIdentifier.parse(id),
              value.kind == .deck
        else { throw AutomationEntityError.invalidEntity("deck") }
        guard value.profileID == profileID else { throw AutomationEntityError.invalidEntity("deck") }
        guard value.profileID == currentProfileID else { throw AutomationEntityError.wrongProfile }
        return DeckID(value.localID)
    }

    @MainActor
    public static func currentEntities() async throws -> [DeckEntity] {
        let context = AccountStore.shared.selectedContext
        @Dependency(\.deckClient) var client
        let tree = try await client.fetchTree()
        guard AccountStore.shared.selectedContext == context else {
            throw AutomationEntityError.profileChanged
        }
        return tree.flattened().compactMap {
            DeckEntity(context: context, deckID: $0.id, name: $0.name)
        }
    }

    public struct DeckQuery: EntityStringQuery {
        public init() {}

        public func entities(for identifiers: [String]) async throws -> [DeckEntity] {
            let current = try await DeckEntity.currentEntities()
            let requested = Set(identifiers)
            return current.filter { requested.contains($0.id) }
        }

        public func entities(matching string: String) async throws -> [DeckEntity] {
            let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return Array(try await suggestedEntities()) }
            return try await DeckEntity.currentEntities()
                .filter { $0.name.localizedStandardContains(query) }
                .prefix(25)
                .map { $0 }
        }

        public func suggestedEntities() async throws -> [DeckEntity] {
            Array(try await DeckEntity.currentEntities().prefix(25))
        }
    }
}

@available(iOS 27.0, macOS 27.0, *)
extension DeckEntity.DeckQuery: IndexedEntityQuery {
    /// Spotlight may ask the app to repair individual records after a
    /// journaled batch. Keep the same named index used by the proactive
    /// indexer so the repair cannot create a second searchable store.
    public func reindexEntities(
        for identifiers: [String],
        indexDescription: CSSearchableIndexDescription
    ) async throws {
        _ = indexDescription
        let searchableIndex = CSSearchableIndex(name: SystemSpotlightIndexer.defaultIndexName)
        guard AutomationPreferences.spotlightDeckNames else {
            try await searchableIndex.deleteAppEntities(identifiedBy: identifiers, ofType: DeckEntity.self)
            return
        }
        let requested = Set(identifiers)
        let entities = try await DeckEntity.currentEntities().filter { requested.contains($0.id) }
        let currentIDs = Set(entities.map(\.id))
        let staleIDs = requested.subtracting(currentIDs)
        if !staleIDs.isEmpty {
            try await searchableIndex.deleteAppEntities(
                identifiedBy: Array(staleIDs),
                ofType: DeckEntity.self
            )
        }
        guard !entities.isEmpty else { return }
        try await searchableIndex.indexAppEntities(entities)
    }

    public func reindexAllEntities(
        indexDescription: CSSearchableIndexDescription
    ) async throws {
        _ = indexDescription
        let searchableIndex = CSSearchableIndex(name: SystemSpotlightIndexer.defaultIndexName)
        guard AutomationPreferences.spotlightDeckNames else {
            try await searchableIndex.deleteAppEntities(ofType: DeckEntity.self)
            return
        }
        try await searchableIndex.deleteAppEntities(ofType: DeckEntity.self)
        let entities = try await DeckEntity.currentEntities()
        try await searchableIndex.indexAppEntities(entities)
    }
}

// MARK: - Note

public struct NoteEntity: AppEntity, Hashable, Sendable, Identifiable, Transferable {
    public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Note")
    public static let defaultQuery = NoteQuery()

    public let id: String
    public let title: String
    public let profileID: String
    public let profileName: String
    /// Snapshot of the privacy-safe value used by Transferable. It is stored
    /// rather than computed so App Intents metadata can represent the export
    /// without reading mutable UserDefaults during metadata extraction.
    private let transferText: String

    /// Title shown to system surfaces. The raw title remains available to
    /// in-app callers, while Shortcuts/Siri/Share Sheet see a neutral label
    /// unless the user explicitly opts into note-title exposure.
    public var systemDisplayTitle: String {
        AutomationPreferences.exposesNoteTitles ? title : "Private note"
    }

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(systemDisplayTitle)",
            subtitle: "\(profileName)",
            image: .init(systemName: "note.text")
        )
    }

    public init(id: String, title: String, profileID: String, profileName: String) {
        self.id = id
        self.title = title
        self.profileID = profileID
        self.profileName = profileName
        self.transferText = AutomationPreferences.exposesNoteTitles ? title : "Private note"
    }

    public func systemSafeEntity() -> NoteEntity {
        NoteEntity(
            id: id,
            title: systemDisplayTitle,
            profileID: profileID,
            profileName: profileName
        )
    }

    public init?(context: ProfileContext, note: NoteRecord) {
        let title = CardText.plainText(note.sfld)
        guard !title.isEmpty else { return nil }
        self.init(
            id: ScopedEntityIdentifier.make(profileID: context.id, kind: .note, localID: note.id.rawValue),
            title: title,
            profileID: context.id,
            profileName: context.displayName
        )
    }

    public func resolvedNoteID(currentProfileID: String) throws -> NoteID {
        guard let value = ScopedEntityIdentifier.parse(id), value.kind == .note else {
            throw AutomationEntityError.invalidEntity("note")
        }
        guard value.profileID == profileID else { throw AutomationEntityError.invalidEntity("note") }
        guard value.profileID == currentProfileID else { throw AutomationEntityError.wrongProfile }
        return NoteID(value.localID)
    }

    public static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(exporting: \.transferText)
    }

    @MainActor
    public static func search(_ query: String, limit: Int = 25) async throws -> [NoteEntity] {
        guard AutomationPreferences.exposesNoteTitles else { return [] }
        let context = AccountStore.shared.selectedContext
        @Dependency(\.noteClient) var client
        let records = try await client.search(query, max(1, limit))
        guard AccountStore.shared.selectedContext == context else {
            throw AutomationEntityError.profileChanged
        }
        return records.prefix(max(1, limit)).compactMap {
            NoteEntity(context: context, note: $0)
        }
    }

    @MainActor
    public static func currentEntities(for identifiers: [String]) async throws -> [NoteEntity] {
        let context = AccountStore.shared.selectedContext
        @Dependency(\.noteClient) var client
        var result: [NoteEntity] = []
        for identifier in identifiers {
            guard let value = ScopedEntityIdentifier.parse(identifier),
                  value.kind == .note,
                  value.profileID == context.id,
                  let record = try await client.fetch(NoteID(value.localID))
            else { continue }
            guard AccountStore.shared.selectedContext == context else {
                throw AutomationEntityError.profileChanged
            }
            if let entity = NoteEntity(context: context, note: record) {
                result.append(entity.systemSafeEntity())
            }
        }
        return result
    }

    public struct NoteQuery: EntityStringQuery {
        public init() {}

        public func entities(for identifiers: [String]) async throws -> [NoteEntity] {
            try await NoteEntity.currentEntities(for: identifiers)
        }

        public func entities(matching string: String) async throws -> [NoteEntity] {
            guard AutomationPreferences.exposesNoteTitles else { return [] }
            return try await NoteEntity.search(string)
        }

        public func suggestedEntities() async throws -> [NoteEntity] {
            []
        }
    }
}

// MARK: - Notetype

public struct NotetypeEntity: AppEntity, Hashable, Sendable, Identifiable {
    public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Note Type")
    public static let defaultQuery = NotetypeQuery()

    public let id: String
    public let name: String
    public let profileID: String
    public let profileName: String

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(profileName)",
            image: .init(systemName: "square.stack.3d.up.fill")
        )
    }

    public init(id: String, name: String, profileID: String, profileName: String) {
        self.id = id
        self.name = name
        self.profileID = profileID
        self.profileName = profileName
    }

    public init?(context: ProfileContext, notetype: NotetypeNameId) {
        self.init(
            id: ScopedEntityIdentifier.make(
                profileID: context.id,
                kind: .notetype,
                localID: notetype.id.rawValue
            ),
            name: notetype.name,
            profileID: context.id,
            profileName: context.displayName
        )
    }

    public func resolvedNotetypeID(currentProfileID: String) throws -> NotetypeID {
        guard let value = ScopedEntityIdentifier.parse(id), value.kind == .notetype else {
            throw AutomationEntityError.invalidEntity("note type")
        }
        guard value.profileID == profileID else {
            throw AutomationEntityError.invalidEntity("note type")
        }
        guard value.profileID == currentProfileID else { throw AutomationEntityError.wrongProfile }
        return NotetypeID(value.localID)
    }

    @MainActor
    public static func currentEntities() async throws -> [NotetypeEntity] {
        let context = AccountStore.shared.selectedContext
        @Dependency(\.notetypesClient) var client
        let values = try await client.listAll()
        guard AccountStore.shared.selectedContext == context else {
            throw AutomationEntityError.profileChanged
        }
        return values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .compactMap { NotetypeEntity(context: context, notetype: $0) }
    }

    public struct NotetypeQuery: EntityStringQuery {
        public init() {}

        public func entities(for identifiers: [String]) async throws -> [NotetypeEntity] {
            let current = try await NotetypeEntity.currentEntities()
            let requested = Set(identifiers)
            return current.filter { requested.contains($0.id) }
        }

        public func entities(matching string: String) async throws -> [NotetypeEntity] {
            let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return Array(try await suggestedEntities()) }
            return try await NotetypeEntity.currentEntities()
                .filter { $0.name.localizedStandardContains(query) }
                .prefix(25)
                .map { $0 }
        }

        public func suggestedEntities() async throws -> [NotetypeEntity] {
            Array(try await NotetypeEntity.currentEntities().prefix(25))
        }
    }
}

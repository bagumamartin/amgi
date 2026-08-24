import AnkiClients
import AppIntents
import Foundation

/// Deck as an intent parameter — type-ahead search plus a suggested
/// list, both served live from the engine.
struct DeckEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Deck"
    static let defaultQuery = DeckQuery()

    var id: String
    var name: String

    var displayRepresentation: DisplayRepresentation {
        .init(title: "\(name)", image: .init(systemName: "rectangle.stack"))
    }

    struct DeckQuery: EntityStringQuery {
        func entities(for identifiers: [String]) async throws -> [DeckEntity] {
            let all = await allDecks()
            return identifiers.compactMap { key in all.first { $0.id == key } }
        }

        func entities(matching string: String) async throws -> [DeckEntity] {
            let lowered = string.lowercased()
            return Array(
                await allDecks()
                    .filter { $0.name.lowercased().contains(lowered) }
                    .prefix(25)
            )
        }

        func suggestedEntities() async throws -> [DeckEntity] {
            Array(await allDecks().prefix(25))
        }

        private func allDecks() async -> [DeckEntity] {
            let tree = (try? await DeckClient.liveValue.fetchTree()) ?? []
            return tree.flatMap { [$0.asDeckInfo] + $0.flattened() }
                .map { DeckEntity(id: String($0.id.rawValue), name: $0.name) }
        }
    }
}

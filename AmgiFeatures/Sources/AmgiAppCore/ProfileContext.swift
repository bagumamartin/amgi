public import Foundation

/// Immutable identity for one activation of a collection profile.
///
/// The stable `id` is a generation-qualified system scope (for example,
/// `default` or `work~g1`) and is safe to persist inside App Entity
/// identifiers and Spotlight records. `selectionID` changes whenever the
/// active profile changes and is intentionally not persisted: it is an
/// in-process fence for multi-step intents, model requests, and UI routes.
public struct ProfileContext: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let displayName: String
    public let selectionID: UUID

    public init(id: String, displayName: String, selectionID: UUID) {
        self.id = id
        self.displayName = displayName
        self.selectionID = selectionID
    }

    /// True while the same activation of this profile remains active.
    public func isCurrent(_ current: ProfileContext) -> Bool {
        id == current.id && selectionID == current.selectionID
    }
}

public extension AccountStore {
    @MainActor var selectedContext: ProfileContext {
        let account = current
        return ProfileContext(
            id: scopeID(for: account),
            displayName: account.displayName,
            selectionID: selectionID
        )
    }
}

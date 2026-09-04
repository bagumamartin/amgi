/// Host-registered deck-icon resolution. Browse cannot import DecksFeature
/// (Decks → Browse), so Library's `DeckIconOverrides` is wired here from
/// RootFeature bootstrap. Nil providers leave the tree without icons.
@MainActor
public enum DeckIconLookup {
    public static var refresh: (@MainActor () async -> Void)?
    public static var initialIcon: (@MainActor (_ deckId: Int64, _ name: String) -> String?)?
    public static var resolvedIcon: (@MainActor (_ deckId: Int64, _ name: String, _ fullName: String) async -> String?)?
}

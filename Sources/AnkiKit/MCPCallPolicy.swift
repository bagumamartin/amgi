/// Canonical authorization and refresh policy for raw engine calls that may
/// cross the MCP bridge. Keeping it in the shared protocol module prevents
/// the helper and app from drifting onto different service/method tables.
public enum MCPCallPolicy {
    /// Returns nil for any raw RPC the MCP surface does not intentionally
    /// expose. The bridge is deny-by-default so upstream service-index drift
    /// cannot silently turn a mutation into an authorized read.
    public static func requiredTier(service: UInt32, method: UInt32) -> ToolTier? {
        switch (service, method) {
        case (25, 7),  // notes.removeNotes
             (5, 2),   // cards.removeCards
             (7, 16):  // decks.removeDecks
            .full
        case (25, 1),  // notes.addNote
             (25, 5),  // notes.updateNotes
             (45, 7),  // tags.addNoteTags
             (45, 8),  // tags.removeNoteTags
             (5, 4),   // cards.setFlag
             (7, 1),   // decks.addDeck
             (7, 18),  // decks.renameDeck
             (41, 1),  // media.addMediaFile
             (9, 2),   // config.setConfigJsonNoUndo
             (3, 8):   // collectionOps.undo
            .safeWrite
        case (7, 0),   // decks.newDeck
             (7, 4),   // decks.getDeckTree
             (23, 6),  // notetypes.getNotetype
             (23, 8),  // notetypes.getNotetypeNames
             (25, 0),  // notes.newNote
             (25, 6),  // notes.getNote
             (29, 1),  // search.searchCards
             (29, 2),  // search.searchNotes
             (5, 0),   // cards.getCard
             (27, 6),  // cardRendering.renderExistingCard
             (43, 2),  // stats.graphs
             (9, 0),   // config.getConfigJson
             (41, 0),  // media.checkMedia
             (3, 7):   // collectionOps.getUndoStatus
            .readOnly
        default:
            nil
        }
    }

    public static func isMutating(service: UInt32, method: UInt32) -> Bool {
        guard let tier = requiredTier(service: service, method: method) else { return false }
        return tier > .readOnly
    }
}

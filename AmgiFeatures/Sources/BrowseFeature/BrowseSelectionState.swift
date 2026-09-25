import Foundation
import AnkiKit

struct BrowseSelectionState: Equatable, Sendable {
    var isSelectMode: Bool = false
    var selectedNoteIDs: Set<NoteID> = []
    /// Cards-mode selection: card IDs as picked in the list. Upstream
    /// card-mode operations use these directly; note mode expands notes to
    /// all their cards. Keeping both sets preserves card scope so selecting
    /// one template's card never touches its unselected siblings.
    var selectedCardIDs: Set<CardID> = []

    var isEmpty: Bool { selectedNoteIDs.isEmpty && selectedCardIDs.isEmpty }
    /// Total selected items in the active mode (cards win when non-empty).
    var count: Int { selectedCardIDs.isEmpty ? selectedNoteIDs.count : selectedCardIDs.count }

    /// Whether the batch action bar should be showing. macOS arms it purely
    /// from a multi-row `List` selection — there is no explicit mode to enter,
    /// so there is no Done button either. iOS enters `isSelectMode` from the
    /// overflow Select item (Mail), and the bar stays up even with an empty
    /// selection so the actions can enable as rows are ticked. On macOS any
    /// non-empty native selection arms the bar so sibling-card multi-selects
    /// are never hidden.
    var showsBatchActions: Bool {
        isSelectMode || selectedNoteIDs.count > 1 || !selectedCardIDs.isEmpty
    }

    mutating func enterSelectMode(preselect: NoteID? = nil) {
        isSelectMode = true
        selectedNoteIDs = preselect.map { [$0] } ?? []
        selectedCardIDs = []
    }

    mutating func enterSelectMode(preselectCard: CardID) {
        isSelectMode = true
        selectedCardIDs = [preselectCard]
        selectedNoteIDs = []
    }

    mutating func exitSelectMode() {
        isSelectMode = false
        selectedNoteIDs = []
        selectedCardIDs = []
    }

    /// A new source, search, mode, or result set is a new selection domain.
    /// Keeping ids here is especially dangerous on macOS: a native List can
    /// retain a highlighted row while the engine has already returned a
    /// different result set, and a later batch action would then target a
    /// note that is no longer visible.  Treat a result identity change as a
    /// hard boundary and leave Select mode as well.
    mutating func resetForResultChange() {
        exitSelectMode()
    }

    /// Drops ids that are no longer present while preserving an intentional
    /// empty Select mode. This is useful after a refresh that does not change
    /// the query, where callers still want the mode's Done affordance.
    mutating func reconcile(
        validNoteIDs: Set<NoteID>,
        validCardIDs: Set<CardID>
    ) {
        selectedNoteIDs.formIntersection(validNoteIDs)
        selectedCardIDs.formIntersection(validCardIDs)
        if selectedNoteIDs.isEmpty && selectedCardIDs.isEmpty {
            selectedNoteIDs = []
            selectedCardIDs = []
        }
    }

    /// Mail's Deselect All: drop the ticks but stay in select mode.
    mutating func clearSelectionKeepingMode() {
        selectedNoteIDs = []
        selectedCardIDs = []
    }

    mutating func toggle(_ id: NoteID) {
        if selectedNoteIDs.contains(id) {
            selectedNoteIDs.remove(id)
        } else {
            selectedNoteIDs.insert(id)
        }
    }

    mutating func toggle(card id: CardID) {
        if selectedCardIDs.contains(id) {
            selectedCardIDs.remove(id)
        } else {
            selectedCardIDs.insert(id)
        }
    }

    func contains(_ id: NoteID) -> Bool {
        selectedNoteIDs.contains(id)
    }

    func contains(card id: CardID) -> Bool {
        selectedCardIDs.contains(id)
    }
}

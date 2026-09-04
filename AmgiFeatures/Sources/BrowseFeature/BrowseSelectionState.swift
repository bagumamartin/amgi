import Foundation
import AnkiKit

struct BrowseSelectionState: Equatable, Sendable {
    var isSelectMode: Bool = false
    var selectedNoteIDs: Set<NoteID> = []

    var isEmpty: Bool { selectedNoteIDs.isEmpty }
    var count: Int { selectedNoteIDs.count }

    /// Whether the batch action bar should be showing. macOS arms it purely
    /// from a multi-row `List` selection — there is no explicit mode to enter,
    /// so there is no Done button either. iOS long-presses into `isSelectMode`.
    var showsBatchActions: Bool { isSelectMode || selectedNoteIDs.count > 1 }

    mutating func enterSelectMode(preselect: NoteID? = nil) {
        isSelectMode = true
        selectedNoteIDs = preselect.map { [$0] } ?? []
    }

    mutating func exitSelectMode() {
        isSelectMode = false
        selectedNoteIDs = []
    }

    mutating func toggle(_ id: NoteID) {
        if selectedNoteIDs.contains(id) {
            selectedNoteIDs.remove(id)
        } else {
            selectedNoteIDs.insert(id)
        }
    }

    func contains(_ id: NoteID) -> Bool {
        selectedNoteIDs.contains(id)
    }
}

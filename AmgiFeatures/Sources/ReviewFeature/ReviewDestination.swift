import Foundation
import CasePaths
import AnkiKit
import AmgiReviewCore

/// Single source of truth for every modal axis on the review screen: the note
/// editor, the template editor, and the dictionary lookup popup.
///
/// Replaces three independent optionals (`editingNote`, `editingTemplate`,
/// `lookupQuery`) threaded down as three bindings, which between them could
/// encode states the screen has no rendering for — two editors asking to show
/// at once, or a lookup raised behind one.
///
/// It also retires `ReviewLookupQuery`: the toolbar's "Look Up" opens the
/// popup with no query yet, which `.sheet(item:)` could only express by
/// wrapping the string in an `Identifiable` box. Presence is the case here,
/// so `.lookup("")` is a perfectly good presented state.
@CasePathable
enum ReviewDestination {
    case editNote(NoteRecord)
    case editTemplate(ReviewSession.TemplateTarget)
    case lookup(String)
}

package import SwiftUI
package import AnkiKit
import AmgiTheme

package struct NoteEditingDestinationView: View {
    let note: NoteRecord
    let deckID: DeckID?
    let embedInNavigationStack: Bool
    let resumeDraft: Bool
    let onSave: () -> Void

    package init(
        note: NoteRecord,
        deckID: DeckID? = nil,
        embedInNavigationStack: Bool = false,
        resumeDraft: Bool = false,
        onSave: @escaping () -> Void
    ) {
        self.note = note
        self.deckID = deckID
        self.embedInNavigationStack = embedInNavigationStack
        self.resumeDraft = resumeDraft
        self.onSave = onSave
    }

    package var body: some View {
        Group {
            if embedInNavigationStack {
                NavigationStack {
                    destinationBody
                }
            } else {
                destinationBody
            }
        }
    }

    @ViewBuilder
    private var destinationBody: some View {
        if note.isImageOcclusionNote {
            EditImageOcclusionNoteView(
                noteId: note.id,
                onSave: onSave,
                embedInNavigationStack: false
            )
        } else {
            NoteEditorView(note: note, deckID: deckID, resumeDraft: resumeDraft, onSave: onSave)
        }
    }
}

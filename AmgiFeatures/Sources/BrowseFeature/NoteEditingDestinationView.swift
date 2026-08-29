package import SwiftUI
package import AnkiKit
import AmgiTheme

package struct NoteEditingDestinationView: View {
    let note: NoteRecord
    let embedInNavigationStack: Bool
    let onSave: () -> Void

    package init(note: NoteRecord, embedInNavigationStack: Bool = false, onSave: @escaping () -> Void) {
        self.note = note
        self.embedInNavigationStack = embedInNavigationStack
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
            NoteEditorView(note: note, onSave: onSave)
        }
    }
}

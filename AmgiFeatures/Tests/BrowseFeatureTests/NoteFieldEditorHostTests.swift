import Testing
@testable import BrowseFeature

#if os(iOS)
import UIKit

@Suite("Note field editor host")
@MainActor
struct NoteFieldEditorHostTests {
    @Test func textViewIsTheEditableFirstResponder() {
        let editor = NoteFieldTextView()
        #expect(editor.isEditable)
        #expect(editor.isSelectable)
        #expect(editor.canBecomeFirstResponder)
        #expect(!editor.gutter.isUserInteractionEnabled)
    }

    @Test func sourceGutterInsetsTextWithoutWrappingTheEditor() {
        let editor = NoteFieldTextView()
        editor.setGutterVisible(true)
        #expect(!editor.gutter.isHidden)
        #expect(editor.textContainerInset.left == NoteFieldTextView.gutterWidth)
        editor.setGutterVisible(false)
        #expect(editor.gutter.isHidden)
        #expect(editor.textContainerInset.left == 0)
    }
}
#endif

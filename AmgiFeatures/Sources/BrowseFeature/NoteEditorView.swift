package import SwiftUI
import AmgiUI
package import AnkiKit
import AmgiTheme

/// Edit Note container: owns the toolbar and the transient "Saved" toast, and
/// drives a `NoteEditorModel` for the notetype lookup + note write. The form
/// is `NoteEditorContent`, bound to the model.
package struct NoteEditorView: View {
    @State private var model: NoteEditorModel
    let onSave: () -> Void

    @State private var showSavedConfirmation = false
    @Environment(\.dismiss) private var dismiss

    package init(note: NoteRecord, onSave: @escaping () -> Void) {
        _model = State(initialValue: NoteEditorModel(note: note))
        self.onSave = onSave
    }

    package var body: some View {
        NoteEditorContent(model: model)
            .navigationTitle("Edit Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            if await model.save() {
                                withAnimation(AmgiMotion.momentum) { showSavedConfirmation = true }
                                try? await Task.sleep(for: .seconds(1.5))
                                withAnimation(AmgiMotion.standard) { showSavedConfirmation = false }
                                onSave()
                            }
                        }
                    }
                    // Stay disabled across the "Saved" toast too — the model's
                    // isSaving flag clears the instant the write returns, but a
                    // second tap during the 1.5s toast would re-save and re-fire
                    // onSave (the pre-extraction save() held isSaving across the
                    // toast).
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isSaving || showSavedConfirmation)
                }
            }
            .overlay { savedToast }
            .task { await model.loadNote() }
    }

    @ViewBuilder
    private var savedToast: some View {
        if showSavedConfirmation {
            VStack {
                Spacer()
                Text("Saved")
                    .amgiFont(.bodyEmphasis)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .amgiMaterial(.light, in: Capsule())
                    .padding(.bottom, 32)
            }
            .transition(AmgiMotion.slide(from: .bottom))
        }
    }
}

// MARK: - NoteEditorContent

/// The Edit Note form: the note-type's fields and a tags field. Bound to a
/// `NoteEditorModel`; owns no I/O, so it renders in a `#Preview` from a
/// seeded model.
struct NoteEditorContent: View {
    @Environment(\.palette) private var palette
    @Bindable var model: NoteEditorModel

    var body: some View {
        Form {
            Section("Fields") {
                ForEach(Array(model.fieldNames.enumerated()), id: \.element) { index, name in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(name)
                            .amgiFont(.caption)
                            .foregroundStyle(palette.textSecondary)
                        RichNoteFieldEditor(htmlText: $model[fieldAt: index])
                    }
                }
            }

            Section("Tags") {
                TextField("Tags", text: $model.tags, prompt: Text("space-separated"))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        .frame(minWidth: 360, idealWidth: 460, maxWidth: 640)
        .presentationSizing(.fitted)
        #endif
    }
}

// MARK: - Preview

#if DEBUG
#Preview {
    let model = NoteEditorModel(note: NoteRecord(
        id: NoteID(1), guid: "g1", mid: NotetypeID(1), mod: 0, flds: "", sfld: "", csum: 0
    ))
    model.fieldNames = ["Front", "Back"]
    model.fieldValues = ["안녕하세요", "Hello"]
    model.tags = "vocab korean"
    return NavigationStack {
        NoteEditorContent(model: model)
            .navigationTitle("Edit Note")
            .navigationBarTitleDisplayMode(.inline)
    }
}
#endif

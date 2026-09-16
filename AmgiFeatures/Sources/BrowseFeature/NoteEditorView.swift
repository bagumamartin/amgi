package import SwiftUI
import AmgiUI
package import AnkiKit
import AmgiTheme

/// Edit Note container: owns the toolbar and the transient "Saved" toast, and
/// drives a `NoteEditorModel` for the notetype lookup + note write. The form
/// is `NoteEditorContent`, bound to the model.
package struct NoteEditorView: View {
    @State private var model: NoteEditorModel
    @State private var editingSession = NoteFieldEditingSession()
    let onSave: () -> Void
    private let resumeDraft: Bool

    @State private var showSavedConfirmation = false
    @State private var showParkedDraftPrompt = false
    @Environment(\.dismiss) private var dismiss

    package init(note: NoteRecord, deckID: DeckID? = nil, resumeDraft: Bool = false, onSave: @escaping () -> Void) {
        _model = State(initialValue: NoteEditorModel(note: note, deckID: deckID))
        self.resumeDraft = resumeDraft
        self.onSave = onSave
    }

    package var body: some View {
        NoteEditorContent(model: model)
            .navigationTitle("Edit Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { requestDismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            if await model.save() {
                                NoteComposerDraftStore.clearEdit(noteID: model.noteID.rawValue)
                                withAnimation(AmgiMotion.momentum) { showSavedConfirmation = true }
                                try? await Task.sleep(for: .seconds(1.5))
                                withAnimation(AmgiMotion.standard) { showSavedConfirmation = false }
                                onSave()
                            }
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isSaving || showSavedConfirmation || !model.hasUnsavedChanges)
                }
            }
            .modifier(NoteFieldFormatChrome(session: editingSession))
            .modifier(NoteFieldMediaBridge(session: editingSession))
            .overlay { savedToast }
            .task { await bootstrap() }
            .onChange(of: model.fieldValues) { _, values in
                editingSession.clozeFields = values
                persistEditDraft()
            }
            .onChange(of: model.tags) { _, _ in
                persistEditDraft()
            }
            .onChange(of: model.isClozeNotetype) { _, isCloze in
                editingSession.showsClozeTools = isCloze
            }
            #if os(macOS)
            .onExitCommand { requestDismiss() }
            #endif
            .confirmationDialog(
                "Unfinished edit",
                isPresented: $showParkedDraftPrompt,
                titleVisibility: .visible
            ) {
                Button("Resume") {
                    resumeParkedDraft()
                }
                Button("Start New") {
                    startNewLeavingParkedDraft()
                }
            } message: {
                Text("You have a draft for this card. Resume it, or start from the saved card — the draft stays in Drafts until you save or delete it.")
            }
    }

    private func bootstrap() async {
        await model.loadNote()
        if resumeDraft {
            resumeParkedDraft()
        } else if NoteComposerDraftStore.loadEdit(noteID: model.noteID.rawValue) != nil {
            showParkedDraftPrompt = true
        }
        editingSession.showsClozeTools = model.isClozeNotetype
        editingSession.clozeFields = model.fieldValues
    }

    private func persistEditDraft() {
        guard model.hasUnsavedChanges else { return }
        NoteComposerDraftStore.saveEdit(model.makeDraft())
    }

    private func resumeParkedDraft() {
        model.applyParkedDraftIfAny()
        editingSession.clozeFields = model.fieldValues
    }

    private func startNewLeavingParkedDraft() {
        model.revertToCommitted()
        editingSession.clozeFields = model.fieldValues
    }

    private func requestDismiss() {
        dismiss()
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
                        RichNoteFieldEditor(
                            htmlText: $model[fieldAt: index],
                            fieldIndex: index
                        )
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

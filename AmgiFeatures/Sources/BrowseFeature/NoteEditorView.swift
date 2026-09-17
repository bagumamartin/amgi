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
    /// Manual overrides; otherwise the notetype's `collapsed` flag rules.
    @State private var manuallyExpanded: Set<Int> = []
    @State private var manuallyCollapsed: Set<Int> = []

    var body: some View {
        Form {
            if let warning = model.duplicateWarning {
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(palette.warning)
                        Text(warning)
                            .amgiFont(.caption)
                            .foregroundStyle(palette.textPrimary)
                        Spacer()
                        Button("Show Duplicates") {
                            // Handled by the hosting Browse list via notification;
                            // inline navigation stays out of the editor.
                        }
                        .buttonStyle(.borderless)
                        .disabled(true)
                    }
                }
            }
            Section("Fields") {
                ForEach(Array(model.fieldNames.enumerated()), id: \.offset) { index, name in
                    fieldRow(index: index, name: name)
                }
            }

            Section("Tags") {
                let parsed = model.tags.split(separator: " ").map(String.init).filter { !$0.isEmpty }
                if !parsed.isEmpty {
                    TagPillsView(tags: parsed) { removed in
                        model.tags = parsed.filter { $0 != removed }.joined(separator: " ")
                    }
                    .padding(.bottom, 2)
                }
                TextField("Tags", text: $model.tags, prompt: Text("space-separated"))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onChange(of: model.tags) { _, _ in
                        Task { await model.refreshTagCompletions() }
                    }
                if !model.tagCompletions.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(model.tagCompletions.prefix(10), id: \.self) { completion in
                                Button(completion) {
                                    applyCompletion(completion)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }
                }
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        .frame(minWidth: 360, idealWidth: 460, maxWidth: 640)
        .presentationSizing(.fitted)
        #endif
        .task(id: model.fieldValues.first) {
            await model.refreshDuplicateWarning()
        }
    }

    @ViewBuilder
    private func fieldRow(index: Int, name: String) -> some View {
        let field = index < model.fieldConfigs.count ? model.fieldConfigs[index] : nil
        let defaultCollapsed = field?.config.collapsed ?? false
        let isCollapsed: Bool = manuallyExpanded.contains(index)
            ? false
            : (manuallyCollapsed.contains(index) ? true : defaultCollapsed)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(name)
                    .amgiFont(.caption)
                    .foregroundStyle(palette.textSecondary)
                Spacer(minLength: 4)
                Button(isCollapsed ? "Expand" : "Collapse") {
                    if isCollapsed {
                        manuallyCollapsed.remove(index)
                        manuallyExpanded.insert(index)
                    } else {
                        manuallyExpanded.remove(index)
                        manuallyCollapsed.insert(index)
                    }
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
            if !isCollapsed {
                RichNoteFieldEditor(
                    htmlText: $model[fieldAt: index],
                    fieldIndex: index
                )
            } else {
                Text(fieldPreview(model[fieldAt: index]))
                    .amgiFont(.caption)
                    .foregroundStyle(palette.textTertiary)
                    .lineLimit(1)
            }
        }
    }

    private func fieldPreview(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func applyCompletion(_ completion: String) {
        var parts = model.tags.split(separator: " ").map(String.init)
        if parts.isEmpty {
            model.tags = completion
        } else {
            parts[parts.count - 1] = completion
            model.tags = parts.joined(separator: " ")
        }
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

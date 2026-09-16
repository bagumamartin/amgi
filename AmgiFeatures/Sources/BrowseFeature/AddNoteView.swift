package import SwiftUI
import AmgiUI
package import AnkiKit
import AmgiTheme

/// Add Note container: owns the modal chrome (navigation, toolbar, dismissal)
/// and drives an `AddNoteModel` for deck/notetype loading and the note write.
/// The form itself is `AddNoteContent`, bound to the model.
package struct AddNoteView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: AddNoteModel
    @State private var editingSession = NoteFieldEditingSession()
    @State private var showAddedConfirmation = false
    @State private var showDismissConfirmation = false
    private let initialDraft: AddNoteDraft?
    let onSave: () -> Void

    package init(
        preselectedDeckId: DeckID? = nil,
        initialDraft: AddNoteDraft? = nil,
        onSave: @escaping () -> Void
    ) {
        let resolved = preselectedDeckId ?? initialDraft?.deckID.map { DeckID($0) }
        _model = State(initialValue: AddNoteModel(preselectedDeckId: resolved, initialDraft: initialDraft))
        self.initialDraft = initialDraft
        self.onSave = onSave
    }

    package var body: some View {
        NavigationStack {
            AddNoteContent(model: model)
                .navigationTitle("Add Note")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
                .modifier(NoteFieldFormatChrome(session: editingSession))
                .modifier(NoteFieldMediaBridge(session: editingSession))
                .modifier(NoteComposerDismissGuard(isBlocked: model.hasFieldContent) {
                    showDismissConfirmation = true
                })
                .confirmationDialog(
                    "Save your progress?",
                    isPresented: $showDismissConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Save Progress") {
                        NoteComposerDraftStore.saveAdd(model.makeDraft())
                        dismiss()
                    }
                    Button("Discard", role: .destructive) {
                        NoteComposerDraftStore.clearAdd()
                        dismiss()
                    }
                    Button("Keep Editing", role: .cancel) {}
                } message: {
                    Text("You have text that isn’t added to a card yet.")
                }
                .overlay { addedToast }
                .task { await bootstrap() }
                .onChange(of: model.fieldValues) { _, values in
                    editingSession.clozeFields = values
                    persistAddDraft()
                }
                .onChange(of: model.isClozeNotetype) { _, isCloze in
                    editingSession.showsClozeTools = isCloze
                }
                .onChange(of: model.tags) { _, _ in persistAddDraft() }
                .onChange(of: model.selectedDeckId) { _, _ in persistAddDraft() }
                .onChange(of: model.selectedNotetypeId) { _, _ in persistAddDraft() }
                #if os(macOS)
                .onExitCommand { requestDismiss() }
                #endif
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(leadingActionTitle) { handleLeadingAction() }
                .keyboardShortcut(.cancelAction)
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("Add") {
                Task {
                    if await model.save() {
                        NoteComposerDraftStore.clearAdd()
                        onSave()
                        model.resetForNextNote()
                        withAnimation(AmgiMotion.momentum) { showAddedConfirmation = true }
                        try? await Task.sleep(for: .seconds(1.5))
                        withAnimation(AmgiMotion.standard) { showAddedConfirmation = false }
                    }
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(model.isSaving || !model.hasFieldContent || showAddedConfirmation)
        }
    }

    private var leadingActionTitle: String {
        if model.hasFieldContent { return "Clear" }
        if model.addedCount > 0 { return "Done" }
        return "Cancel"
    }

    private func handleLeadingAction() {
        if model.hasFieldContent {
            model.resetForNextNote()
            return
        }
        requestDismiss()
    }

    private func persistAddDraft() {
        if model.hasFieldContent {
            NoteComposerDraftStore.saveAdd(model.makeDraft())
        } else {
            NoteComposerDraftStore.clearAdd()
        }
    }

    private func requestDismiss() {
        if model.hasFieldContent {
            showDismissConfirmation = true
        } else {
            dismiss()
        }
    }

    private func bootstrap() async {
        await model.loadData()
        if initialDraft == nil, let draft = NoteComposerDraftStore.loadAdd() {
            model.applyDraft(draft)
        }
        editingSession.showsClozeTools = model.isClozeNotetype
        editingSession.clozeFields = model.fieldValues
    }

    @ViewBuilder
    private var addedToast: some View {
        if showAddedConfirmation {
            VStack {
                Spacer()
                Text("Added")
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

// MARK: - AddNoteContent

struct AddNoteContent: View {
    @Environment(\.palette) private var palette
    @Bindable var model: AddNoteModel

    var body: some View {
        Form {
            Section("Deck") {
                Picker("Deck", selection: $model.selectedDeckId) {
                    ForEach(model.decks) { deck in
                        Text(deck.name).tag(deck.id)
                    }
                }
            }

            Section("Note Type") {
                Picker("Type", selection: $model.selectedNotetypeId) {
                    ForEach(model.notetypeNames, id: \.id) { entry in
                        Text(entry.name).tag(entry.id)
                    }
                }
                .onChange(of: model.selectedNotetypeId) {
                    Task { await model.loadFields() }
                }
            }

            Section("Fields") {
                ForEach(Array(model.fieldNames.enumerated()), id: \.element) { index, name in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(name)
                            .amgiFont(.caption)
                            .foregroundStyle(palette.textSecondary)
                        RichNoteFieldEditor(
                            htmlText: $model[fieldAt: index],
                            fieldIndex: index,
                            focusGeneration: model.fieldFocusGeneration
                        )
                    }
                }
            }

            Section("Tags") {
                TextField("Tags", text: $model.tags, prompt: Text("space-separated"))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }

            if let errorMessage = model.errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(palette.danger)
                        .amgiFont(.caption)
                }
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
    let model = AddNoteModel()
    model.decks = [.sample, .filtered]
    model.selectedDeckId = DeckInfo.sample.id
    model.notetypeNames = [(NotetypeID(1), "Basic"), (NotetypeID(2), "Cloze")]
    model.selectedNotetypeId = NotetypeID(1)
    model.fieldNames = ["Front", "Back"]
    model.fieldValues = ["안녕하세요", "Hello"]
    model.tags = "vocab korean"
    return NavigationStack {
        AddNoteContent(model: model)
            .navigationTitle("Add Note")
            .navigationBarTitleDisplayMode(.inline)
    }
}
#endif

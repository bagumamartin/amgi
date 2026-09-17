import OSLog
import AmgiAppCore
import AmgiAppShared
import AnkiBackend
import AnkiKit
import AnkiClients
import AnkiServices
import Dependencies
import SwiftUI

/// Data state + load/save logic for the Add Note form. Mirrors the other
/// screen models: the View owns navigation, the toolbar, and dismissal,
/// while the model owns deck/notetype loading, field assembly, and the note
/// write so the form stays testable and the View stays thin.
@Observable
@MainActor
final class AddNoteModel {
    var decks: [DeckInfo] = []
    var notetypeNames: [(id: NotetypeID, name: String)] = []
    var selectedDeckId: DeckID = DeckID(1)
    var selectedNotetypeId: NotetypeID = NotetypeID(0)
    var fieldNames: [String] = []
    var fieldValues: [String] = []
    var tags: String = ""
    var isSaving = false
    var errorMessage: String?
    var fieldFocusGeneration = 0
    var addedCount = 0
    var isClozeNotetype = false
    /// Sticky flags per field index (desktop pinned-field workflow for
    /// repeated Add entry). Persisted per notetype below.
    var stickyFields: [Bool] = []

    private var stickyKey: String {
        "browse.addNote.sticky.\(selectedNotetypeId.rawValue)"
    }

    private func loadStickyFlags(count: Int) {
        let saved = UserDefaults.standard.array(forKey: stickyKey) as? [Bool] ?? []
        if saved.count == count {
            stickyFields = saved
        } else {
            stickyFields = Array(repeating: false, count: count)
        }
    }

    private func persistStickyFlags() {
        UserDefaults.standard.set(stickyFields, forKey: stickyKey)
    }

    func setSticky(_ sticky: Bool, at index: Int) {
        guard stickyFields.indices.contains(index) else { return }
        stickyFields[index] = sticky
        persistStickyFlags()
    }

    @ObservationIgnored @Dependency(\.deckClient) private var deckClient
    @ObservationIgnored @Dependency(\.notetypesService) private var notetypesService
    @ObservationIgnored @Dependency(\.notesService) private var notesService
    @ObservationIgnored @Dependency(\.collectionStore) private var store

    @ObservationIgnored private let preselectedDeckId: DeckID?
    @ObservationIgnored private let initialDraft: AddNoteDraft?

    var wasOpenedOnADeck: Bool { preselectedDeckId != nil }

    init(preselectedDeckId: DeckID? = nil, initialDraft: AddNoteDraft? = nil) {
        self.preselectedDeckId = preselectedDeckId
        self.initialDraft = initialDraft
    }

    /// Positional projection into `fieldValues`, read through `@Bindable` as
    /// `$model[fieldAt: index]`. A subscript rather than a
    /// `Binding(get:set:)`-returning method so the field editors get a stable
    /// binding instead of a freshly-allocated closure pair on every body pass.
    subscript(fieldAt index: Int) -> String {
        get { index < fieldValues.count ? fieldValues[index] : "" }
        set { if index < fieldValues.count { fieldValues[index] = newValue } }
    }

    func loadData() async {
        decks = (try? await deckClient.fetchAll()) ?? []
        if let preselectedDeckId, decks.contains(where: { $0.id == preselectedDeckId }) {
            selectedDeckId = preselectedDeckId
        } else if let first = decks.first {
            selectedDeckId = first.id
        }

        do {
            let service = notetypesService
            notetypeNames = try await backendOffload { try service.getNotetypeNames() }
            // Honour an incoming draft's preferred notetype when it matches
            // one the user actually has; otherwise fall back to the first.
            let chosen = initialDraft?.notetypeID
                .flatMap { id in notetypeNames.first(where: { $0.id.rawValue == id }) }
                ?? notetypeNames.first
            if let chosen {
                selectedNotetypeId = chosen.id
                await loadFields()
            }
        } catch {
            Log.browse.error("Error loading notetypes: \(error)")
        }

        if let initialDraft, !initialDraft.tags.isEmpty {
            tags = initialDraft.tags.joined(separator: " ")
        }
    }

    func loadFields() async {
        guard selectedNotetypeId.rawValue != 0 else { return }
        do {
            let service = notetypesService
            let id = selectedNotetypeId
            let notetype = try await backendOffload { try service.getNotetype(id) }
            let previous = Dictionary(uniqueKeysWithValues: zip(fieldNames, fieldValues))
            fieldNames = notetype.fieldNames
            isClozeNotetype = notetype.kind == .cloze
            fieldValues = fieldNames.map { name in
                previous[name] ?? initialDraft?.fieldValues[name] ?? ""
            }
            loadStickyFlags(count: fieldNames.count)
        } catch {
            Log.browse.error("Error loading fields: \(error)")
        }
    }

    var hasFieldContent: Bool {
        fieldValues.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    func applyDraft(_ draft: NoteComposerDraft) {
        if let deckID = draft.deckID {
            selectedDeckId = DeckID(deckID)
        }
        if let notetypeID = draft.notetypeID {
            selectedNotetypeId = NotetypeID(notetypeID)
        }
        if !draft.fieldNames.isEmpty {
            fieldNames = draft.fieldNames
        }
        if !draft.fieldValues.isEmpty {
            fieldValues = draft.fieldValues
            while fieldValues.count < fieldNames.count { fieldValues.append("") }
        }
        tags = draft.tags
    }

    func makeDraft() -> NoteComposerDraft {
        NoteComposerDraft(
            deckID: selectedDeckId.rawValue,
            notetypeID: selectedNotetypeId.rawValue,
            fieldNames: fieldNames,
            fieldValues: fieldValues,
            tags: tags,
            noteID: nil
        )
    }

    /// Clears non-sticky fields for the next note; sticky (pinned) values
    /// persist across adds (desktop Add-mode workflow).
    func resetForNextNote() {
        if stickyFields.count == fieldValues.count {
            fieldValues = fieldValues.enumerated().map { idx, value in
                stickyFields[idx] ? value : ""
            }
        } else {
            fieldValues = Array(repeating: "", count: fieldNames.count)
        }
        errorMessage = nil
        fieldFocusGeneration += 1
    }

    /// Persist the note. Returns whether the write succeeded; on failure
    /// `errorMessage` carries the reason. Navigation/dismissal stays with
    /// the View.
    func save() async -> Bool {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            let notes = notesService
            let notetypeID = selectedNotetypeId
            let deckID = selectedDeckId
            let fields = fieldValues
            let tagList = tags.split(separator: " ").map(String.init)
            try await backendOffload {
                var template = try notes.newNote(notetypeID)
                template.fields = fields
                template.tags = tagList
                try notes.addNote(template, deckID)
            }
            // addNote doesn't surface OpChanges yet — invalidate the shared
            // tree cache conservatively so every host (DeckDetail, reader
            // lookup, Browse) sees fresh counts.
            store.apply(CollectionChanges(card: true, note: true, studyQueues: true))
            addedCount += 1
            return true
        } catch {
            errorMessage = "Failed to add note: \(error.localizedDescription)"
            return false
        }
    }
}

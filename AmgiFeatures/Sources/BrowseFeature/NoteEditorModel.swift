import OSLog
import AmgiAppCore
import AnkiBackend
import AnkiKit
import AnkiClients
import AnkiServices
import Dependencies
import SwiftUI

/// Field/tag state + load/save logic for editing an existing note. The View
/// owns the toolbar and the "Saved" toast; the model owns notetype lookup,
/// field unpacking, and the note write so the form stays testable.
@Observable
@MainActor
final class NoteEditorModel {
    var fieldNames: [String] = []
    var fieldValues: [String] = []
    var tags: String = ""
    var isSaving = false
    var isClozeNotetype = false
    /// Per-field display config (font/RTL/collapsed) from the notetype.
    /// Full `Notetype.Field` mirrors (not the `NotetypeFieldInfo` summary,
    /// which drops `collapsed`/`rtl`/`sticky`).
    var fieldConfigs: [Notetype.Field] = []
    /// Live duplicate-field warning for the sort field (desktop parity).
    var duplicateWarning: String?
    /// Tag completions for the current tag token (collection-aware).
    var tagCompletions: [String] = []
    private var originalFieldValues: [String] = []
    private var originalTags = ""

    @ObservationIgnored @Dependency(\.noteClient) private var noteClient
    @ObservationIgnored @Dependency(\.notetypesService) private var notetypesService
    @ObservationIgnored private let note: NoteRecord
    @ObservationIgnored private let deckID: DeckID?

    init(note: NoteRecord, deckID: DeckID? = nil) {
        self.note = note
        self.deckID = deckID
    }

    /// Positional projection into `fieldValues`, read through `@Bindable` as
    /// `$model[fieldAt: index]`. A subscript rather than a
    /// `Binding(get:set:)`-returning method so the field editors get a stable
    /// binding instead of a freshly-allocated closure pair on every body pass.
    subscript(fieldAt index: Int) -> String {
        get { index < fieldValues.count ? fieldValues[index] : "" }
        set { if index < fieldValues.count { fieldValues[index] = newValue } }
    }

    func loadNote() async {
        do {
            let service = notetypesService
            let mid = note.mid
            let notetype = try await backendOffload { try service.getNotetype(mid) }
            fieldNames = notetype.fieldNames
            isClozeNotetype = notetype.kind == .cloze
            @Dependency(\.notetypesClient) var fullClient
            if let full = try? await fullClient.get(mid) {
                fieldConfigs = full.fields
            } else {
                fieldConfigs = []
            }
        } catch {
            Log.browse.error("Error loading notetype: \(error)")
        }

        fieldValues = note.flds
            .split(separator: "\u{1f}", omittingEmptySubsequences: false)
            .map(String.init)
        while fieldValues.count < fieldNames.count { fieldValues.append("") }
        tags = note.tags.trimmingCharacters(in: .whitespaces)
        originalFieldValues = fieldValues
        originalTags = tags
    }

    var hasUnsavedChanges: Bool {
        fieldValues != originalFieldValues || tags != originalTags
    }

    var noteID: NoteID { note.id }

    /// Checks the sort field for duplicates elsewhere in the collection
    /// (desktop live duplicate warning). Sets `duplicateWarning`; empty = none.
    func refreshDuplicateWarning() async {
        duplicateWarning = nil
        guard let first = fieldValues.first?.trimmingCharacters(in: .whitespacesAndNewlines),
              !first.isEmpty else { return }
        let client = noteClient
        let ownID = note.id
        // `dupe:` needs the notetype id + first-field text.
        let query = "dupe:\(note.mid.rawValue),\(first)"
        guard let hits = try? await client.searchIds(query, nil) else { return }
        let others = hits.filter { $0 != ownID }
        if !others.isEmpty {
            duplicateWarning = "This field matches \(others.count) other note\(others.count == 1 ? "" : "s")."
        }
    }

    /// Collection-aware tag completions for the in-progress token.
    func refreshTagCompletions() async {
        let token = tags.split(separator: " ").last.map(String.init) ?? ""
        @Dependency(\.tagClient) var tagClient
        tagCompletions = (try? await tagClient.completeTag(token)) ?? []
    }

    func applyParkedDraftIfAny() {
        if let draft = NoteComposerDraftStore.loadEdit(noteID: note.id.rawValue) {
            applyDraft(draft)
        }
    }

    func applyDraft(_ draft: NoteComposerDraft) {
        if !draft.fieldValues.isEmpty {
            fieldValues = draft.fieldValues
            while fieldValues.count < fieldNames.count { fieldValues.append("") }
        }
        tags = draft.tags
    }

    func makeDraft() -> NoteComposerDraft {
        NoteComposerDraft(
            deckID: deckID?.rawValue,
            notetypeID: note.mid.rawValue,
            fieldNames: fieldNames,
            fieldValues: fieldValues,
            tags: tags,
            noteID: note.id.rawValue
        )
    }

    func revertToCommitted() {
        fieldValues = originalFieldValues
        tags = originalTags
    }

    func markSaved() {
        originalFieldValues = fieldValues
        originalTags = tags
    }

    /// Persist the edited fields/tags. Returns whether the write succeeded.
    func save() async -> Bool {
        isSaving = true
        defer { isSaving = false }

        let newFlds = fieldValues.joined(separator: "\u{1f}")
        let newSfld = fieldValues.first ?? ""
        // Anki's field checksum is FNV-1a over UTF-8 (NOT Swift's hash) —
        // hashValue produced values the engine's dupe search never sees.
        let newCsum = Int64(bitPattern: BrowseFnv.fnv1a(newSfld) & 0xFFFF_FFFF)

        var updatedNote = note
        updatedNote.flds = newFlds
        updatedNote.sfld = newSfld
        updatedNote.csum = newCsum
        updatedNote.tags = " \(tags) "

        do {
            try await noteClient.save(updatedNote)
            markSaved()
            return true
        } catch {
            return false
        }
    }
}

package import SwiftUI
import AmgiTheme
import AmgiUI
package import AnkiKit
import AnkiClients
import Dependencies

/// Lists unfinished add-note drafts and unsaved note edits. Scoped to a
/// deck tree when `deckIDs` is set (deck-detail overflow); collection-wide
/// when it is `nil` (Browse).
package struct NoteDraftsView: View {
    var deckIDs: Set<Int64>? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    @Dependency(\.deckClient) private var deckClient
    @Dependency(\.noteClient) private var noteClient

    @State private var tab: Tab = .add
    @State private var addDrafts: [NoteComposerDraft] = []
    @State private var editDrafts: [NoteComposerDraft] = []
    @State private var deckNames: [Int64: String] = [:]
    @State private var openedAdd: NoteComposerDraft?
    @State private var openedEdit: NoteRecord?
    @State private var missingEditMessage: String?

    private enum Tab: String, CaseIterable, Identifiable {
        case add = "New"
        case edit = "Edits"
        var id: String { rawValue }
    }

    package init(deckIDs: Set<Int64>? = nil) {
        self.deckIDs = deckIDs
    }

    package var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Drafts", selection: $tab) {
                    ForEach(Tab.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, AmgiSpacing.md)
                .padding(.vertical, AmgiSpacing.sm)

                List {
                    switch tab {
                    case .add:
                        addList
                    case .edit:
                        editList
                    }
                }
                #if os(iOS)
                .listStyle(.insetGrouped)
                #endif
            }
            .background(palette.background)
            .navigationTitle("Drafts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    EditButton()
                }
            }
            .task { await reload() }
            .sheet(item: $openedAdd) { draft in
                AddNoteView(composerDraft: draft) {
                    openedAdd = nil
                    Task { await reload() }
                }
            }
            .sheet(item: $openedEdit) { note in
                NavigationStack {
                    NoteEditingDestinationView(note: note, resumeDraft: true) {
                        openedEdit = nil
                        Task { await reload() }
                    }
                }
            }
            .alert(
                "Note isn’t in the collection",
                isPresented: Binding(
                    get: { missingEditMessage != nil },
                    set: { if !$0 { missingEditMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { missingEditMessage = nil }
            } message: {
                Text(missingEditMessage ?? "")
            }
        }
    }

    @ViewBuilder
    private var addList: some View {
        if addDrafts.isEmpty {
            emptyRow(title: "No New Drafts", detail: "Unfinished notes will show up here.")
        } else {
            ForEach(addDrafts) { draft in
                Button {
                    openedAdd = draft
                } label: {
                    draftRow(draft, kindLabel: "New note")
                }
                .accessibilityLabel("Resume new note draft")
                .contextMenu {
                    Button(role: .destructive) {
                        NoteComposerDraftStore.deleteAdd(id: draft.id)
                        addDrafts.removeAll { $0.id == draft.id }
                    } label: {
                        Label("Delete Draft", systemImage: "trash")
                    }
                }
            }
            .onDelete { offsets in
                deleteAdds(at: offsets)
            }
        }
    }

    @ViewBuilder
    private var editList: some View {
        if editDrafts.isEmpty {
            emptyRow(title: "No Edit Drafts", detail: "Unsaved edits to existing notes will show up here.")
        } else {
            ForEach(editDrafts) { draft in
                Button {
                    Task { await openEdit(draft) }
                } label: {
                    draftRow(draft, kindLabel: "Unsaved edit")
                }
                .accessibilityLabel("Resume edited note draft")
                .contextMenu {
                    Button(role: .destructive) {
                        if let noteID = draft.noteID {
                            NoteComposerDraftStore.deleteEdit(noteID: noteID)
                        }
                        editDrafts.removeAll { $0.id == draft.id }
                    } label: {
                        Label("Delete Draft", systemImage: "trash")
                    }
                }
            }
            .onDelete { offsets in
                deleteEdits(at: offsets)
            }
        }
    }

    private func emptyRow(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: AmgiSpacing.xs) {
            Text(title)
                .amgiFont(.bodyEmphasis)
                .foregroundStyle(palette.textPrimary)
            Text(detail)
                .amgiFont(.caption)
                .foregroundStyle(palette.textSecondary)
        }
        .padding(.vertical, AmgiSpacing.sm)
    }

    private func draftRow(_ draft: NoteComposerDraft, kindLabel: String) -> some View {
        VStack(alignment: .leading, spacing: AmgiSpacing.xxs) {
            Text(draft.preview)
                .amgiFont(.body)
                .foregroundStyle(palette.textPrimary)
                .lineLimit(2)
            Text(subtitle(for: draft, kindLabel: kindLabel))
                .amgiFont(.caption)
                .foregroundStyle(palette.textSecondary)
                .lineLimit(1)
        }
        .padding(.vertical, AmgiSpacing.xxs)
    }

    private func subtitle(for draft: NoteComposerDraft, kindLabel: String) -> String {
        var parts = [kindLabel]
        if let deckID = draft.deckID, let name = deckNames[deckID] {
            parts.append(leafName(name))
        }
        parts.append(draft.updatedAt.formatted(.relative(presentation: .named)))
        return parts.joined(separator: " · ")
    }

    private func leafName(_ fullName: String) -> String {
        String(fullName.split(separator: "::", omittingEmptySubsequences: true).last ?? Substring(fullName))
    }

    private func deleteAdds(at offsets: IndexSet) {
        for index in offsets {
            NoteComposerDraftStore.deleteAdd(id: addDrafts[index].id)
        }
        addDrafts.remove(atOffsets: offsets)
    }

    private func deleteEdits(at offsets: IndexSet) {
        for index in offsets {
            if let noteID = editDrafts[index].noteID {
                NoteComposerDraftStore.deleteEdit(noteID: noteID)
            }
        }
        editDrafts.remove(atOffsets: offsets)
    }

    private func openEdit(_ draft: NoteComposerDraft) async {
        guard let noteID = draft.noteID else { return }
        do {
            if let note = try await noteClient.fetch(NoteID(noteID)) {
                openedEdit = note
            } else {
                NoteComposerDraftStore.deleteEdit(noteID: noteID)
                await reload()
                missingEditMessage = "That note was deleted. The draft was removed."
            }
        } catch {
            missingEditMessage = "Couldn’t open that draft."
        }
    }

    private func reload() async {
        addDrafts = NoteComposerDraftStore.addDrafts(inDeckIDs: deckIDs)
        editDrafts = NoteComposerDraftStore.editDrafts(inDeckIDs: deckIDs)
        let decks = (try? await deckClient.fetchAll()) ?? []
        deckNames = Dictionary(uniqueKeysWithValues: decks.map { ($0.id.rawValue, $0.name) })
    }
}
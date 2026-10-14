package import SwiftUI
import AmgiAppCore
import AmgiReviewCore
import AnkiKit
import AnkiClients
import Dependencies
import AmgiTheme
import AmgiUI

package enum QuickCaptureKind: String, Identifiable { case camera, text; package var id: String { rawValue } }

/// Separate capture session; normal Add/Edit drafts and sticky fields are untouched.
package struct QuickCaptureView: View {
    let kind: QuickCaptureKind
    @Environment(\.dismiss) private var dismiss
    @State private var model = AddNoteModel(preselectedDeckId: DeckID(1))
    @State private var editing = NoteFieldEditingSession()
    @State private var ready = false
    @State private var savedTo: String?
    @State private var profile = AccountStore.shared.selectedContext
    @State private var persistenceError: String?
    #if os(macOS)
    @State private var showMacCamera = false
    @Dependency(\.mediaClient) private var mediaClient
    #endif
    private var draftURL: URL {
        AccountStore.profileDirectory(for: AccountStore.shared.current.id).appendingPathComponent("quick-capture-\(profile.id).json")
    }
    private var typeKey: String { "capture.notetype.\(profile.id)" }
    package init(kind: QuickCaptureKind) { self.kind = kind }
    package var body: some View {
        @Bindable var model = model
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    Picker("Save to", selection: $model.selectedDeckId) {
                        if !model.decks.contains(where: { $0.id == model.selectedDeckId }) { Text("Choose deck").tag(DeckID(0)) }
                        ForEach(model.decks) { Text($0.name).tag($0.id) }
                    }.labelsHidden()
                    Spacer()
                    Picker("Note type", selection: $model.selectedNotetypeId) {
                        ForEach(model.notetypeNames, id: \.id) { Text($0.name).tag($0.id) }
                    }.labelsHidden()
                }.padding(.horizontal, 16).padding(.bottom, 8)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(Array(model.fieldNames.enumerated()), id: \.offset) { index, name in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(name).font(.caption).foregroundStyle(.secondary)
                                RichNoteFieldEditor(htmlText: $model[fieldAt: index], fieldIndex: index, focusGeneration: model.fieldFocusGeneration)
                                    .frame(minHeight: 90)
                            }
                        }
                        TextField("Tags", text: $model.tags).textFieldStyle(.plain)
                        if let error = model.errorMessage ?? persistenceError { Text(error).font(.caption).foregroundStyle(.red) }
                        if let savedTo { Label("Saved to \(savedTo)", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout) }
                    }.padding(16)
                }
                HStack {
                    Button("Camera", systemImage: "camera") { openCamera() }.labelStyle(.iconOnly)
                    Spacer()
                    Button("Save") { Task { await save() } }
                        .buttonStyle(.glassProminent).accessibilityIdentifier("capture.save")
                        .disabled(!ready || model.isSaving || !model.hasFieldContent || !model.decks.contains(where: { $0.id == model.selectedDeckId }))
                }.padding(16)
            }
            .navigationTitle("Quick Capture")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close", systemImage: "xmark") { persist(); dismiss() }.labelStyle(.iconOnly).accessibilityIdentifier("capture.close") } }
            .modifier(NoteFieldFormatChrome(session: editing))
            .modifier(NoteFieldMediaBridge(session: editing))
            #if os(macOS)
            .sheet(isPresented: $showMacCamera) {
                MacQuickCamera(onPhoto: { data in Task { await insertPhoto(data) } }, onChooseFile: { editing.pendingMediaSource = .files })
            }
            #endif
            .task { await prepare() }
            .onChange(of: model.fieldValues) { editing.clozeFields = model.fieldValues; persist() }
            .onChange(of: model.tags) { persist() }
            .onChange(of: model.selectedNotetypeId) {
                guard ready else { return }
                UserDefaults.standard.set(model.selectedNotetypeId.rawValue, forKey: typeKey)
                Task { await model.loadFields(); editing.showsClozeTools = model.isClozeNotetype; persist() }
            }
            .onChange(of: AccountStore.shared.selectionID) { dismiss() }
        }
        .interactiveDismissDisabled(model.isSaving)
        .onDisappear { persist() }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #if os(macOS)
        .frame(minWidth: 400, idealWidth: 460, minHeight: 420)
        #endif
    }
    private func prepare() async {
        guard !ready else { return }
        await model.loadData()
        guard profile.isCurrent(AccountStore.shared.selectedContext) else { return }
        // Missing Default must ask for a destination; never silently pick another.
        if !model.decks.contains(where: { $0.id.rawValue == 1 }) { model.selectedDeckId = DeckID(0) }
        let remembered = UserDefaults.standard.object(forKey: typeKey) as? Int64
        if let remembered, model.notetypeNames.contains(where: { $0.id.rawValue == remembered }) {
            model.selectedNotetypeId = NotetypeID(remembered); await model.loadFields()
        }
        if let data = try? Data(contentsOf: draftURL), let draft = try? JSONDecoder().decode(NoteComposerDraft.self, from: data),
           model.notetypeNames.contains(where: { $0.id.rawValue == draft.notetypeID }) {
            // Recover content but reset each fresh session's destination to Default.
            var restored = draft; restored.deckID = model.selectedDeckId.rawValue
            model.applyDraft(restored)
        }
        editing.showsClozeTools = model.isClozeNotetype; editing.clozeFields = model.fieldValues
        ready = true
        model.fieldFocusGeneration += 1
        if kind == .camera {
            // Wait for the rich field to attach its insertion responder; avoids
            // dropping the capture into a sheet with no destination field.
            for _ in 0..<30 {
                if editing.insertionResponder != nil { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard profile.isCurrent(AccountStore.shared.selectedContext), !Task.isCancelled else { return }
            openCamera()
        }
    }
    private func openCamera() {
        #if os(macOS)
        showMacCamera = true
        #else
        editing.pendingMediaSource = .camera
        #endif
    }
    #if os(macOS)
    private func insertPhoto(_ data: Data) async {
        guard profile.isCurrent(AccountStore.shared.selectedContext), ReviewSessionActivity.shared.beginMutation() else { return }
        defer { ReviewSessionActivity.shared.endMutation() }
        do {
            let filename = try await mediaClient.addFile("capture-\(UUID().uuidString).jpg", data)
            guard profile.isCurrent(AccountStore.shared.selectedContext) else { return }
            editing.insertMedia(filename: filename)
        } catch { model.errorMessage = "Could not attach the photo: \(error.localizedDescription)" }
    }
    #endif
    private func save() async {
        guard profile.isCurrent(AccountStore.shared.selectedContext),
              !ReviewSessionCoordinator.shared.hasActiveSession,
              ReviewSessionActivity.shared.beginMutation() else { model.errorMessage = "The collection is busy. Try again after review or profile switching finishes."; return }
        defer { ReviewSessionActivity.shared.endMutation() }
        if await model.save() {
            savedTo = model.decks.first(where: { $0.id == model.selectedDeckId })?.name
            model.fieldValues = Array(repeating: "", count: model.fieldNames.count)
            model.tags = ""; model.fieldFocusGeneration += 1
            try? FileManager.default.removeItem(at: draftURL)
            UserDefaults.standard.set(model.selectedNotetypeId.rawValue, forKey: typeKey)
        }
    }
    private func persist() {
        guard ready, profile.isCurrent(AccountStore.shared.selectedContext) else { return }
        do {
            if model.hasFieldContent { try JSONEncoder().encode(model.makeDraft()).write(to: draftURL, options: .atomic) }
            else if FileManager.default.fileExists(atPath: draftURL.path) { try FileManager.default.removeItem(at: draftURL) }
        } catch { persistenceError = "Could not save capture draft: \(error.localizedDescription)" }
    }
}

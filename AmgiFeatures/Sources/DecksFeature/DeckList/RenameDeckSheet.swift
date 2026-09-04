import SwiftUI
import AmgiUI
import AmgiAppShared
import AnkiKit
import AmgiIcons
import AnkiClients
import Dependencies

// MARK: - RenameDeckSheet

struct RenameDeckSheet: View {
    let deckId: DeckID
    let onDone: () -> Void

    @Dependency(\.deckClient) var deckClient
    @Dependency(\.collectionStore) var store
    @State private var name: String
    @State private var selectedIconName: String?
    @State private var iconManuallySet = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    init(deckId: DeckID, currentName: String, onDone: @escaping () -> Void) {
        self.deckId = deckId
        self.onDone = onDone
        _name = State(initialValue: currentName)
        // A previously stored override is a manual pick — it must survive
        // this session untouched unless the user changes it.
        let existing = DeckIconOverrides.iconName(for: deckId.rawValue)
        _selectedIconName = State(initialValue: existing)
        _iconManuallySet = State(initialValue: existing != nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Deck name", text: $name)
                        .autocorrectionDisabled()
                }
                Section("Icon") {
                    DeckIconSection(
                        selectedIconName: $selectedIconName,
                        iconManuallySet: $iconManuallySet,
                        deckName: name
                    )
                }
            }
            .navigationTitle("Rename Deck")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await rename() }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
                }
            }
            .alert(
                "Couldn't rename deck",
                isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }),
                presenting: errorMessage
            ) { _ in
                Button("OK") {}
            } message: { message in
                Text(message)
            }
        }
    }

}

private extension RenameDeckSheet {
    func rename() async {
        isSaving = true
        do {
            let changes = try await deckClient.rename(deckId, name.trimmingCharacters(in: .whitespaces))
            // Manual pick ⇒ persist it; back to Automatic ⇒ clear any stale
            // override so the icon follows the (possibly new) name again.
            // col.conf write → rides collection sync to every device.
            await DeckIconOverrides.set(
                iconManuallySet ? selectedIconName : nil,
                for: deckId.rawValue
            )
            store.apply(changes)
            // Icon-only edits (rename that produced no tree change) still
            // need a generation bump so tiles refresh immediately.
            if !changes.affectsDeckTree {
                store.invalidateAll(origin: .localUser)
            }
            onDone()
        } catch {
            errorMessage = "Failed to rename deck: \(error.localizedDescription)"
        }
        isSaving = false
    }
}

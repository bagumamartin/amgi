import SwiftUI
import AnkiKit
import AmgiIcons
import AnkiClients
import Dependencies

// MARK: - CreateDeckSheet

/// Trivial sheet — keeps `@Dependency` inline. Previewed via
/// `withDependencies { $0.deckClient = .previewValue }`.
struct CreateDeckSheet: View {
    let onDone: () -> Void

    @Dependency(\.deckClient) var deckClient
    @Dependency(\.collectionStore) var store
    @State private var name = ""
    @State private var selectedIconName: String?
    @State private var iconManuallySet = false
    @State private var isSaving = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text("Use :: for subdecks"))
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
            #if os(macOS)
            .formStyle(.grouped)
            .frame(minWidth: 340, idealWidth: 400, maxWidth: 520)
            .presentationSizing(.fitted)
            #endif
            .navigationTitle("New Deck")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task { await create() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
                }
            }
        }
    }

}

private extension CreateDeckSheet {
    func create() async {
        isSaving = true
        do {
            let creation = try await deckClient.create(name.trimmingCharacters(in: .whitespaces))
            // Only manual picks persist; non-picked decks keep auto-following
            // their name at render time. col.conf write → rides collection sync.
            if iconManuallySet, let iconName = selectedIconName {
                await DeckIconOverrides.set(iconName, for: creation.id.rawValue)
            }
            store.apply(creation.changes)
            onDone()
        } catch {
            print("[CreateDeckSheet] Create failed: \(error)")
        }
        isSaving = false
    }
}

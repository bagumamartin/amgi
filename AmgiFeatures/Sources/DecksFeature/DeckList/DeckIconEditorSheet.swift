import SwiftUI
import AmgiIcons
import AmgiAppShared
import AnkiClients
import Dependencies

/// Standalone icon editing for an existing deck, reachable from a Library
/// row at the same level as Delete/Rename (swipe action + context menu).
///
/// Commits immediately: picking a cell writes the override to `col.conf`
/// and bumps the collection generation, so every screen's tiles refresh on
/// the spot and the change rides the automatic sync to other devices.
/// The picker's "Automatic" action clears any override.
struct DeckIconEditorSheet: View {
    let deckId: Int64
    let deckName: String
    let onDone: () -> Void

    @Dependency(\.collectionStore) private var store
    @State private var selection: String?

    init(deckId: Int64, deckName: String, onDone: @escaping () -> Void) {
        self.deckId = deckId
        self.deckName = deckName
        self.onDone = onDone
        // Mirror is fresh: the Library load that produced this row pulled
        // the conf blob this generation.
        _selection = State(initialValue: DeckIconOverrides.iconName(for: deckId))
    }

    var body: some View {
        // IconPickerView owns its NavigationStack + toolbar (including the
        // "Automatic" reset); presented directly as sheet content.
        IconPickerView(selection: $selection) { picked in
            Task { await commit(picked) }
        }
    }

    private func commit(_ picked: String?) async {
        await DeckIconOverrides.set(picked, for: deckId)
        // Generation bump → every generation-keyed screen reloads with the
        // new icon immediately; `.localUser` also queues an automatic sync
        // so the conf blob reaches other devices.
        store.invalidateAll(origin: .localUser)
        onDone()
    }
}

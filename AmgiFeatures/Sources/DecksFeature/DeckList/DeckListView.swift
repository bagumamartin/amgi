package import SwiftUI
package import AmgiAppCore
import AmgiAppShared
import AmgiUI
import AnkiKit
import AnkiClients
import Dependencies
import BrowseFeature

/// Library container: owns navigation, sheets, and the toolbar, and drives
/// a `DeckListModel` for load/refresh + deck mutations. Rendering is
/// delegated to `LibraryListContent` (AmgiUI); data assembly lives in the
/// model. The View is intentionally thin — presentation wiring only.
package struct DeckListView: View {
    private let onSwitchProfile: (AmgiAccount) async -> Void
    @Dependency(\.collectionStore) private var store
    @State private var model: DeckListModel
    @State private var showCreateSheet = false
    @State private var renameTarget: DeckRowViewData?
    @State private var pendingDeck: DeckInfo?
    /// Deck detail grows out of the row that was tapped, rather than cutting
    /// in from the trailing edge — the row and the screen are the same thing.
    @Namespace private var deckTransition

    /// `onSwitchProfile` is the app root's profile switch — see
    /// `ProfilePickerMenu`.
    package init(onSwitchProfile: @escaping (AmgiAccount) async -> Void) {
        self.onSwitchProfile = onSwitchProfile
        _model = State(initialValue: DeckListModel())
    }

    /// Preview / test seam — internal so the model stays module-private.
    init(model: DeckListModel, onSwitchProfile: @escaping (AmgiAccount) async -> Void = { _ in }) {
        self.onSwitchProfile = onSwitchProfile
        _model = State(initialValue: model)
    }

    package var body: some View {
        LibraryListContent(
            state: model.state,
            onRefresh: { await model.load() },
            onStartReview: { pendingDeck = model.firstReviewableDeck() },
            onTapDeck: { row in pendingDeck = row.asDeckInfo },
            onDeleteDeck: { rawID in await model.delete(DeckID(rawID)) },
            onRenameDeck: { row in renameTarget = row },
            onCreateDeck: { showCreateSheet = true },
            deckTransition: deckTransition
        )
        // `LibraryListContent` stores seven closures, which makes it
        // incomparable to AttributeGraph by default — see the Equatable
        // conformance in AmgiUI. It declares equality over `state`, so this
        // turns a field walk into a value compare.
        .equatable()
        .navigationTitle("Library")
        .navigationDestination(item: $pendingDeck) { deck in
            DeckDetailView(deck: deck)
                .navigationTransition(.zoom(sourceID: deck.id.rawValue, in: deckTransition))
        }
        .toolbar { toolbarContent }
        .sheet(isPresented: $showCreateSheet) {
            CreateDeckSheet {
                showCreateSheet = false
            }
        }
        .sheet(item: $renameTarget) { row in
            RenameDeckSheet(deckId: DeckID(row.id), currentName: row.fullName) {
                renameTarget = nil
            }
        }
        // Keyed on the store's generation: any Invalidation (deck mutation,
        // sync, import, review-end) re-runs the load; `.task` still cancels
        // on disappear.
        .task(id: store.generation) { await model.load() }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            ProfilePickerMenu(onSwitch: onSwitchProfile)
        }
        ToolbarItem(placement: .topBarTrailing) {
            // `BrowseView` owns its own title and search field and expects to be
            // pushed, so a plain NavigationLink is the whole wiring — no route
            // state to thread through the model.
            NavigationLink {
                BrowseView()
            } label: {
                Label("Browse", systemImage: "square.stack.3d.up")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button("New Deck", systemImage: "plus") {
                showCreateSheet = true
            }
        }
    }
}

// MARK: - Preview
//
// None here, deliberately. Previews of a package target run in XCPreviewAgent
// with no app host, and the JIT can only resolve symbols from dylibs in the
// products dir — `libanki_bridge_ios.a` is a static archive, so anything whose
// preview transitively reaches AnkiBackend fails to link with
// "Symbols not found: [_anki_open_backend, …]". DeckListView reaches it through
// DeckListModel, DeckDetailView, and ReviewView. It rendered while this file
// lived in the app target (AmgiApp.debug.dylib exports those four symbols);
// it cannot since the DecksFeature extraction.
//
// The deck list surface previews from `LibraryListContent` in AmgiUI instead —
// same pixels, engine-free, including the minimal-palette variant this file
// used to pin.

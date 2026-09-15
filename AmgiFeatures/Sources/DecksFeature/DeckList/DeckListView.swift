package import SwiftUI
import AmgiAppShared
import AmgiUI
import AnkiKit
import AnkiClients
import Dependencies

/// Library container: owns navigation, sheets, and the toolbar, and drives
/// a `DeckListModel` for load/refresh + deck mutations. Rendering is
/// delegated to `LibraryListContent` (AmgiUI); data assembly lives in the
/// model. The View is intentionally thin — presentation wiring only.
package struct DeckListView: View {
    @Dependency(\.collectionStore) private var store
    @State private var model: DeckListModel
    @State private var showCreateSheet = false
    @State private var showExportSheet = false
    @State private var showImport = false
    @State private var renameTarget: DeckRowViewData?
    @State private var pendingDeck: DeckInfo?
    /// Deck detail grows out of the row that was tapped, rather than cutting
    /// in from the trailing edge — the row and the screen are the same thing.
    @Namespace private var deckTransition

    /// Profile switching lives on the root stack (MainTabView `.accountMenu()`),
    /// not here — applying it twice doubled the leading profile pill.
    package init() {
        _model = State(initialValue: DeckListModel())
    }

    /// Preview / test seam — internal so the model stays module-private.
    init(model: DeckListModel) {
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
                #if os(iOS)
                .navigationTransition(.zoom(sourceID: deck.id.rawValue, in: deckTransition))
                #endif
        }
        .toolbar { toolbarContent }
        .sheet(isPresented: $showCreateSheet) {
            CreateDeckSheet {
                showCreateSheet = false
            }
        }
        .sheet(isPresented: $showExportSheet) {
            ExportPackagesSheet()
        }
        .sheet(item: $renameTarget) { row in
            RenameDeckSheet(deckId: DeckID(row.id), currentName: row.fullName) {
                renameTarget = nil
            }
        }
        .deckImport(isPresented: $showImport) {
            store.invalidateAll()
        }
        // Keyed on the store's generation: any Invalidation (deck mutation,
        // sync, import, review-end) re-runs the load; `.task` still cancels
        // on disappear.
        .task(id: store.generation) { await model.load() }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // One glass capsule: Sync · Import · Export · New Deck. Browse is
        // its own tab — a Library push was leftover from the old drill-in.
        ToolbarItemGroup(placement: .topBarTrailing) {
            SyncToolbarButton()
            Button {
                showImport = true
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .accessibilityLabel("Import deck")
            .help("Import deck")
            Button {
                showExportSheet = true
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .accessibilityLabel("Export")
            .help("Export deck or collection package")
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

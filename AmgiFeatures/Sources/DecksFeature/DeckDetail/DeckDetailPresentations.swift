import SwiftUI
import AnkiKit
import SwiftNavigation
import SwiftUINavigation
import ReviewFeature
import UniformTypeIdentifiers  // UTType.data

// Two ViewModifiers split out from `DeckDetailView.body` so the SwiftUI
// type-checker doesn't blow up on a single long modifier chain. AnyView
// wrappers on the closure returns keep the outer body type stable across
// sheet/alert variants.

struct SheetCoverModifier: ViewModifier {
    let destination: Binding<DeckDetailDestination?>
    let deckId: DeckID
    let onReviewDismiss: () -> Void
    let sheetContent: (DeckDetailSheet) -> AnyView

    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content
            #if os(macOS)
            // macOS HIG: review opens in its own window; the deck-detail
            // screen returns to the underlying content instead of being
            // covered by a full-screen modal.
            .onChange(of: destination.wrappedValue) { _, newValue in
                guard case .review? = newValue else { return }
                ReviewWindowQueue.shared.enqueue(deckId)
                openWindow(id: "review")
                destination.wrappedValue = nil
            }
            #else
            .fullScreenCover(isPresented: destination.review) {
                ReviewView(deckId: deckId) { onReviewDismiss() }
            }
            #endif
            .sheet(item: destination.sheet) { sheet in
                sheetContent(sheet)
            }
    }
}

struct AlertImporterModifier: ViewModifier {
    let destination: Binding<DeckDetailDestination?>
    let currentAlert: DeckDetailAlert?
    let alertTitle: String
    let alertActions: (DeckDetailAlert) -> AnyView
    let alertMessage: (DeckDetailAlert) -> AnyView
    let onImportResult: (Result<URL, any Error>) -> Void

    func body(content: Content) -> some View {
        content
            .alert(
                alertTitle,
                isPresented: Binding(destination.alert),
                presenting: currentAlert
            ) { alert in
                alertActions(alert)
            } message: { alert in
                alertMessage(alert)
            }
            .fileImporter(
                isPresented: destination.importer,
                allowedContentTypes: [.data]
            ) { result in
                onImportResult(result)
            }
    }
}


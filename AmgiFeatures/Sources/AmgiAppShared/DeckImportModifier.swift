public import SwiftUI

/// Presents the system importer and routes the selected file to the root-owned,
/// format-aware review flow. Keeping presentation here preserves each feature's
/// existing toolbar entry point while ensuring every import follows the same
/// staging, review, execution, and error lifecycle.
private struct DeckImportModifier: ViewModifier {
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content
            .fileImporter(
                isPresented: $isPresented,
                allowedContentTypes: AnkiImportFormat.supportedContentTypes
            ) { result in
                if case .success(let url) = result {
                    ImportRequestRouter.shared.request(url)
                }
            }
    }
}

extension View {
    /// Attach the system Anki-compatible file picker.
    package func deckImport(isPresented: Binding<Bool>) -> some View {
        modifier(DeckImportModifier(isPresented: isPresented))
    }
}

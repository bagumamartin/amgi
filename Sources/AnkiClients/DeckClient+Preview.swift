#if DEBUG
import AnkiKit
import Dependencies

extension DeckClient {
    /// Deterministic in-memory client used by SwiftUI `#Preview` blocks.
    /// Reads return canned `AnkiKit` fixtures; writes are no-ops.
    public static let previewValue = DeckClient(
        fetchAll: { DeckTreeNode.sampleTree.flattened() },
        fetchTree: { DeckTreeNode.sampleTree },
        countsForDeck: { _ in .sampleLight },
        create: { _ in DeckCreation(id: DeckID(999), changes: CollectionChanges()) },
        rename: { _, _ in CollectionChanges() },
        delete: { _ in CollectionChanges() },
        rebuildFilteredDeck: { _ in 0 },
        emptyFilteredDeck: { _ in },
        extendLimits: { _, _, _ in },
        customStudyDefaults: { _ in
            CustomStudyDefaults(
                tags: [
                    CustomStudyTag(name: "exam::high-yield"),
                    CustomStudyTag(name: "pharmchem::structures"),
                ],
                extendNew: 10,
                extendReview: 50,
                availableNew: 45,
                availableReview: 254,
                availableNewInChildren: 120,
                availableReviewInChildren: 310
            )
        },
        customStudy: { _, _ in
            CustomStudyResult(changes: CollectionChanges(deck: true, studyQueues: true), sessionDeck: .filtered)
        },
        fetchDeckConfigContext: { _ in
            throw PreviewClientError.notImplementedInPreview("fetchDeckConfigContext")
        },
        getDeckConfig: { _ in
            throw PreviewClientError.notImplementedInPreview("getDeckConfig")
        },
        updateDeckConfig: { _, _, _, _, _, _, _ in },
        computeFsrsParams: { _ in
            throw PreviewClientError.notImplementedInPreview("computeFsrsParams")
        },
        simulateFsrsReview: { _ in
            throw PreviewClientError.notImplementedInPreview("simulateFsrsReview")
        },
        simulateFsrsWorkload: { _ in
            throw PreviewClientError.notImplementedInPreview("simulateFsrsWorkload")
        },
        optimizeFsrsPresets: { _, _ in },
        selectDeckPreset: { _, _, _ in },
        createDeckPreset: { _, _, _, _ in },
        deleteDeckPreset: { _, _, _, _ in }
    )
}

/// Thrown by preview-only client implementations when a real backend
/// call would be required to honour the request. Catch and ignore at
/// the call site, or replace the surrounding `previewValue` with a
/// per-preview override via `withDependencies`.
public enum PreviewClientError: Error, CustomStringConvertible {
    case notImplementedInPreview(String)

    public var description: String {
        switch self {
        case .notImplementedInPreview(let what):
            return "PreviewClientError: \(what) is not implemented in previewValue."
        }
    }
}
#endif

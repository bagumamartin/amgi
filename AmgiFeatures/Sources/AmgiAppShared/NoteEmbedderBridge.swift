import AmgiEmbeddings
import Foundation

/// Bridge between Browse's semantic index and the shared MLX engine
/// (TextEmbedder inside the AmgiEmbeddings package — one resident native
/// model instance serves both deck-icon suggestion and card search).
///
/// This indirection exists for one narrow reason: under the current
/// explicit-module build, brand-new source files that `import AmgiEmbeddings`
/// directly can hit a planner quirk reporting the package unresolvable
/// (BrowseSupport 2026-08), while long-standing importers resolve fine.
/// New Browse-layer code should call through here, not import the
/// package itself. Revisit if the toolchain behavior changes.
package enum NoteEmbedderBridge {
    /// nil = embedding engine unavailable (model missing/uncompilable) or
    /// inference failed; callers degrade gracefully.
    package static func embedQuery(_ text: String) async -> [Float]? {
        try? await TextEmbedder.shared.embed(text, prefix: .query)
    }

    package static func embedPassage(_ text: String) async -> [Float]? {
        // Duplicate comparison needs one vector per note. Pool bounded text
        // passages so a long field cannot abort the remaining Browse window.
        // Retrieval itself keeps the individual passage vectors and anchors.
        var pooled = [Float](repeating: 0, count: TextEmbedder.dimensionValue)
        do {
            for passage in MediaIndexer.passages(text) {
                try Task.checkCancellation()
                let vector = try await TextEmbedder.shared.embed(passage, prefix: .passage)
                for i in pooled.indices { pooled[i] += vector[i] * Float(passage.count) }
            }
            let norm = pooled.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
            guard norm.isFinite, norm > 0 else { return nil }
            return pooled.map { $0 / norm }
        } catch { return nil }
    }

    /// Identity of the currently installed embedding model. Persisted vectors
    /// are valid only for this exact version.
    package static var installedModelVersion: Int? {
        ModelAssetManager.installedVersion()
    }

    /// Dot product over L2-normalized vectors = cosine similarity.
    package static func cosine(_ lhs: [Float], _ rhs: [Float]) -> Float {
        TextEmbedder.cosine(lhs, rhs)
    }
}

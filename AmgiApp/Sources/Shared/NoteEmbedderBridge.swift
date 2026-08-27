// AmgiApp/Sources/Shared/NoteEmbedderBridge.swift
import AmgiIcons
import Foundation

/// Bridge between Browse's semantic index and the shared e5 engine
/// (TextEmbedder inside the AmgiIcons package — one resident CoreML
/// model instance serves both deck-icon suggestion and card search).
///
/// This indirection exists for one narrow reason: under the current
/// explicit-module build, brand-new source files that `import AmgiIcons`
/// directly can hit a planner quirk reporting the package unresolvable
/// (BrowseSupport 2026-08), while long-standing importers resolve fine.
/// New Browse-layer code should call through here, not import the
/// package itself. Revisit if the toolchain behavior changes.
enum NoteEmbedderBridge {
    /// nil = embedding engine unavailable (model missing/uncompilable) or
    /// inference failed; callers degrade gracefully.
    static func embedQuery(_ text: String) async -> [Float]? {
        try? await TextEmbedder.shared.embed(text, prefix: .query)
    }

    static func embedPassage(_ text: String) async -> [Float]? {
        try? await TextEmbedder.shared.embed(text, prefix: .passage)
    }

    /// Dot product over L2-normalized vectors = cosine similarity.
    static func cosine(_ lhs: [Float], _ rhs: [Float]) -> Float {
        TextEmbedder.cosine(lhs, rhs)
    }
}

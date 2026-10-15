import CoreGraphics
import Foundation
import PDFKit

/// Width over height of each book's cover as it is actually drawn, so a
/// collection's collage can be laid out around the real shapes instead of
/// cropping them into assumed ones.
///
/// Cheap by construction: image covers are measured from their file headers
/// (no decode) and PDFs from their first page's bounds. Cached per book for
/// the session.
@MainActor
enum CoverAspectResolver {
    /// What a generated placeholder (and anything unmeasurable) is drawn at.
    static let bookAspect: CGFloat = 1 / 1.45

    private static var cache: [String: CGFloat] = [:]

    static func cached(_ bookID: String) -> CGFloat? { cache[bookID] }

    static func aspect(for book: BookCellItem) async -> CGFloat {
        if let hit = cache[book.id] { return hit }
        // Anki covers resolve through a main-actor cache; do that here and
        // hand the detached measurement a plain file URL.
        let source: Source
        switch book.coverArt {
        case .epub(let url):
            source = url.map(Source.image) ?? .fixed(bookAspect)
        case .anki(let path):
            if case .local(let url) = CoverURLCache.shared.resolve(path) {
                source = .image(url)
            } else {
                source = .fixed(bookAspect)
            }
        case .pdf(let coverURL, let documentURL):
            source = .pdf(coverURL: coverURL, documentURL: documentURL)
        case .epubFirstPage:
            // The first-page snapshot is rendered at a fixed 2:3 viewport.
            source = .fixed(2.0 / 3.0)
        case .none:
            source = .fixed(bookAspect)
        }
        let measured = await Task.detached(priority: .utility) { measure(source) }.value
        let aspect = min(max(measured ?? bookAspect, 0.35), 2.6)
        cache[book.id] = aspect
        return aspect
    }

    private enum Source: Sendable {
        case image(URL)
        case pdf(coverURL: URL?, documentURL: URL?)
        case fixed(CGFloat)
    }

    nonisolated private static func measure(_ source: Source) -> CGFloat? {
        switch source {
        case .fixed(let aspect):
            return aspect
        case .image(let url):
            return EPUBCoverImageExtractor.pixelDimensions(of: url).map { $0.width / $0.height }
        case .pdf(let coverURL, let documentURL):
            if let coverURL, let size = EPUBCoverImageExtractor.pixelDimensions(of: coverURL) {
                return size.width / size.height
            }
            guard let documentURL,
                  let page = PDFDocument(url: documentURL)?.page(at: 0) else { return nil }
            // Mirror what PDFCoverThumbnail draws: a long strip shows only its
            // A4-shaped top, everything else the whole (rotated) page.
            let bounds = page.bounds(for: .mediaBox)
            if page.rotation == 0, CoverGeometry.topSlice(forPageBounds: bounds) != nil {
                return 1 / CoverGeometry.a4Aspect
            }
            let size = PDFThumbnailLoader.thumbnailSize(for: page, longEdge: 1000)
            return size.height > 0 ? size.width / size.height : nil
        }
    }
}

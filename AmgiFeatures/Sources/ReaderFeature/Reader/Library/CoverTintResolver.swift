import AmgiUI
import CoreGraphics
import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Finds the tint for a book's Continue card from whatever its cover is
/// actually drawn from, so the card matches the thumbnail beside it.
///
/// Each branch asks the same loader (and so the same cache) the cover view
/// uses, so sampling a cover the card is already showing costs no decode.
@MainActor
enum CoverTintResolver {
    private static var cache: [String: CoverTint] = [:]

    /// The tint already sampled for this book, so a re-created card paints in
    /// its colour on the first frame instead of flashing neutral.
    static func cached(bookID: String) -> CoverTint? { cache[bookID] }

    static func tint(bookID: String, coverArt: CoverArtSource) async -> CoverTint {
        if let hit = cache[bookID] { return hit }
        let tint = await image(for: coverArt).flatMap(CoverTint.init(image:))
            ?? .placeholder(seed: bookID)
        cache[bookID] = tint
        return tint
    }

    private static func image(for coverArt: CoverArtSource) async -> CGImage? {
        switch coverArt {
        case .epub(let url):
            return await fileImage(url)
        case .pdf(let coverURL, let documentURL):
            if let image = await fileImage(coverURL) { return image }
            return await PDFThumbnailLoader.thumbnail(for: documentURL).flatMap(cgImage(of:))
        case .epubFirstPage(let source):
            return await EPUBFirstPageRenderer.snapshot(for: source).flatMap(cgImage(of:))
        case .anki(let path):
            guard case .local(let url) = CoverURLCache.shared.resolve(path) else { return nil }
            return await fileImage(url)
        case .none:
            return nil
        }
    }

    private static func fileImage(_ url: URL?) async -> CGImage? {
        guard let url else { return nil }
        return await DownsampledImageLoader.load(url: url, maxPixelSize: AmgiImagePixelSize.cover)
            .flatMap(cgImage(of:))
    }

    private static func cgImage(of image: PlatformCoverImage) -> CGImage? {
        #if os(macOS)
        image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        #else
        image.cgImage
        #endif
    }
}

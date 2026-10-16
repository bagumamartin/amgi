import PDFKit
import SwiftUI

/// Short-lived page artwork for a single open PDF.
///
/// The cache includes both document identity and rendered size. A page 2 from
/// one book can never be mistaken for page 2 from another, and the small track
/// artwork does not replace the larger selected-page preview.
@MainActor
final class PDFThumbnailCache {
    private var images = NSCache<NSString, PlatformImage>()

    init() {
        images.countLimit = 100
        images.totalCostLimit = 16 * 1024 * 1024
    }

    func get(documentID: UUID, pageIndex: Int, size: CGSize) -> PlatformImage? {
        images.object(forKey: key(documentID: documentID, pageIndex: pageIndex, size: size))
    }

    func set(_ image: PlatformImage, documentID: UUID, pageIndex: Int, size: CGSize) {
        let cost: Int
        #if canImport(UIKit) && !os(macOS)
        cost = (image.cgImage?.bytesPerRow ?? 0) * (image.cgImage?.height ?? 0)
        #else
        cost = Int(size.width * size.height * 4)
        #endif
        images.setObject(
            image,
            forKey: key(documentID: documentID, pageIndex: pageIndex, size: size),
            cost: cost
        )
    }

    func clear() {
        images.removeAllObjects()
    }

    private func key(documentID: UUID, pageIndex: Int, size: CGSize) -> NSString {
        "\(documentID.uuidString):\(pageIndex):\(Int(size.width.rounded()))x\(Int(size.height.rounded()))" as NSString
    }
}

#if canImport(UIKit)
import UIKit

typealias PlatformImage = UIImage

extension Image {
    init(platformImage: UIImage) { self.init(uiImage: platformImage) }
}
#else
import AppKit

typealias PlatformImage = NSImage

extension Image {
    init(platformImage: NSImage) { self.init(nsImage: platformImage) }
}
#endif

/// Renders a page to a thumbnail.
///
/// Split by platform because the two drawing APIs differ in how the context is
/// obtained and in whether the context is flipped — PDF user space has its
/// origin at the bottom left, both graphics contexts at the top left. Getting
/// that transform wrong produces a thumbnail that is correct in size and
/// upside down, which is easy to miss on a page of symmetric text.
enum PDFThumbnailRenderer {
    static func render(page: PDFPage, size: CGSize) -> PlatformImage? {
        // PDFKit preserves the page's aspect ratio, applies its rotation, and
        // includes visible annotations. A hand-built CGContext transform is
        // easy to stretch or clip on landscape and rotated pages.
        page.thumbnail(of: size, for: .mediaBox)
    }
}

/// A rendered thumbnail handed from the render actor to the main actor.
///
/// `UIImage` is immutable once drawn and `NSImage` is only ever read after
/// this point, so crossing the boundary is safe even where the SDK has not
/// marked the image type `Sendable`.
struct PDFRenderedThumbnail: @unchecked Sendable {
    let image: PlatformImage
}

/// Draws thumbnails off the main actor.
///
/// Holds its **own** `PDFDocument`, opened from the same file as the reader's.
/// `PDFDocument` is not thread-safe, and the reader's instance is drawn by
/// `PDFView` on the main thread; sharing it would race. A second instance costs
/// one more parse of the cross-reference table, not a second copy of the pages.
///
/// Being an actor makes rendering serial: a scrub across a 600-page book queues
/// requests, and the ones whose task was cancelled because the finger moved on
/// return before touching PDFKit, so only the latest page actually draws.
///
/// It sees the file as it was when it opened. Annotations added in this
/// session appear in the thumbnails of the next one — a trade made on purpose:
/// a thumbnail is 38 points wide, and keeping it exact would mean drawing from
/// the main-actor document again.
actor PDFPageThumbnailRenderer {
    private let url: URL
    private var document: PDFDocument?
    private var didOpen = false

    init(url: URL) {
        self.url = url
    }

    func render(pageIndex: Int, size: CGSize) -> PDFRenderedThumbnail? {
        guard !Task.isCancelled else { return nil }
        if !didOpen {
            didOpen = true
            document = PDFDocument(url: url)
        }
        guard let page = document?.page(at: pageIndex),
              let image = PDFThumbnailRenderer.render(page: page, size: size) else { return nil }
        return PDFRenderedThumbnail(image: image)
    }
}

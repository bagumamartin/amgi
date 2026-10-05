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

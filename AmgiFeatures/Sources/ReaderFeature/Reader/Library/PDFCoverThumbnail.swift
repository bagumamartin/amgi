import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import PDFKit

#if os(macOS)
typealias PlatformCoverImage = NSImage
#else
typealias PlatformCoverImage = UIImage
#endif

/// First-page thumbnail for a PDF that has no embedded cover.
///
/// Rendered on demand with PDFKit and cached in memory per document URL, so
/// scrolling the library grid does not re-rasterise the same page. When the
/// document cannot be opened, falls through to `placeholder` — the row still
/// renders rather than showing a blank tile.
struct PDFCoverThumbnail<Placeholder: View>: View {
    let documentURL: URL?
    @ViewBuilder let placeholder: () -> Placeholder

    @State private var thumbnail: PlatformCoverImage?

    var body: some View {
        Group {
            if let thumbnail {
                PlatformImageView(image: thumbnail)
            } else {
                placeholder()
            }
        }
        .task(id: documentURL) {
            thumbnail = await PDFThumbnailLoader.thumbnail(for: documentURL)
        }
    }
}

/// Rendering + cache live outside the generic view: a generic type cannot
/// hold static stored properties, and referencing its static members from a
/// detached task would capture the placeholder's metatype.
private enum PDFThumbnailLoader {
    // NSCache is thread-safe; the `unsafe` is only about Swift not knowing that.
    nonisolated(unsafe) private static let cache: NSCache<NSString, PlatformCoverImage> = {
        let cache = NSCache<NSString, PlatformCoverImage>()
        cache.countLimit = 120
        return cache
    }()

    static func thumbnail(for url: URL?) async -> PlatformCoverImage? {
        guard let url else { return nil }
        let key = url.standardizedFileURL.path as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let targetURL = url
        guard let image = await Task.detached(priority: .utility, operation: {
            renderFirstPage(of: targetURL)
        }).value else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    nonisolated static func renderFirstPage(of url: URL) -> PlatformCoverImage? {
        guard let document = PDFDocument(url: url),
              let page = document.page(at: 0) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        // A single long strip (a stitched screenshot, a continuous export)
        // would otherwise shrink to an unreadable sliver: crop its top to an
        // A4-proportioned preview instead.
        if let slice = CoverGeometry.topSlice(forPageBounds: bounds),
           let sliced = renderSlice(of: page, slice: slice) {
            return sliced
        }
        // Ordinary sheets — plus rotated pages and anything the slice path
        // declines — render whole. `thumbnail` is rotation-aware; the manual
        // slice transform is not.
        // 400pt on the long edge: crisp at 3x on a ~130pt grid cell without
        // holding a full-resolution raster per book.
        let target = CGSize(width: 400, height: 545)
        #if os(macOS)
        return page.thumbnail(of: target, for: .mediaBox)
        #else
        let uiImage = page.thumbnail(of: target, for: .mediaBox)
        // A blank (0x0) image means the page had nothing rasterisable;
        // treat it as missing so the placeholder shows instead.
        guard uiImage.size.width > 1, uiImage.size.height > 1 else { return nil }
        return uiImage
        #endif
    }

    /// Renders only `slice` of a page at cover density. Draws the slice
    /// directly (rather than rasterising the whole strip and cropping) so a
    /// very long page never materialises as a giant intermediate image.
    ///
    /// Uses the page's `CGPDFPage` rather than `PDFPage.draw(with:to:)`: the
    /// latter applies its own transform on top of the context's, which
    /// double-flipped the output (upside-down and mirrored). `drawPDFPage`
    /// draws in raw PDF space under the caller's transform only.
    nonisolated static func renderSlice(of page: PDFPage, slice: CGRect) -> PlatformCoverImage? {
        // Rotation is handled by the whole-page path (`thumbnail` accounts
        // for it); the manual transform below assumes an unrotated page.
        guard page.rotation == 0, let cgPage = page.pageRef else { return nil }
        let pixelWidth: CGFloat = 600
        let pixelHeight = pixelWidth * CoverGeometry.a4Aspect
        let width = Int(pixelWidth), height = Int(pixelHeight)
        guard width > 0, height > 0, slice.width > 0, slice.height > 0 else { return nil }
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        // Documents are white pages; a transparent backing would show the
        // cell chrome through instead.
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Map the slice (PDF space, origin bottom-left) onto the target
        // (CG space, origin top-left): slice top-left -> image top-left,
        // slice bottom-right -> image bottom-right. Content outside the
        // slice is clipped by the context bounds.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: CGFloat(width) / slice.width, y: -CGFloat(height) / slice.height)
        context.translateBy(x: -slice.minX, y: -slice.minY)
        context.drawPDFPage(cgPage)
        guard let cgImage = context.makeImage() else { return nil }
        #if os(macOS)
        return NSImage(cgImage: cgImage, size: NSSize(width: pixelWidth, height: pixelHeight))
        #else
        return UIImage(cgImage: cgImage)
        #endif
    }
}

/// Cover-proportion geometry for first-page thumbnails.
enum CoverGeometry {
    /// Height-over-width of an A4 page (√2). Long-strip PDFs are cropped to
    /// a top slice of this proportion.
    static let a4Aspect: CGFloat = 1.41421356
    /// Height-over-width above which a page counts as a continuous strip
    /// rather than a paginated sheet. Ordinary pages (A4 1.41, US Letter
    /// 1.29) render whole; stitched screenshots and continuous exports —
    /// typically 2× and up — get the top-slice treatment.
    static let longPageThreshold: CGFloat = 1.6

    /// The top A4-proportioned slice of a long page, in the page's own
    /// coordinate space — or nil when the page is an ordinary sheet that
    /// should render whole.
    static func topSlice(forPageBounds bounds: CGRect) -> CGRect? {
        guard bounds.width > 0, bounds.height > 0,
              bounds.height / bounds.width > longPageThreshold else {
            return nil
        }
        let sliceHeight = bounds.width * a4Aspect
        guard sliceHeight < bounds.height else { return nil }
        return CGRect(
            x: bounds.minX,
            y: bounds.maxY - sliceHeight,
            width: bounds.width,
            height: sliceHeight
        )
    }
}

#if os(macOS)
private struct PlatformImageView: View {
    let image: NSImage
    var body: some View {
        Image(nsImage: image)
            .resizable()
            .scaledToFit()
    }
}
#else
private struct PlatformImageView: View {
    let image: UIImage
    var body: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
    }
}
#endif

import AmgiReaderPDF
import PDFKit

/// Renders a region of a page to a PNG.
///
/// Render once, crop once. The tempting alternative — render the page and then
/// take a sub-rect of the image — needs the same transform either way and adds
/// a second place for it to be wrong.
enum PDFRegionCapture {
    /// The default capture scale.
    ///
    /// Twice the point size, not once. A crop of a formula or a small table at
    /// 1× is legible on screen and unreadable in Anki's card window, and the
    /// user finds out at review time — after the card is in their collection and
    /// the media file is content-addressed, so re-capturing means a new file.
    static let defaultScale: CGFloat = 2

    /// A PNG of the given page-relative rect, or nil when the page will not draw.
    ///
    /// - Parameters:
    ///   - page: the page to render.
    ///   - rect: the region, normalised to 0...1 of the page box.
    ///
    /// - Returns: PNG bytes, or nil. nil is not an error the caller should
    ///   report: a page that will not draw is a page PDFKit could not open, and
    ///   the card is still worth keeping with its text.
    static func capture(
        page: PDFPage,
        rect: PDFNormalizedRect,
        scale: CGFloat = defaultScale
    ) -> Data? {
        let box = page.bounds(for: .mediaBox)
        guard box.width > 0, box.height > 0 else { return nil }
        // Convert once, here, rather than making every caller normalise: the
        // rect arrives normalised because that is what an anchor stores, and the
        // conversion back to user space is the step that is easy to skip.
        let converted = rect.pdfRect(pageWidth: box.width, pageHeight: box.height)
        let pdfRect = CGRect(
            x: converted.x,
            y: converted.y,
            width: converted.width,
            height: converted.height
        ).intersection(box)
        guard pdfRect.width > 0, pdfRect.height > 0 else { return nil }
        return capture(
            page: page,
            pdfRect: pdfRect,
            pageSize: box.size,
            scale: scale
        )
    }

    /// The capture, with the rect already in PDF user space.
    ///
    /// Separated so the transform can be reasoned about — and tested — without
    /// a live `PDFPage`, which is the half of this that is easy to get wrong.
    ///
    /// The flip is the thing to be careful about. PDF user space has its origin
    /// at the **bottom left** with y increasing upward; a `CGContext` bitmap has
    /// its origin at the **top left** with y increasing downward. Getting that
    /// backwards produces a crop that is the right size, in the right place on
    /// the page, and upside down — which is easy to miss on a symmetric page of
    /// body text and glaring on a diagram.
    static func capture(
        page: PDFPage,
        pdfRect: CGRect,
        pageSize: CGSize,
        scale: CGFloat
    ) -> Data? {
        let scale = max(1, scale)
        let pixelSize = CGSize(
            width: (pdfRect.width * scale).rounded(),
            height: (pdfRect.height * scale).rounded()
        )
        // A crop smaller than a pixel at the requested scale cannot be encoded
        // meaningfully, and asking for zero is a hard failure inside the
        // bitmap context rather than a nil return.
        guard pixelSize.width >= 1, pixelSize.height >= 1 else { return nil }
        guard let context = makeContext(pixelSize: pixelSize) else { return nil }

        context.saveGState()
        defer { context.restoreGState() }
        context.setFillColor(PlatformColor.white.cgColor)
        context.fill(CGRect(origin: .zero, size: pixelSize))
        // Undo the context's top-left origin so the page draws in its own
        // bottom-left space, then scale into the bitmap.
        context.translateBy(x: 0, y: pixelSize.height)
        context.scaleBy(x: scale, y: -scale)
        // Move the page so the region is at the origin. Without this the page is
        // drawn at its own origin and the crop lands off-image — a nil-looking
        // white rectangle rather than a wrong-but-plausible crop.
        context.translateBy(x: -pdfRect.minX, y: -pdfRect.minY)
        page.draw(with: .mediaBox, to: context)
        context.restoreGState()

        return makeImage(context: context, pixelSize: pixelSize)
    }

    #if canImport(UIKit) && !os(macOS)
    private static func makeContext(pixelSize: CGSize) -> CGContext? {
        // `bitmapInfo` and `bytesPerRow` are 0 for a device RGB context, which
        // is the one that handles the colour space correctly for page content
        // that includes images with an embedded profile.
        UIGraphicsBeginImageContextWithOptions(pixelSize, true, 1)
        return UIGraphicsGetCurrentContext()
    }

    private static func makeImage(context: CGContext, pixelSize: CGSize) -> Data? {
        UIGraphicsEndImageContext()
        guard let image = UIGraphicsGetImageFromCurrentImageContext() else { return nil }
        return image.pngData()
    }
    #else
    private static func makeContext(pixelSize: CGSize) -> CGContext? {
        guard let context = CGContext(
            data: nil,
            width: Int(pixelSize.width),
            height: Int(pixelSize.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        return context
    }

    private static func makeImage(context: CGContext, pixelSize: CGSize) -> Data? {
        guard let image = context.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .png, properties: [:])
    }
    #endif
}

extension PDFRegionCapture {
    /// A rect in PDF user space, clamped to the page.
    ///
    /// Clamping here rather than trusting the caller, because an unclamped rect
    /// that overhangs the page produces a bitmap bigger than the page with
    /// transparent margins — a file that looks right and is not the crop the
    /// user drew.
    static func normalizedRect(from rect: CGRect, on page: PDFPage) -> PDFNormalizedRect? {
        let box = page.bounds(for: .mediaBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let clipped = rect.intersection(box)
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return nil }
        return PDFNormalizedRect(
            pdfRect: PDFRect(
                x: clipped.origin.x,
                y: clipped.origin.y,
                width: clipped.width,
                height: clipped.height
            ),
            pageWidth: box.width,
            pageHeight: box.height
        )
    }
}

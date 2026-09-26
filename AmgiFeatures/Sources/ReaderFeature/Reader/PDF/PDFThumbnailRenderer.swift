import PDFKit
import SwiftUI

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
    /// The size a sidebar thumbnail is rendered at.
    ///
    /// Twice the cell's width, which is the usual rule: at one-to-one a
    /// downscaled screenshot is visibly soft, and at full page resolution a
    /// 900-page document costs hundreds of megabytes for a list the user may
    /// never scroll.
    static let size = CGSize(width: 200, height: 260)

    static func render(page: PDFPage) -> PlatformImage? {
        #if canImport(UIKit) && !os(macOS)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { context in
            let cgContext = context.cgContext
            cgContext.setFillColor(PlatformColor.white.cgColor)
            cgContext.fill(CGRect(origin: .zero, size: size))
            cgContext.translateBy(x: 0, y: size.height)
            cgContext.scaleBy(x: 1, y: -1)
            page.draw(with: .mediaBox, to: cgContext)
        }
        #else
        let image = PlatformImage(size: NSSize(width: size.width, height: size.height))
        image.lockFocus()
        defer { image.unlockFocus() }
        guard let cgContext = NSGraphicsContext.current?.cgContext else { return nil }
        cgContext.setFillColor(PlatformColor.white.cgColor)
        cgContext.fill(CGRect(origin: .zero, size: size))
        cgContext.translateBy(x: 0, y: size.height)
        cgContext.scaleBy(x: 1, y: -1)
        page.draw(with: .mediaBox, to: cgContext)
        return image
        #endif
    }
}

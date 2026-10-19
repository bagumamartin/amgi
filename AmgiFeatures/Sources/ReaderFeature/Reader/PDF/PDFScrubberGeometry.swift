import CoreGraphics
import Foundation

/// The arithmetic of the PDF page strip, kept apart from the view so it can be
/// tested without a window.
///
/// The strip maps the whole document linearly onto its width minus an inset
/// at each end. The finger's x picks a page, and a page's x places the raised
/// selected thumbnail — the same mapping both ways, so the thumbnail sits under
/// the finger.
enum PDFScrubberGeometry {
    /// The page under `x`, clamped to the document.
    static func pageIndex(atX x: CGFloat, width: CGFloat, inset: CGFloat, pageCount: Int) -> Int {
        guard pageCount > 1 else { return 0 }
        let usable = max(1, width - inset * 2)
        let fraction = min(max((x - inset) / usable, 0), 1)
        return Int((fraction * CGFloat(pageCount - 1)).rounded())
    }

    /// The x a page maps to on the track, before any clamping.
    static func centerX(forPage page: Int, width: CGFloat, inset: CGFloat, pageCount: Int) -> CGFloat {
        guard pageCount > 1 else { return width / 2 }
        let clamped = min(max(page, 0), pageCount - 1)
        let fraction = CGFloat(clamped) / CGFloat(pageCount - 1)
        return inset + fraction * (width - inset * 2)
    }

    /// `x` moved inward just far enough that a tile of `tileSize`, vertically
    /// centred in a capsule of `stripWidth` × `stripHeight`, lies wholly inside
    /// the capsule's rounded ends with `margin` to spare.
    ///
    /// The ends are semicircles of radius `stripHeight / 2`. A tile's outer
    /// corners are what touch the curve first, at half the tile's height from
    /// the axis, where the curve is `r − √(r² − (h/2)²)` in from the strip's
    /// end. Without this the first and last page's thumbnail is centred on the
    /// track's end and half of it hangs outside the strip.
    static func clampedCenterX(
        _ x: CGFloat,
        stripWidth: CGFloat,
        stripHeight: CGFloat,
        tileSize: CGSize,
        margin: CGFloat
    ) -> CGFloat {
        let radius = stripHeight / 2
        let halfHeight = min(tileSize.height / 2, radius)
        let curveInset = radius - (radius * radius - halfHeight * halfHeight).squareRoot()
        let lowest = curveInset + margin + tileSize.width / 2
        let highest = stripWidth - lowest
        guard lowest <= highest else { return stripWidth / 2 }
        return min(max(x, lowest), highest)
    }

    /// Centre-to-centre distance between two sample tiles.
    static let samplePitch: CGFloat = 22

    /// The strip's own width: the whole of `availableWidth` when the document
    /// has more pages than fit, otherwise just enough for one tile per page.
    ///
    /// A short document used to get a full-width capsule with its few tiles
    /// bunched in the middle, while the raised tile and the finger still
    /// mapped across the whole width — so the selected page sat away from its
    /// own tile. Hugging the pages keeps the strip and the mapping in step.
    static func stripWidth(
        pageCount: Int,
        availableWidth: CGFloat,
        inset: CGFloat,
        minimumWidth: CGFloat
    ) -> CGFloat {
        let fitted = inset * 2 + CGFloat(max(0, pageCount - 1)) * samplePitch
        return min(availableWidth, max(fitted, minimumWidth))
    }

    /// Evenly spaced representative pages for a strip of `availableWidth`,
    /// always including the first and last page.
    static func sampledPageIndices(pageCount: Int, availableWidth: CGFloat) -> [Int] {
        guard pageCount > 0 else { return [] }
        let desiredCount = max(1, min(80, Int(availableWidth / samplePitch) + 1))
        let sampleCount = min(pageCount, desiredCount)
        guard sampleCount > 1 else { return [0] }
        return (0..<sampleCount).map { sample in
            Int((Double(sample) * Double(pageCount - 1) / Double(sampleCount - 1)).rounded())
        }
    }

    /// The sample nearest `page`, for showing *something* in the selected tile
    /// while the exact page is still drawing.
    static func nearestSample(to page: Int, in samples: [Int]) -> Int? {
        samples.min { abs($0 - page) < abs($1 - page) }
    }
}

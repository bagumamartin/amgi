import CoreGraphics
import Foundation
import Testing
@testable import ReaderFeature

/// Cover-thumbnail geometry: ordinary sheets render whole, continuous strips
/// get an A4-proportioned top slice.
@Suite("Cover geometry")
struct CoverGeometryTests {
    @Test("ordinary pages render whole")
    func ordinaryPagesRenderWhole() {
        // A4, US Letter, and square-ish pages are not long strips.
        #expect(CoverGeometry.topSlice(forPageBounds: CGRect(x: 0, y: 0, width: 595, height: 842)) == nil)
        #expect(CoverGeometry.topSlice(forPageBounds: CGRect(x: 0, y: 0, width: 612, height: 792)) == nil)
        #expect(CoverGeometry.topSlice(forPageBounds: CGRect(x: 0, y: 0, width: 500, height: 500)) == nil)
    }

    @Test("a long strip crops to its A4-proportioned top")
    func longStripCropsTop() {
        let slice = CoverGeometry.topSlice(forPageBounds: CGRect(x: 0, y: 0, width: 600, height: 2400))
        let expected = CGRect(
            x: 0,
            y: 2400 - 600 * CoverGeometry.a4Aspect,
            width: 600,
            height: 600 * CoverGeometry.a4Aspect
        )
        #expect(slice != nil)
        #expect(abs((slice?.height ?? 0) / (slice?.width ?? 1) - CoverGeometry.a4Aspect) < 0.001)
        #expect(slice?.minY == expected.minY)
        // The slice is the top of the page, not the middle or bottom.
        #expect(slice?.maxY == 2400)
    }

    @Test("the crop respects non-zero page origins")
    func cropRespectsPageOrigin() {
        let slice = CoverGeometry.topSlice(forPageBounds: CGRect(x: 10, y: 20, width: 600, height: 2400))
        #expect(slice?.minX == 10)
        #expect(slice?.maxY == 2420)
    }

    @Test("degenerate bounds render nothing")
    func degenerateBoundsRenderNothing() {
        #expect(CoverGeometry.topSlice(forPageBounds: .zero) == nil)
        #expect(CoverGeometry.topSlice(forPageBounds: CGRect(x: 0, y: 0, width: 0, height: 2400)) == nil)
    }
}

import CoreGraphics
import Testing
@testable import ReaderFeature

/// The collection collage never crops: every cover keeps its own shape and
/// sits inside the space without overlapping another, no cover shrinks to a
/// sliver, and ordinary books get Apple's feature-plus-columns look while
/// wide covers get rows.
@Suite("Collection mosaic")
struct CollectionMosaicTests {
    private let space = CGSize(width: 156, height: 186)
    private let gap: CGFloat = 8

    @discardableResult
    private func check(_ aspects: [CGFloat]) -> CollectionMosaic.Arrangement {
        guard let arrangement = CollectionMosaic.layout(aspects: aspects, in: space, gap: gap) else {
            Issue.record("no arrangement for \(aspects)")
            return .init(frames: [], size: .zero)
        }
        #expect(arrangement.size.width <= space.width + 0.5)
        #expect(arrangement.size.height <= space.height + 0.5)
        for (frame, aspect) in zip(arrangement.frames, aspects) {
            // Whole cover, own shape.
            #expect(abs(frame.width / frame.height - aspect) < 0.001)
            #expect(frame.minX >= -0.5 && frame.maxX <= arrangement.size.width + 0.5)
            #expect(frame.minY >= -0.5 && frame.maxY <= arrangement.size.height + 0.5)
            #expect(frame.height >= space.height * 0.24 - 0.5 || arrangement.frames.count == 1)
        }
        for (i, a) in arrangement.frames.enumerated() {
            for b in arrangement.frames.dropFirst(i + 1) {
                #expect(a.insetBy(dx: 0.5, dy: 0.5).intersection(b.insetBy(dx: 0.5, dy: 0.5)).isNull)
            }
        }
        return arrangement
    }

    @Test("ordinary books get a large feature cover with smaller ones beside it")
    func booksGetFeatureLayout() {
        let arrangement = check([0.67, 0.67, 0.67, 0.67, 0.67])
        let heights = arrangement.frames.map(\.height)
        #expect(arrangement.frames.count >= 3)
        #expect(heights[0] > heights[1] * 1.5)
    }

    @Test("wide slides go in rows rather than a feature")
    func slidesGetRows() {
        let arrangement = check([1.33, 1.78, 1.33])
        #expect(arrangement.frames.count == 3)
        // No cover is the full-height feature.
        #expect(arrangement.frames.allSatisfy { $0.height < arrangement.size.height - 0.5 })
    }

    @Test("mixed shapes all fit whole")
    func mixedShapes() {
        check([0.69, 1.78, 1.33, 0.71, 1.0, 0.5])
        check([3, 3, 3, 0.5, 0.5, 0.5])
    }

    @Test("one cover is shown whole and as large as fits")
    func single() {
        let frame = check([0.69]).frames[0]
        #expect(abs(frame.height - space.height) < 0.5 || abs(frame.width - space.width) < 0.5)
    }

    @Test("nothing to lay out gives nothing")
    func empty() {
        #expect(CollectionMosaic.layout(aspects: [], in: space, gap: gap) == nil)
        #expect(CollectionMosaic.layout(aspects: [1], in: .zero, gap: gap) == nil)
    }
}

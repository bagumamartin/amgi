import CoreGraphics
import Testing
@testable import AmgiUI

@Suite("Responsive deck detail layout")
struct ResponsiveDeckDetailLayoutTests {
    @Test("narrow detail keeps the readable single column")
    func narrowDetail() {
        #expect(
            DeckDetailLayout.resolve(
                availableWidth: DeckDetailLayout.minimumWideWidth - 1
            ) == .narrow
        )
    }

    @Test("wide detail activates the primary and secondary columns")
    func wideDetail() {
        #expect(
            DeckDetailLayout.resolve(
                availableWidth: DeckDetailLayout.minimumWideWidth
            ) == .wide
        )
    }

    @Test("accessibility Dynamic Type keeps the detail single-column")
    func accessibilityDetail() {
        #expect(
            DeckDetailLayout.resolve(
                availableWidth: 1_200,
                isAccessibilitySize: true
            ) == .narrow
        )
    }
}

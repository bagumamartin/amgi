import CoreGraphics
import Testing
@testable import AmgiUI

@Suite("Responsive Study layout")
struct ResponsiveStudyLayoutTests {
    @Test("compact width keeps the phone composition")
    func compactWidth() {
        #expect(
            StudyContentLayout.resolve(
                availableWidth: StudyContentLayout.minimumRegularWidth - 1,
                isAccessibilitySize: false
            ) == .compact
        )
    }

    @Test("regular width supports a readable single-column study desk")
    func regularWidth() {
        #expect(
            StudyContentLayout.resolve(
                availableWidth: StudyContentLayout.minimumRegularWidth,
                isAccessibilitySize: false
            ) == .regular
        )
    }

    @Test("wide width activates the two-column desk")
    func wideWidth() {
        #expect(
            StudyContentLayout.resolve(
                availableWidth: StudyContentLayout.minimumWideWidth,
                isAccessibilitySize: false
            ) == .wide
        )
    }

    @Test("accessibility Dynamic Type collapses the wide grid")
    func accessibilitySizeCollapsesWideGrid() {
        #expect(
            StudyContentLayout.resolve(
                availableWidth: StudyContentLayout.minimumWideWidth,
                isAccessibilitySize: true
            ) == .compact
        )
    }

    @Test("narrow wide desks use compact metrics without dropping columns")
    func mediumWidePresentation() {
        #expect(
            StudyDashboardPresentation.resolveWideLayout(
                availableWidth: StudyContentLayout.minimumWideWidth
            ) == .medium
        )
        #expect(
            StudyDashboardPresentation.resolveWideLayout(
                availableWidth: StudyDashboardPresentation.mediumWideMaximumWidth
            ) == .wide
        )
    }
}

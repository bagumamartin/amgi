import CoreFoundation
import Testing
@testable import AmgiUI

@Suite("Responsive Library layout")
struct ResponsiveLibraryLayoutTests {
    @Test("compact always stays on the native list")
    func compactNeverUsesWideOverview() {
        #expect(LibraryContentLayout.resolve(isRegularWidth: false, availableWidth: 1_400) == .compactList)
    }

    @Test("regular width uses one column until both cards genuinely fit")
    func regularRespectsAvailableWidth() {
        #expect(
            LibraryContentLayout.resolve(
                isRegularWidth: true,
                availableWidth: LibraryContentLayout.minimumWideWidth - 1
            ) == .regularNarrow
        )
        #expect(
            LibraryContentLayout.resolve(
                isRegularWidth: true,
                availableWidth: LibraryContentLayout.minimumWideWidth
            ) == .regularWide
        )
    }

    @Test("the wide threshold is derived from two readable columns")
    func wideThresholdTracksColumnRequirements() {
        #expect(
            LibraryContentLayout.minimumWideWidth
                == LibraryContentLayout.minimumColumnWidth * 2
                    + LibraryContentLayout.columnSpacing
                    + LibraryContentLayout.horizontalPadding
        )
    }
}

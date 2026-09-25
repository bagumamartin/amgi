import CoreFoundation
import Testing
@testable import DecksFeature

@Suite("Responsive deck options")
struct ResponsiveDeckEditorTests {
    @Test("compact keeps the original single Form")
    func compactUsesForm() {
        #expect(
            DeckConfigLayout.resolve(
                isRegularWidth: false,
                availableWidth: DeckConfigLayout.minimumWidth + 400
            ) == .compactForm
        )
    }

    @Test("regular width uses category/settings/summary only when all columns fit")
    func regularRespectsAvailableWidth() {
        #expect(
            DeckConfigLayout.resolve(
                isRegularWidth: true,
                availableWidth: DeckConfigLayout.minimumWidth - 1
            ) == .compactForm
        )
        #expect(
            DeckConfigLayout.resolve(
                isRegularWidth: true,
                availableWidth: DeckConfigLayout.minimumWidth
            ) == .splitEditor
        )
    }

    @Test("the split-width minimum is derived from its three panes")
    func splitThresholdTracksPaneRequirements() {
        #expect(
            DeckConfigLayout.minimumWidth
                == DeckConfigLayout.categoryWidth
                    + DeckConfigLayout.settingsMinimumWidth
                    + DeckConfigLayout.summaryWidth
        )
    }

    @Test("category navigation is stable and complete")
    func categoryNavigation() {
        #expect(DeckConfigCategory.allCases.map(\.id) == ["preset", "scheduling", "reviewFlow", "advanced"])
        #expect(Set(DeckConfigCategory.allCases.map(\.title)).count == DeckConfigCategory.allCases.count)
    }
}

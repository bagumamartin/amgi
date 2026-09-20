import AnkiKit
import Testing
@testable import BrowseFeature

@Suite("Browse multi-select state")
struct BrowseSelectionTests {

    @Test func initialStateIsInactive() {
        let s = BrowseSelectionState()
        #expect(s.isSelectMode == false)
        #expect(s.isEmpty)
        #expect(s.count == 0)
        #expect(!s.showsBatchActions)
    }

    @Test func enterSelectModePreselectsRow() {
        var s = BrowseSelectionState()
        s.enterSelectMode(preselect: NoteID(42))
        #expect(s.isSelectMode)
        #expect(s.contains(NoteID(42)))
        #expect(s.count == 1)
        #expect(s.showsBatchActions)
    }

    @Test func enterSelectModeWithoutPreselectIsEmpty() {
        var s = BrowseSelectionState()
        s.enterSelectMode()
        #expect(s.isSelectMode)
        #expect(s.isEmpty)
        #expect(s.showsBatchActions)
    }

    @Test func clearSelectionKeepsMode() {
        var s = BrowseSelectionState()
        s.enterSelectMode(preselect: NoteID(1))
        s.clearSelectionKeepingMode()
        #expect(s.isSelectMode)
        #expect(s.isEmpty)
        #expect(s.showsBatchActions)
    }

    @Test func toggleAddsThenRemoves() {
        var s = BrowseSelectionState()
        s.enterSelectMode()
        s.toggle(NoteID(7))
        #expect(s.contains(NoteID(7)))
        s.toggle(NoteID(7))
        #expect(!s.contains(NoteID(7)))
    }

    @Test func exitClearsEverything() {
        var s = BrowseSelectionState()
        s.enterSelectMode(preselect: NoteID(1))
        s.toggle(NoteID(2))
        s.toggle(NoteID(3))
        s.exitSelectMode()
        #expect(!s.isSelectMode)
        #expect(s.isEmpty)
    }
}

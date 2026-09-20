import Testing
@testable import BrowseFeature

@Suite("Note row subtitle composition")
struct BrowseSubtitleTests {

    @Test func bothPresent() {
        #expect(composeNoteSubtitle(notetypeName: "Basic", tags: "math") == "Basic · math")
    }

    @Test func hierarchicalTagsUseHumanReadableLeafNames() {
        #expect(
            composeNoteSubtitle(
                notetypeName: "Basic",
                tags: "pharmchem::final pharmchem::second-topic marked"
            ) == "Basic · final · second topic"
        )
    }

    @Test func notetypeOnlyWhenTagsBlank() {
        #expect(composeNoteSubtitle(notetypeName: "Basic", tags: "  ") == "Basic")
    }

    @Test func tagsOnlyWhenNoNotetype() {
        #expect(composeNoteSubtitle(notetypeName: nil, tags: "math science") == "math science")
    }

    @Test func nilWhenBothEmpty() {
        #expect(composeNoteSubtitle(notetypeName: nil, tags: "") == nil)
    }
}

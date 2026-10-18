import AnkiKit
import Testing
@testable import BrowseFeature

@Suite("Note checker")
struct NoteCheckerTests {
    private let basic = NotetypeID(1)
    private let cloze = NotetypeID(2)

    private func note(_ id: Int64, _ fields: [String], type: NotetypeID? = nil) -> NoteRecord {
        NoteRecord(
            id: NoteID(id), guid: "g\(id)", mid: type ?? basic, mod: 0,
            flds: fields.joined(separator: "\u{1f}"), sfld: fields.first ?? "", csum: 0
        )
    }

    private func check(_ notes: [NoteRecord], media: Set<String> = []) -> [NoteCheckIssue: [NoteID]] {
        NoteChecker.check(notes, clozeNotetypes: [cloze]) { media.contains($0) }
    }

    @Test func flagsEmptyFrontButNotPictureOnlyFront() {
        let found = check([
            note(1, ["<br>", "back"]),
            note(2, [#"<img src="a.png">"#, "back"]),
        ], media: ["a.png"])
        #expect(found[.emptyFront] == [NoteID(1)])
    }

    @Test func clozeWithoutDeletionAndUnclosedCloze() {
        let found = check([
            note(1, ["No deletion here", ""], type: cloze),
            note(2, ["{{c1::open never closes", ""], type: cloze),
            note(3, ["{{c1::fine}}", ""], type: cloze),
        ])
        #expect(found[.missingCloze] == [NoteID(1)])
        #expect(found[.brokenCloze] == [NoteID(2)])
    }

    @Test func duplicateFrontsIgnoreCaseAndMarkup() {
        let found = check([
            note(1, ["<b>Liver</b>", "a"]),
            note(2, ["liver", "b"]),
            note(3, ["Kidney", "c"]),
        ])
        #expect(Set(found[.duplicateFront] ?? []) == [NoteID(1), NoteID(2)])
    }

    @Test func missingMediaSkipsRemoteImages() {
        let found = check([
            note(1, [#"Q <img src="gone.png">"#, "[sound:here.mp3]"]),
            note(2, [#"Q <img src="https://example.com/x.png">"#, "A"]),
        ], media: ["here.mp3"])
        #expect(found[.missingMedia] == [NoteID(1)])
    }

    @Test func longAnswerOverLimit() {
        let long = String(repeating: "word ", count: NoteChecker.longAnswerLimit / 4)
        let found = check([note(1, ["Q", long]), note(2, ["Q2", "short"])])
        #expect(found[.longAnswer] == [NoteID(1)])
    }
}

@Suite("Search completions")
struct SearchCompletionsTests {
    private func note(_ id: Int64, _ text: String) -> NoteRecord {
        NoteRecord(id: NoteID(id), guid: "g\(id)", mid: NotetypeID(1), mod: 0, flds: text, sfld: text, csum: 0)
    }

    private var index: SearchCompletions.Index {
        SearchCompletions.Index(records: [
            note(1, "Liver cirrhosis is scarring"),
            note(2, "Liver cirrhosis causes"),
            note(3, "Liver function tests"),
            note(4, "Living organisms"),
        ])
    }

    @Test func completesTheWordBeingTypedByNoteCount() {
        let completions = SearchCompletions.complete("liv", index: index)
        #expect(completions.first == "liver")
        #expect(completions.contains("living"))
    }

    @Test func offersPhrasesBackedByTwoNotes() {
        let completions = SearchCompletions.complete("liv", index: index)
        #expect(completions.contains("liver cirrhosis"))
        #expect(!completions.contains("liver function"))
    }

    @Test func keepsEarlierWordsOfTheQuery() {
        #expect(SearchCompletions.complete("chronic liv", index: index).first == "chronic liver")
    }

    @Test func nothingForOneLetterOrGrammar() {
        #expect(SearchCompletions.complete("l", index: index).isEmpty)
        #expect(SearchCompletions.complete("tag:liv", index: index).isEmpty)
    }
}

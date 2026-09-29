import AmgiReader
import AnkiClients
import AnkiKit
import Foundation
import Testing

@Suite("ReaderLookupNoteTemplate")
struct ReaderLookupNoteTemplateTests {

    @Test("definitionsByDictionary preserves order and merges duplicates")
    func definitionsByDictionaryPreservesOrder() {
        let glossaries = [
            DictionaryLookupGlossary(dictionary: "DictA", definitions: ["A1", "A2"]),
            DictionaryLookupGlossary(dictionary: "DictB", definitions: ["B1"]),
            DictionaryLookupGlossary(dictionary: "DictA", definitions: ["A3"]),
        ]
        #expect(
            ReaderLookupNotePayload.definitionsByDictionary(from: glossaries)
                == ["A1\nA2\nA3", "B1"]
        )
    }

    @Test("makeDraft maps def1/def2/def3 from per-dictionary groups")
    func makeDraftAssignsDefinitionsToMappedFields() {
        let payload = ReaderLookupNotePayload(
            term: "単語",
            reading: "たんご",
            sentence: "Example sentence",
            definitions: ["dict1-def1\ndict1-def2", "dict2-def1", "dict3-def1"]
        )
        let template = ReaderLookupNoteTemplate(
            definition1Field: "Def1",
            definition2Field: "Def2",
            definition3Field: "Def3"
        )

        let draft = template.makeDraft(
            payload: payload,
            fallbackDeckID: nil,
            sourceDescription: "Source"
        )

        #expect(draft.fieldValues["Def1"] == "dict1-def1\ndict1-def2")
        #expect(draft.fieldValues["Def2"] == "dict2-def1")
        #expect(draft.fieldValues["Def3"] == "dict3-def1")
    }

    @Test("Empty template falls back to common Basic-notetype names")
    func emptyTemplateFallsBackToBasicNames() {
        let payload = ReaderLookupNotePayload(term: "term", sentence: "sentence")
        let template = ReaderLookupNoteTemplate.empty

        let draft = template.makeDraft(
            payload: payload,
            fallbackDeckID: 42,
            sourceDescription: "src"
        )

        #expect(draft.fieldValues["Front"] == "term")
        #expect(draft.fieldValues["Sentence"] == "sentence")
        #expect(draft.deckID == 42)
    }

    @Test("clearInvalidFields drops orphan field names after notetype change")
    func clearInvalidFieldsDropsOrphans() {
        var template = ReaderLookupNoteTemplate(
            termField: "Front",
            readingField: "Reading",
            sentenceField: "GoneField"
        )
        template.clearInvalidFields(validFields: ["Front", "Reading", "Back"])

        #expect(template.termField == "Front")
        #expect(template.readingField == "Reading")
        #expect(template.sentenceField == "")
    }

    @Test("encode/decode round-trips field mappings")
    func encodeDecodeRoundTrip() {
        let original = ReaderLookupNoteTemplate(
            deckID: 1,
            notetypeID: 2,
            termField: "Front",
            definition1Field: "Back"
        )
        let restored = ReaderLookupNoteTemplate.decode(from: original.encodedString())
        #expect(restored == original)
    }

    // MARK: - Source anchor

    /// Built once so a round-trip comparison is against the same value —
    /// `ReaderSourceAnchor` stamps `createdAt` on creation.
    private static let sampleAnchor = ReaderSourceAnchor(
        bookID: "epub-abc",
        chapterID: 7,
        chapterHref: "OEBPS/Text/ch3.xhtml",
        cfi: 1_024,
        path: [1, 0, 3],
        quote: "an anchored sentence"
    )

    @Test("a mapped anchor field receives the encoded anchor")
    func anchorFieldReceivesEncodedAnchor() throws {
        let payload = ReaderLookupNotePayload(
            term: "word",
            sentence: "an anchored sentence",
            sourceAnchor: Self.sampleAnchor
        )
        let template = ReaderLookupNoteTemplate(
            termField: "Front",
            sentenceField: "Sentence",
            anchorField: "SourceAnchor"
        )

        let draft = template.makeDraft(
            payload: payload,
            fallbackDeckID: nil,
            sourceDescription: "src"
        )

        let json = try #require(draft.fieldValues["SourceAnchor"])
        // Stored as JSON so a later feature can re-open the note at its source
        // rather than pattern-matching the sentence text.
        let decoded = try JSONDecoder().decode(
            ReaderSourceAnchor.self,
            from: Data(json.utf8)
        )
        #expect(decoded == Self.sampleAnchor)
    }

    @Test("an unmapped anchor field leaves no value behind")
    func unmappedAnchorFieldIsOmitted() {
        // The default template has no anchor field, so existing users must not
        // get a JSON blob dropped into a field they never mapped.
        let payload = ReaderLookupNotePayload(
            term: "word",
            sentence: "an anchored sentence",
            sourceAnchor: Self.sampleAnchor
        )
        let draft = ReaderLookupNoteTemplate(
            termField: "Front",
            sentenceField: "Sentence"
        ).makeDraft(
            payload: payload,
            fallbackDeckID: nil,
            sourceDescription: "src"
        )
        #expect(draft.fieldValues.keys.sorted() == ["Front", "Sentence"])
    }

    @Test("a payload with no anchor does not populate the anchor field")
    func nilAnchorIsOmitted() {
        let payload = ReaderLookupNotePayload(
            term: "word",
            sentence: "from a plain selection"
        )
        let template = ReaderLookupNoteTemplate(
            termField: "Front",
            anchorField: "SourceAnchor"
        )
        let draft = template.makeDraft(
            payload: payload,
            fallbackDeckID: nil,
            sourceDescription: "src"
        )
        #expect(draft.fieldValues["SourceAnchor"] == nil)
    }

    @Test("an anchor mapped onto an already-claimed field does not overwrite it")
    func anchorDoesNotOverwriteAnotherMapping() {
        // "Source" is also one of the names the unmapped fallback uses, so a
        // user can easily map both sourceField and anchorField there. The
        // first writer must win, or the dictionary source is lost to JSON.
        let payload = ReaderLookupNotePayload(
            term: "word",
            sentence: "an anchored sentence",
            source: "JMdict",
            sourceAnchor: Self.sampleAnchor
        )
        let template = ReaderLookupNoteTemplate(
            termField: "Front",
            sourceField: "Source",
            anchorField: "Source"
        )
        let draft = template.makeDraft(
            payload: payload,
            fallbackDeckID: nil,
            sourceDescription: "src"
        )
        #expect(draft.fieldValues["Source"] == "JMdict")
    }

    @Test("an orphan anchor field is dropped after a notetype change")
    func clearInvalidFieldsDropsOrphanAnchorField() {
        var template = ReaderLookupNoteTemplate(
            termField: "Front",
            anchorField: "Removed"
        )
        template.clearInvalidFields(validFields: ["Front", "Back"])
        #expect(template.anchorField == "")
    }

    @Test("the anchor field round-trips through encoding")
    func anchorFieldRoundTrips() {
        let original = ReaderLookupNoteTemplate(
            termField: "Front",
            anchorField: "SourceAnchor"
        )
        let restored = ReaderLookupNoteTemplate.decode(from: original.encodedString())
        #expect(restored == original)
    }
}

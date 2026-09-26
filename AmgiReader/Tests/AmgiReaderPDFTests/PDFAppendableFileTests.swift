import Foundation
import Testing
@testable import AmgiReaderPDF

/// The load, append, and merge path — the machinery that makes concurrent
/// annotation safe without losing Preview compatibility.
@Suite("PDF appendable file")
struct PDFAppendableFileTests {
    @Test("a classic-table document loads with its page tree intact")
    func loadsClassicDocument() throws {
        let file = try PDFAppendableFile(bytes: PDFFixture.classicDocument())
        #expect(file.pages.count == 1)
        #expect(file.catalog?["Type"]?.asName == "Catalog")
        let page = try #require(file.pages.first)
        #expect(page.dictionary["Type"]?.asName == "Page")
        #expect(page.mediaBox?.width == 612)
        #expect(page.mediaBox?.height == 792)
    }

    @Test("pages come back in reading order")
    func pagesInReadingOrder() throws {
        let file = try PDFAppendableFile(bytes: PDFFixture.twoPageDocument())
        #expect(file.pages.count == 2)
        // Order is what "page 12" means, so a document that lists its kids in
        // order must be read that way.
        let contents: [String] = file.pages.compactMap { page in
            guard let number = page.dictionary["Contents"]?.asReference?.number,
                  case .stream(let stream)? = file.object(number: number)
            else { return nil }
            return String(decoding: stream.rawBytes, as: UTF8.self)
        }
        #expect(contents.count == 2)
        #expect(contents[0].contains("Page one"))
        #expect(contents[1].contains("Page two"))
    }

    @Test("a stream object keeps its bytes verbatim")
    func streamBytesPreserved() throws {
        let file = try PDFAppendableFile(bytes: PDFFixture.classicDocument())
        let page = try #require(file.pages.first)
        let contentReference = try #require(page.dictionary["Contents"]?.asReference)
        guard case .stream(let stream)? = file.object(number: contentReference.number) else {
            Issue.record("expected a content stream")
            return
        }
        // A rewrite that re-encoded stream bytes would corrupt page content,
        // so they are carried through untouched.
        #expect(String(decoding: stream.rawBytes, as: UTF8.self).contains("Test Document"))
    }

    @Test("a document with damaged cross-references is recovered by scanning")
    func recoversBrokenXref() throws {
        // Common enough in the wild that refusing to annotate these would
        // exclude a large share of real files.
        let file = try PDFAppendableFile(bytes: PDFFixture.documentWithBrokenXref())
        #expect(file.pages.count == 1)
        #expect(file.catalog?["Type"]?.asName == "Catalog")
    }

    @Test("an encrypted document is refused rather than corrupted")
    func refusesEncrypted() {
        // Writing an update to an encrypted document would leave its strings
        // and streams in the clear while claiming they were encrypted, which
        // produces a file that looks fine here and is broken everywhere else.
        #expect(throws: PDFAppendableFile.LoadError.encrypted) {
            try PDFAppendableFile(bytes: PDFFixture.encryptedDocument())
        }
    }

    @Test("a non-PDF is refused")
    func refusesNonPDF() {
        #expect(throws: PDFAppendableFile.LoadError.notAPDF) {
            try PDFAppendableFile(bytes: Array("this is not a pdf at all".utf8))
        }
        #expect(throws: PDFAppendableFile.LoadError.unreadable) {
            try PDFAppendableFile(bytes: [])
        }
    }

    @Test("a document with a compressed cross-reference stream loads")
    func loadsXrefStreamDocument() throws {
        // PDF 1.5 and later producers emit a cross-reference *stream* rather
        // than plain text, and it is zlib-compressed. Two things have to line
        // up for this to work: the zlib wrapper has to be stripped, and the
        // offsets inside the decoded table have to be trusted.
        let file = try PDFAppendableFile(bytes: PDFFixture.documentWithXrefStream())
        #expect(file.pages.count == 1)
        #expect(file.catalog?["Type"]?.asName == "Catalog")
        // Six objects, the last being the cross-reference stream itself.
        #expect(file.highestObjectNumber == 6)
    }

    // MARK: - Appending

    /// Adds one highlight to the first page and returns the updated bytes.
    private func appendingHighlight(
        to bytes: [UInt8],
        contents: String,
        objectNumber: Int
    ) throws -> [UInt8] {
        let file = try PDFAppendableFile(bytes: bytes)
        let page = try #require(file.pages.first)
        let change = PDFAnnotationWriter.add(
            PDFFixture.highlightAnnotation(
                rect: PDFRect(x: 72, y: 700, width: 300, height: 24),
                contents: contents,
                page: page.reference
            ),
            to: page,
            on: file,
            objectNumber: objectNumber,
            name: "amgi-highlight"
        )
        return bytes + PDFIncrementalUpdate.build(
            for: file,
            entries: change.entries,
            freed: change.freed,
            appendedAt: bytes.count
        )
    }

    @Test("an appended annotation appears in the document immediately")
    func appendedAnnotationIsVisible() throws {
        // The point of writing into the file rather than beside it: no export
        // step, and the file on disk is what Preview would see.
        let original = PDFFixture.classicDocument()
        let updated = try appendingHighlight(
            to: original, contents: "a highlighted phrase", objectNumber: 6
        )
        let file = try PDFAppendableFile(bytes: updated)
        let page = try #require(file.pages.first)
        let annotations = file.annotations(on: page)
        #expect(annotations.count == 1)
        #expect(annotations[0].subtype == "Highlight")
        #expect(annotations[0].contents == "a highlighted phrase")
    }

    @Test("the cross-reference table alone locates an appended annotation")
    func xrefAloneLocatesTheAnnotation() throws {
        // This is the Preview-fidelity guarantee, stated precisely: a reader
        // that trusts the cross-reference table — which is every conformant
        // reader, Preview among them — must find the annotation at the offset
        // the table gives it.
        //
        // Our own loader scans the file for objects when the table looks wrong,
        // which is what makes a damaged document readable. That recovery hides a
        // whole class of mistake: if the table records a *relative* offset
        // instead of an absolute one, our reader finds the annotation by scan
        // and the test passes, while Preview resolves object 6 to whatever sits
        // at that offset and shows nothing at all. So this checks the table's
        // own arithmetic rather than going through the loader.
        let original = PDFFixture.classicDocument()
        let file = try PDFAppendableFile(bytes: original)
        let page = try #require(file.pages.first)
        let update = PDFIncrementalUpdate.build(
            for: file,
            entries: PDFAnnotationWriter.add(
                PDFFixture.highlightAnnotation(
                    rect: PDFRect(x: 72, y: 700, width: 300, height: 24),
                    contents: "located by the table",
                    page: page.reference
                ),
                to: page,
                on: file,
                objectNumber: 6,
                name: "amgi-highlight"
            ).entries,
            appendedAt: original.count
        )
        let updated = original + update

        let parsed = try #require(PDFCrossReferenceTable.parse(bytes: updated, headerOffset: 0))
        let entry = try #require(parsed.entries[6])
        #expect(entry.offset >= original.count, "the offset must be absolute, not relative to the update")
        var cursor = PDFByteCursor(updated, from: entry.offset)
        #expect(cursor.readDigits() == 6)
        #expect(cursor.readDigits() == 0)
        #expect(cursor.readKeyword() == "obj")
        let object = try #require(try PDFObjectParser.parseObject(&cursor))
        #expect(object.asDictionary?["Subtype"]?.asName == "Highlight")

        // And the `startxref` at the tail must point into the appended section,
        // because a reader starts there and walks `/Prev` back.
        let startXref = try #require(PDFCrossReferenceTable.lastStartXref(in: updated))
        #expect(startXref > original.count, "the tail must point into the appended section")
        #expect(startXref > entry.offset, "the table comes after the objects it indexes")
    }

    @Test("appending does not change the original bytes")
    func appendIsNonDestructive() throws {
        // The original bytes must survive verbatim: they are the base document
        // every later update chains from, and rewriting them would invalidate
        // every `/Prev` pointing at this section.
        let original = PDFFixture.classicDocument()
        let updated = try appendingHighlight(
            to: original, contents: "x", objectNumber: 6
        )
        #expect(updated.count > original.count)
        #expect(Array(updated.prefix(original.count)) == original)
    }

    @Test("repeated appends accumulate rather than replace")
    func repeatedAppendsAccumulate() throws {
        var bytes = PDFFixture.classicDocument()
        for index in 0..<3 {
            bytes = try appendingHighlight(
                to: bytes, contents: "highlight \(index)", objectNumber: 6 + index
            )
        }
        let file = try PDFAppendableFile(bytes: bytes)
        let page = try #require(file.pages.first)
        #expect(file.annotations(on: page).count == 3)
    }

    @Test("an appended page reference resolves to the real page")
    func appendedAnnotationPointsAtItsPage() throws {
        let base = PDFFixture.twoPageDocument()
        let file = try PDFAppendableFile(bytes: base)
        let secondPage = try #require(file.pages.last)
        let change = PDFAnnotationWriter.add(
            PDFFixture.highlightAnnotation(
                rect: PDFRect(x: 10, y: 10, width: 100, height: 12),
                contents: "on page two",
                page: secondPage.reference
            ),
            to: secondPage,
            on: file,
            objectNumber: 7,
            name: "amgi-highlight"
        )
        let updated = try PDFAppendableFile(
            bytes: base + PDFIncrementalUpdate.build(
                for: file,
                entries: change.entries,
                appendedAt: base.count
            )
        )
        // Only the page that was touched gains the annotation. Getting this
        // wrong is how a note ends up attached to the facing page.
        #expect(updated.annotations(on: updated.pages[0]).isEmpty)
        #expect(updated.annotations(on: updated.pages[1]).count == 1)
    }

    @Test("a rewritten annotation supersedes the earlier one")
    func rewriteSupersedes() throws {
        // Editing an annotation appends a new definition of the same object
        // rather than rewriting the old bytes — which is what makes an edit
        // mergeable with a concurrent edit elsewhere.
        var bytes = PDFFixture.classicDocument()
        bytes = try appendingHighlight(to: bytes, contents: "first wording", objectNumber: 6)
        let file = try PDFAppendableFile(bytes: bytes)
        let page = try #require(file.pages.first)
        let existing = try #require(file.annotations(on: page).first)
        let change = PDFAnnotationWriter.add(
            PDFFixture.highlightAnnotation(
                rect: PDFRect(x: 72, y: 700, width: 300, height: 24),
                contents: "second wording",
                page: page.reference
            ),
            to: page,
            on: file,
            objectNumber: existing.reference.number,
            name: "amgi-highlight",
            replacing: existing
        )
        bytes += PDFIncrementalUpdate.build(
            for: file,
            entries: change.entries,
            freed: change.freed,
            appendedAt: bytes.count
        )
        let reread = try PDFAppendableFile(bytes: bytes)
        let annotations = reread.annotations(on: try #require(reread.pages.first))
        #expect(annotations.count == 1, "an edit must not leave two annotations")
        #expect(annotations[0].contents == "second wording")
    }

    @Test("the document's identity is preserved across an update")
    func identityIsPreserved() throws {
        // `/ID`'s first element identifies the original document and must never
        // change, or a reader sees a different file rather than a revised one.
        let original = PDFFixture.classicDocument()
        let file = try PDFAppendableFile(bytes: original)
        #expect(file.fileIdentifier == [0x01, 0x02])
        let page = try #require(file.pages.first)
        let update = PDFIncrementalUpdate.build(
            for: file,
            entries: PDFAnnotationWriter.add(
                PDFFixture.highlightAnnotation(
                    rect: PDFRect(x: 0, y: 0, width: 10, height: 10),
                    contents: "x",
                    page: page.reference
                ),
                to: page,
                on: file,
                objectNumber: 6,
                name: "amgi-highlight"
            ).entries,
            appendedAt: original.count
        )
        let reread = try PDFAppendableFile(bytes: original + update)
        #expect(reread.fileIdentifier == file.fileIdentifier)
    }

    @Test("an identical edit produces identical bytes")
    func identicalEditsAreByteIdentical() throws {
        // Determinism is what makes a no-op sync detectable: two devices that
        // made the same change must produce the same file, not merely
        // equivalent ones.
        let original = PDFFixture.classicDocument()
        let page = try #require(try PDFAppendableFile(bytes: original).pages.first)
        let annotation = PDFFixture.highlightAnnotation(
            rect: PDFRect(x: 72, y: 700, width: 300, height: 24),
            contents: "same",
            page: page.reference
        )
        func makeUpdate() -> [UInt8] {
            let file = try! PDFAppendableFile(bytes: original)
            return PDFIncrementalUpdate.build(
                for: file,
                entries: PDFAnnotationWriter.add(
                    annotation,
                    to: page,
                    on: file,
                    objectNumber: 6,
                    name: "amgi-highlight"
                ).entries,
                appendedAt: original.count
            )
        }
        #expect(makeUpdate() == makeUpdate())
    }

    @Test("removing an annotation frees its object number")
    func removalFreesTheObject() throws {
        // Deletion has to be expressed in the cross-reference table, not by
        // leaving the object unreferenced: a reader recovering a damaged table
        // by scanning the file would otherwise still find, and display, the
        // annotation the user deleted.
        var bytes = PDFFixture.classicDocument()
        bytes = try appendingHighlight(to: bytes, contents: "to be removed", objectNumber: 6)
        let file = try PDFAppendableFile(bytes: bytes)
        let page = try #require(file.pages.first)
        let existing = try #require(file.annotations(on: page).first)
        bytes += PDFIncrementalUpdate.build(
            for: file,
            entries: PDFAnnotationWriter.remove(existing, from: page, on: file).entries,
            freed: PDFAnnotationWriter.remove(existing, from: page, on: file).freed,
            appendedAt: bytes.count
        )
        let reread = try PDFAppendableFile(bytes: bytes)
        let rereadPage = try #require(reread.pages.first)
        #expect(reread.annotations(on: rereadPage).isEmpty)
        // The object is unreachable through the table.
        #expect(reread.object(number: existing.reference.number) == nil)
    }

    @Test("a page's other keys survive being rewritten")
    func pageKeysSurvive() throws {
        // The page dictionary holds `/Resources`, `/Rotate` and `/CropBox`.
        // A writer that rebuilt a page from a known list of keys would drop the
        // font resources and turn the saved page into a page of blank boxes.
        let original = PDFFixture.classicDocument()
        let bytes = try appendingHighlight(
            to: original, contents: "x", objectNumber: 6
        )
        let before = try #require(try PDFAppendableFile(bytes: original).pages.first)
        let after = try #require(try PDFAppendableFile(bytes: bytes).pages.first)
        for key in before.dictionary.keys {
            #expect(after.dictionary[key] == before.dictionary[key], "lost /\(key)")
        }
        #expect(after.dictionary["Resources"] != nil)
        #expect(after.dictionary["MediaBox"] != nil)
    }
}

@Suite("PDF linearisation")
struct PDFLineariserTests {
    private func appending(
        to bytes: [UInt8],
        contents: String,
        objectNumber: Int
    ) throws -> [UInt8] {
        let file = try PDFAppendableFile(bytes: bytes)
        let page = try #require(file.pages.first)
        let change = PDFAnnotationWriter.add(
            PDFFixture.highlightAnnotation(
                rect: PDFRect(x: 72, y: 700, width: 300, height: 24),
                contents: contents,
                page: page.reference
            ),
            to: page,
            on: file,
            objectNumber: objectNumber,
            name: "amgi-highlight"
        )
        return bytes + PDFIncrementalUpdate.build(
            for: file,
            entries: change.entries,
            freed: change.freed,
            appendedAt: bytes.count
        )
    }

    private func annotationTexts(in bytes: [UInt8]) throws -> Set<String> {
        let file = try PDFAppendableFile(bytes: bytes)
        let page = try #require(file.pages.first)
        return Set(file.annotations(on: page).compactMap(\.contents))
    }

    @Test("merging two devices' work on the same page keeps both annotations")
    func mergeKeepsBothSides() throws {
        // The guarantee the whole design exists for: two devices annotated the
        // same document independently, and neither one's work is lost.
        //
        // This is the case that makes a plain union insufficient. Both devices
        // had to rewrite the *page* object to add their annotation to `/Annots`,
        // so they collide on object 3. Letting one page definition win would
        // leave the other device's annotation in the file but referenced by
        // nothing — present, invisible, and lost as far as any reader is
        // concerned. The merge therefore rebuilds `/Annots` from the annotation
        // objects actually present.
        let base = PDFFixture.classicDocument()
        let deviceA = try appending(to: base, contents: "from A", objectNumber: 6)
        let deviceB = try appending(to: base, contents: "from B", objectNumber: 7)

        let merged = try PDFLineariser.merge(primary: deviceA, secondary: deviceB)
        let texts = try annotationTexts(in: merged.bytes)
        #expect(texts.contains("from A"), "device A's annotation was lost")
        #expect(texts.contains("from B"), "device B's annotation was lost")
        #expect(merged.annotationsRelinked == 1, "exactly one side was orphaned by the page collision")
    }

    @Test("merging a device's file with an older base keeps the newer work")
    func mergePrefersTheAnnotatedSide() throws {
        // Reconciling with a base that has no annotations must not discard them.
        let base = PDFFixture.classicDocument()
        let device = try appending(to: base, contents: "kept", objectNumber: 6)
        let merged = try PDFLineariser.merge(primary: device, secondary: base)
        #expect(try annotationTexts(in: merged.bytes).contains("kept"))
    }

    @Test("an annotation edited on both sides resolves to one coherent version")
    func mergeResolvesAConflictingEdit() throws {
        // The one case where a difference between the two files' outcomes is
        // legitimate: both devices edited the *same* annotation, and there is
        // only one slot for the answer. The merge must not leave two copies or
        // a half-applied one.
        let base = PDFFixture.classicDocument()
        let deviceA = try appending(to: base, contents: "A's wording", objectNumber: 6)
        let deviceB = try appending(to: base, contents: "B's wording", objectNumber: 6)
        let merged = try PDFLineariser.merge(primary: deviceA, secondary: deviceB)
        let texts = try annotationTexts(in: merged.bytes)
        #expect(texts.count == 1, "a shared object number resolves to exactly one annotation")
        #expect(texts.contains("A's wording") || texts.contains("B's wording"))
    }

    @Test("a linearised file is compact and re-openable")
    func linearisedIsCompact() throws {
        // Linearising is also how the append-only growth is reclaimed, so it
        // has to be lossless and smaller.
        let base = PDFFixture.classicDocument()
        var device = base
        for index in 0..<5 {
            device = try appending(to: device, contents: "note \(index)", objectNumber: 6 + index)
        }
        let before = device.count
        let merged = try PDFLineariser.merge(primary: device, secondary: base)
        #expect(merged.bytes.count < before, "linearising must reclaim space")
        let file = try PDFAppendableFile(bytes: merged.bytes)
        #expect(file.pages.count == 1)
        #expect(file.annotations(on: try #require(file.pages.first)).count == 5)
    }

    @Test("merging is order-independent in outcome")
    func mergeIsOrderIndependent() throws {
        // Which file is primary only decides provenance, never survival.
        let base = PDFFixture.classicDocument()
        let a = try appending(to: base, contents: "A", objectNumber: 6)
        let b = try appending(to: base, contents: "B", objectNumber: 7)
        let first = try PDFLineariser.merge(primary: a, secondary: b)
        let second = try PDFLineariser.merge(primary: b, secondary: a)
        #expect(first.bytes.count == second.bytes.count)
        // The surviving content is the same either way round.
        #expect(try annotationTexts(in: first.bytes) == annotationTexts(in: second.bytes))
    }

    @Test("merging a file with itself is harmless")
    func mergeWithSelfIsSafe() throws {
        // Idempotence, so a sync that re-receives a file does not churn.
        let base = PDFFixture.classicDocument()
        let annotated = try appending(to: base, contents: "x", objectNumber: 6)
        let merged = try PDFLineariser.merge(primary: annotated, secondary: annotated)
        let file = try PDFAppendableFile(bytes: merged.bytes)
        #expect(file.annotations(on: try #require(file.pages.first)).count == 1)
    }
}

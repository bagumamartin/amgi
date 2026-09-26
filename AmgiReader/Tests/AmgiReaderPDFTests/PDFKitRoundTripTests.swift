import Foundation
import Testing
@testable import AmgiReaderPDF

/// Writes a PDF with our append machinery and reads it back with PDFKit.
///
/// This is the only test that actually establishes Preview compatibility.
/// Everything else in this target checks our reader against our reader, which
/// agrees with itself by construction: a file our own loader resolves correctly
/// proves nothing about whether Preview resolves it correctly. PDFKit is Apple's
/// own PDF implementation — the same family of code Preview uses — so if PDFKit
/// finds the annotation at the right place with the right subtype and contents,
/// a file that round-trips through Mail or Files will too.
///
/// The tests are skipped where PDFKit is unavailable (the package's Linux CI,
/// for instance) rather than failing, since the absence of a platform framework
/// is not a defect in the code under test.
///
/// The whole suite is main-actor isolated because PDFKit's document types are,
/// and because `PDFDocument` reads its file synchronously.
@MainActor
@Suite("PDFKit round trip", .enabled(if: PDFKitProbe.isAvailable))
struct PDFKitRoundTripTests {
    /// Writes `bytes` to a temporary file and returns its URL.
    private func temporaryFile(_ bytes: [UInt8], named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("amgi-pdfkit-\(UUID().uuidString)-\(name).pdf")
        try Data(bytes).write(to: url)
        return url
    }

    @Test("PDFKit sees an annotation appended by us")
    func annotationIsVisibleToPDFKit() throws {
        let base = PDFFixture.classicDocument()
        let file = try PDFAppendableFile(bytes: base)
        let page = try #require(file.pages.first)
        let change = PDFAnnotationWriter.add(
            PDFFixture.highlightAnnotation(
                rect: PDFRect(x: 72, y: 700, width: 300, height: 24),
                contents: "annotated by ijuka",
                page: page.reference
            ),
            to: page,
            on: file,
            objectNumber: 6,
            name: "amgi-highlight"
        )
        let updated = base + PDFIncrementalUpdate.build(
            for: file,
            entries: change.entries,
            freed: change.freed,
            appendedAt: base.count
        )
        let url = try temporaryFile(updated, named: "annotated")
        defer { try? FileManager.default.removeItem(at: url) }

        let report = try PDFKitProbe.inspect(url)
        #expect(report.pageCount == 1, "PDFKit could not read the page count")
        #expect(report.annotationCount == 1, "PDFKit found \(report.annotationCount) annotations")
        let annotation = try #require(report.annotations.first)
        #expect(annotation.subtype == "Highlight")
        #expect(annotation.contents == "annotated by ijuka")
    }

    @Test("PDFKit still reads the page after the page object is rewritten")
    func rewrittenPageStaysReadable() throws {
        // The annotation is found by way of the page's `/Annots` array, which
        // means adding one necessarily rewrites the page object. If that
        // redefinition dropped a key — `/Resources` above all — PDFKit would
        // report the page but fail to render its text. Checking the text is
        // therefore part of checking the annotation.
        let base = PDFFixture.classicDocument()
        let file = try PDFAppendableFile(bytes: base)
        let page = try #require(file.pages.first)
        let change = PDFAnnotationWriter.add(
            PDFFixture.highlightAnnotation(
                rect: PDFRect(x: 72, y: 700, width: 300, height: 24),
                contents: "note",
                page: page.reference
            ),
            to: page,
            on: file,
            objectNumber: 6,
            name: "amgi-highlight"
        )
        let updated = base + PDFIncrementalUpdate.build(
            for: file,
            entries: change.entries,
            freed: change.freed,
            appendedAt: base.count
        )
        let url = try temporaryFile(updated, named: "rewritten")
        defer { try? FileManager.default.removeItem(at: url) }

        let report = try PDFKitProbe.inspect(url)
        #expect(report.pageCount == 1)
        #expect(report.text.contains("Test Document"), "the page lost its text: \(report.text.debugDescription)")
    }

    @Test("PDFKit reads a document whose cross-reference data is a stream")
    func xrefStreamDocumentIsReadable() throws {
        let url = try temporaryFile(PDFFixture.documentWithXrefStream(), named: "xrefstream")
        defer { try? FileManager.default.removeItem(at: url) }
        let report = try PDFKitProbe.inspect(url)
        #expect(report.pageCount == 1, "a compressed cross-reference stream must be readable")
        #expect(report.text.contains("Streamed"))
    }

    @Test("PDFKit reads a linearised file")
    func linearisedFileIsReadable() throws {
        // The merge rewrites every object and every reference. A translation
        // bug would produce a file that opens and shows nothing, so this checks
        // both the page and the annotations survive it.
        let base = PDFFixture.classicDocument()
        let file = try PDFAppendableFile(bytes: base)
        let page = try #require(file.pages.first)
        let change = PDFAnnotationWriter.add(
            PDFFixture.highlightAnnotation(
                rect: PDFRect(x: 72, y: 700, width: 300, height: 24),
                contents: "survives linearisation",
                page: page.reference
            ),
            to: page,
            on: file,
            objectNumber: 6,
            name: "amgi-highlight"
        )
        let annotated = base + PDFIncrementalUpdate.build(
            for: file,
            entries: change.entries,
            freed: change.freed,
            appendedAt: base.count
        )
        let merged = try PDFLineariser.merge(primary: annotated, secondary: base)
        let url = try temporaryFile(merged.bytes, named: "linearised")
        defer { try? FileManager.default.removeItem(at: url) }

        let report = try PDFKitProbe.inspect(url)
        #expect(report.pageCount == 1)
        #expect(report.text.contains("Test Document"))
        #expect(report.annotationCount == 1, "the annotation was lost in translation")
        #expect(report.annotations.first?.contents == "survives linearisation")
    }

    @Test("PDFKit reads a file that has had many annotations appended")
    func manyAppendsStayReadable() throws {
        var bytes = PDFFixture.classicDocument()
        for index in 0..<10 {
            let file = try PDFAppendableFile(bytes: bytes)
            let page = try #require(file.pages.first)
            let change = PDFAnnotationWriter.add(
                PDFFixture.highlightAnnotation(
                    rect: PDFRect(x: 72, y: 700 - Double(index) * 20, width: 300, height: 16),
                    contents: "note \(index)",
                    page: page.reference
                ),
                to: page,
                on: file,
                objectNumber: 6 + index,
                name: "amgi-highlight-\(index)"
            )
            bytes += PDFIncrementalUpdate.build(
                for: file,
                entries: change.entries,
                freed: change.freed,
                appendedAt: bytes.count
            )
        }
        let url = try temporaryFile(bytes, named: "many")
        defer { try? FileManager.default.removeItem(at: url) }

        let report = try PDFKitProbe.inspect(url)
        #expect(report.pageCount == 1)
        // Each append supersedes the page object, so the `/Annots` array grows by
        // one. If a redefinition lost an earlier entry, this count would be short
        // and the earlier annotations would be invisible in Preview even though
        // their objects are still in the file.
        #expect(report.annotationCount == 10, "PDFKit found \(report.annotationCount) of 10")
        let contents = Set(report.annotations.compactMap(\.contents))
        #expect(contents.count == 10)
    }

    @Test("PDFKit does not show a deleted annotation")
    func deletedAnnotationIsHidden() throws {
        // The object stays in the file — the format does not reclaim it — so
        // what makes a deletion stick is the free entry in the cross-reference
        // table. If that is missing, PDFKit finds the bytes and shows the
        // annotation the user deleted.
        let base = PDFFixture.classicDocument()
        let file = try PDFAppendableFile(bytes: base)
        let page = try #require(file.pages.first)
        let add = PDFAnnotationWriter.add(
            PDFFixture.highlightAnnotation(
                rect: PDFRect(x: 72, y: 700, width: 300, height: 24),
                contents: "deleted",
                page: page.reference
            ),
            to: page,
            on: file,
            objectNumber: 6,
            name: "amgi-highlight"
        )
        var bytes = base + PDFIncrementalUpdate.build(
            for: file, entries: add.entries, freed: add.freed, appendedAt: base.count
        )

        let second = try PDFAppendableFile(bytes: bytes)
        let secondPage = try #require(second.pages.first)
        let existing = try #require(second.annotations(on: secondPage).first)
        let remove = PDFAnnotationWriter.remove(existing, from: secondPage, on: second)
        bytes += PDFIncrementalUpdate.build(
            for: second,
            entries: remove.entries,
            freed: remove.freed,
            appendedAt: bytes.count
        )
        let url = try temporaryFile(bytes, named: "deleted")
        defer { try? FileManager.default.removeItem(at: url) }

        let report = try PDFKitProbe.inspect(url)
        #expect(report.annotationCount == 0, "a deleted annotation is still visible")
    }

    @Test("PDFKit reads a file that had junk before the header")
    func toleratesLeadingJunkForPDFKit() throws {
        // Our reader tolerates it; the question is whether the offsets we then
        // write are right. They are absolute, so the appended annotation is
        // still at the position the table says.
        var bytes = Array("<< leading junk >>\n".utf8)
        bytes.append(contentsOf: PDFFixture.classicDocument())
        let originalLength = bytes.count
        let file = try PDFAppendableFile(bytes: bytes)
        let page = try #require(file.pages.first)
        let change = PDFAnnotationWriter.add(
            PDFFixture.highlightAnnotation(
                rect: PDFRect(x: 72, y: 700, width: 300, height: 24),
                contents: "past the junk",
                page: page.reference
            ),
            to: page,
            on: file,
            objectNumber: 6,
            name: "amgi-highlight"
        )
        bytes += PDFIncrementalUpdate.build(
            for: file, entries: change.entries, freed: change.freed, appendedAt: bytes.count
        )
        let url = try temporaryFile(bytes, named: "junk")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(originalLength > 0)

        let report = try PDFKitProbe.inspect(url)
        #expect(report.annotationCount == 1, "PDFKit found \(report.annotationCount) annotations")
        #expect(report.annotations.first?.contents == "past the junk")
    }
}

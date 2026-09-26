import Compression
import Foundation
import Testing
@testable import AmgiReaderPDF

/// Builds PDFs with structure the parser has to read: an outline, page labels,
/// compressed content streams, and a document information dictionary.
enum PDFDocumentFixture {
    /// A two-page document with an outline, an `/Info` dictionary and an
    /// optional page-label tree.
    ///
    /// Written as bytes with computed offsets, so the cross-reference table is
    /// correct by construction. A fixture with plausible-but-wrong offsets would
    /// pass through the object-scan recovery and never exercise the table.
    static func outlined(
        info: [String: String] = ["Title": "On Typography", "Author": "A. Reader"],
        labelRanges: [(startPage: Int, style: String)] = [],
        compressContent: Bool = true
    ) -> [UInt8] {
        let pageObjects = [3, 5]
        let contentObjects = [4, 6]
        // 1 catalog, 2 page tree, 3/4 first page, 5/6 second page, 7 outlines
        // root, 8 first outline item, 9 second outline item.
        var objects: [Int: [UInt8]] = [
            1: Array(("<< /Type /Catalog /Pages 2 0 R /Outlines 7 0 R"
                + (labelRanges.isEmpty ? "" : " /PageLabels 10 0 R") + " >>").utf8),
            2: Array("<< /Type /Pages /Kids [3 0 R 5 0 R] /Count 2 >>".utf8),
            7: Array("<< /Type /Outlines /First 8 0 R /Last 9 0 R /Count 2 >>".utf8),
            8: Array("<< /Title (The First Chapter) /Parent 7 0 R /Next 9 0 R /Dest [3 0 R /XYZ 0 792 0] >>".utf8),
            9: Array("<< /Title (The Second Chapter) /Parent 7 0 R /Prev 8 0 R /Dest [5 0 R /XYZ 0 792 0] >>".utf8),
        ]
        if !labelRanges.isEmpty {
            // `/Nums` pairs a zero-based page index with a label dictionary. The
            // index is where a range *begins*; the range runs until the next
            // entry, which is how one style covers many pages.
            let nums = labelRanges
                .map { "\($0.startPage) << /S \($0.style) >> " }
                .joined()
            objects[10] = Array("<< /Nums [\(nums)] >>".utf8)
        }
        for (offset, page) in pageObjects.enumerated() {
            objects[page] = Array(("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] "
                + "/Contents \(contentObjects[offset]) 0 R "
                + "/Resources << /Font << /F1 11 0 R >> >> >>").utf8)
        }
        for (offset, content) in contentObjects.enumerated() {
            let body = Array("BT /F1 24 Tf 72 700 Td (Chapter \(offset + 1)) Tj ET".utf8)
            if compressContent {
                // The payload is appended as raw bytes. Round-tripping it
                // through `String` would replace every byte that is not valid
                // UTF-8 with U+FFFD, producing a file that *looks* right in a hex
                // dump and decodes to nothing — a fixture that silently fails to
                // test the thing it exists to test.
                let compressed = zlibCompress(body)
                objects[content] = Array(
                    "<< /Length \(compressed.count) /Filter /FlateDecode >>\nstream\n".utf8
                ) + compressed + Array("\nendstream".utf8)
            } else {
                objects[content] = Array(
                    "<< /Length \(body.count) >>\nstream\n".utf8
                ) + body + Array("\nendstream".utf8)
            }
        }
        objects[11] = Array("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>".utf8)

        let infoEntries = info.map { key, value in
            " /\(key) (\(value))"
        }.sorted().joined()
        objects[12] = Array("<< \(infoEntries) >>".utf8)

        return assemble(objects: objects, root: 1, size: 13, extraTrailer: " /Info 12 0 R")
    }

    /// A document of `pageCount` pages with a page-label tree.
    ///
    /// The label ranges are expressed as `(startPage, style)` pairs, because a
    /// range runs until the next one. Giving one entry per *page* would encode
    /// something different — five single-page ranges all start at 1, so they all
    /// read "i" — which is a real trap when reading the specification and a
    /// misleading thing to encode in a fixture.
    static func labelled(
        pageCount: Int,
        ranges: [(startPage: Int, style: String)]
    ) -> [UInt8] {
        var objects: [Int: [UInt8]] = [:]
        var kids: [String] = []
        // Objects from 3 upwards: a page and its content stream per page.
        var next = 3
        for index in 0..<pageCount {
            let page = next
            let content = next + 1
            next += 2
            kids.append("\(page) 0 R")
            objects[page] = Array(
                ("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] "
                    + "/Contents \(content) 0 R /Resources << /Font << /F1 \(next) 0 R >> >> >>").utf8
            )
            let body = "BT /F1 12 Tf 72 700 Td (Page \(index + 1)) Tj ET"
            objects[content] = Array("<< /Length \(body.utf8.count) >>\nstream\n\(body)\nendstream".utf8)
        }
        objects[1] = Array("<< /Type /Catalog /Pages 2 0 R /PageLabels \(next + 1) 0 R >>".utf8)
        objects[2] = Array(
            "<< /Type /Pages /Kids [\(kids.joined(separator: " "))] /Count \(pageCount) >>".utf8
        )
        objects[next] = Array("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>".utf8)
        let nums = ranges.map { "\($0.startPage) << /S \($0.style) >> " }.joined()
        objects[next + 1] = Array("<< /Nums [\(nums)] >>".utf8)
        return assemble(objects: objects, root: 1, size: next + 2)
    }

    /// A page whose content draws no text: an image scan.
    static func scanned() -> [UInt8] {
        // A content stream with no text-showing operator at all.
        let body = "q 612 0 0 792 0 0 cm /Im0 Do Q"
        return assemble(
            objects: [
                1: Array("<< /Type /Catalog /Pages 2 0 R >>".utf8),
                2: Array("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8),
                3: Array(("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R "
                    + "/Resources << /XObject << /Im0 5 0 R >> >> >>").utf8),
                4: Array("<< /Length \(body.utf8.count) >>\nstream\n\(body)\nendstream".utf8),
                5: Array("<< /Type /XObject /Subtype /Image /Width 612 /Height 792 >>".utf8),
            ],
            root: 1,
            size: 6
        )
    }

    /// Lays out objects and writes a correct cross-reference table.
    ///
    /// Object bodies are bytes rather than strings because a content stream's
    /// payload is binary, and any detour through `String` corrupts it.
    private static func assemble(
        objects: [Int: [UInt8]],
        root: Int,
        size: Int,
        extraTrailer: String = ""
    ) -> [UInt8] {
        var bytes: [UInt8] = Array("%PDF-1.7\n%".utf8)
        bytes.append(contentsOf: [0xE2, 0xE3, 0xCF, 0xD3])
        bytes.append(0x0A)
        var offsets: [Int: Int] = [:]
        for number in objects.keys.sorted() {
            offsets[number] = bytes.count
            bytes.append(contentsOf: Array("\(number) 0 obj\n".utf8))
            bytes.append(contentsOf: objects[number]!)
            bytes.append(contentsOf: Array("\nendobj\n".utf8))
        }
        let xrefOffset = bytes.count
        var table = "xref\n0 \(size)\n0000000000 65535 f \n"
        for number in 1..<max(2, size) {
            table += String(format: "%010d 00000 n \n", offsets[number] ?? 0)
        }
        bytes.append(contentsOf: Array("\(table)trailer\n<< /Size \(size) /Root \(root) 0 R\(extraTrailer) >>\n".utf8))
        bytes.append(contentsOf: Array("startxref\n\(xrefOffset)\n%%EOF\n".utf8))
        return bytes
    }

    static func zlibCompress(_ data: [UInt8]) -> [UInt8] {
        // zlib header: DEFLATE with a 32K window, plus the check value that
        // makes the two bytes a multiple of 31.
        var out: [UInt8] = [0x78, 0x9C]
        var body = [UInt8](repeating: 0, count: data.count + 1_024)
        let written = data.withUnsafeBufferPointer { source in
            body.withUnsafeMutableBufferPointer { destination in
                guard let base = destination.baseAddress, let sourceBase = source.baseAddress
                else { return 0 }
                return compression_encode_buffer(
                    base, destination.count, sourceBase, data.count, nil, COMPRESSION_ZLIB
                )
            }
        }
        out.append(contentsOf: body[0..<written])
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % 65_521
            b = (b + a) % 65_521
        }
        let checksum = b << 16 | a
        out.append(contentsOf: [
            UInt8(checksum >> 24 & 0xFF), UInt8(checksum >> 16 & 0xFF),
            UInt8(checksum >> 8 & 0xFF), UInt8(checksum & 0xFF),
        ])
        return out
    }

    static func write(_ bytes: [UInt8], named name: String = "fixture.pdf") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("amgi-pdfdoc-\(UUID().uuidString)-\(name)")
        try Data(bytes).write(to: url)
        return url
    }
}

@Suite("PDF document parser")
struct PDFDocumentParserTests {
    private func parse(_ bytes: [UInt8]) throws -> PDFDocumentDescriptor {
        try PDFDocumentParser().parse(bytes: bytes, bookID: "pdf-test")
    }

    @Test("reads the title and author from the information dictionary")
    func readsDocumentInfo() throws {
        let descriptor = try parse(PDFDocumentFixture.outlined())
        #expect(descriptor.title == "On Typography")
        #expect(descriptor.author == "A. Reader")
    }

    @Test("a document with no information dictionary still gets a title")
    func synthesisesATitle() throws {
        // A row of identical blank entries is the same information as no title.
        let descriptor = try parse(PDFDocumentFixture.outlined(info: [:]))
        #expect(descriptor.title == "Untitled PDF")
        #expect(descriptor.author == nil)
    }

    @Test("reads the outline with its destination pages")
    func readsOutline() throws {
        let descriptor = try parse(PDFDocumentFixture.outlined())
        #expect(descriptor.outline.count == 2)
        #expect(descriptor.outline[0].title == "The First Chapter")
        #expect(descriptor.outline[0].pageIndex == 0)
        #expect(descriptor.outline[1].title == "The Second Chapter")
        #expect(descriptor.outline[1].pageIndex == 1)
    }

    @Test("outline entry IDs are stable and distinct")
    func outlineIDsAreStable() throws {
        // Chapter IDs key the saved reading position, so the same document must
        // always produce the same IDs and different chapters must not collide.
        let first = try parse(PDFDocumentFixture.outlined())
        let second = try parse(PDFDocumentFixture.outlined())
        #expect(first.outline.map(\.id) == second.outline.map(\.id))
        #expect(Set(first.outline.map(\.id)).count == first.outline.count)
    }

    @Test("a document with no outline yields no entries")
    func handlesMissingOutline() throws {
        let descriptor = try parse(PDFFixture.classicDocument())
        #expect(descriptor.outline.isEmpty)
    }

    @Test("reads the document's own page numbering")
    func readsPageLabels() throws {
        // A book with roman front matter is numbered "i, ii, iii, 1, 2" — not
        // "1, 2, 3, 4, 5". Deriving from the index would misreport every page
        // the reader says out loud.
        let descriptor = try parse(PDFDocumentFixture.labelled(
            pageCount: 5,
            ranges: [(0, "/r"), (3, "/D")]
        ))
        #expect(descriptor.pageCount == 5)
        #expect(descriptor.label(forPageIndex: 0) == "i")
        #expect(descriptor.label(forPageIndex: 1) == "ii")
        #expect(descriptor.label(forPageIndex: 2) == "iii")
        // The restart is encoded only by the range boundary, which is the point.
        #expect(descriptor.label(forPageIndex: 3) == "1")
        #expect(descriptor.label(forPageIndex: 4) == "2")
    }

    @Test("a document with no page labels falls back to page numbers")
    func handlesMissingPageLabels() throws {
        let descriptor = try parse(PDFFixture.twoPageDocument())
        #expect(descriptor.pageLabels == nil)
        #expect(descriptor.label(forPageIndex: 0) == "1")
        #expect(descriptor.label(forPageIndex: 1) == "2")
    }

    @Test("a label tree with more ranges than pages is tolerated")
    func toleratesMoreRangesThanPages() throws {
        // A label tree covering a document that was later truncated is ordinary,
        // and the ranges past the end have nowhere to go. Building the range
        // without clamping traps on an inverted interval, which is a crash on
        // opening a book rather than a wrong label.
        let descriptor = try parse(PDFDocumentFixture.labelled(
            pageCount: 2,
            ranges: [(0, "/r"), (1, "/r"), (2, "/D"), (3, "/D"), (4, "/D")]
        ))
        #expect(descriptor.pageCount == 2)
        #expect(descriptor.label(forPageIndex: 0) == "i")
        // Each of these ranges covers exactly one page and so restarts at 1.
        #expect(descriptor.label(forPageIndex: 1) == "i")
    }

    @Test("a page whose stream shows text is not treated as a scan")
    func detectsTextLayer() throws {
        // This is the question that decides whether OCR runs at all. A false
        // "scan" sends a readable document through OCR; a false "readable"
        // produces cards full of empty strings.
        let descriptor = try parse(PDFDocumentFixture.outlined())
        #expect(descriptor.hasTextLayer)
        #expect(descriptor.textLayerCoverage == 1.0)
    }

    @Test("a page that only draws an image is detected as a scan")
    func detectsScan() throws {
        let descriptor = try parse(PDFDocumentFixture.scanned())
        #expect(!descriptor.hasTextLayer)
        #expect(descriptor.textLayerCoverage == 0)
    }

    @Test("a compressed content stream is decoded before being inspected")
    func decodesCompressedStreams() throws {
        // Almost every real content stream is Flate-compressed. Looking for text
        // operators in the compressed bytes would find none, and every
        // born-digital document would be misreported as a scan. It would also
        // make the fingerprint depend on how well the stream compressed rather
        // than on what it says, which is stability for the wrong reason.
        let compressed = try parse(PDFDocumentFixture.outlined(compressContent: true))
        let plain = try parse(PDFDocumentFixture.outlined(compressContent: false))
        #expect(compressed.hasTextLayer)
        #expect(plain.hasTextLayer)
        // Same text and geometry, different bytes: the fingerprint must agree.
        #expect(compressed.documentFingerprint == plain.documentFingerprint)
    }

    @Test("the fingerprint is stable across reads of the same file")
    func fingerprintIsStable() throws {
        let bytes = PDFDocumentFixture.outlined()
        let first = try parse(bytes)
        let second = try parse(bytes)
        #expect(first.documentFingerprint == second.documentFingerprint)
    }

    @Test("the fingerprint notices a change in the document's text")
    func fingerprintTracksText() throws {
        // The fingerprint answers "is this still the same document's layout and
        // text?", so a different page count or different words must change it.
        let twoPages = try parse(PDFDocumentFixture.outlined())
        let threePages = try parse(PDFDocumentFixture.labelled(pageCount: 3, ranges: []))
        #expect(twoPages.documentFingerprint != threePages.documentFingerprint)
    }

    @Test("the fingerprint deliberately ignores metadata")
    func fingerprintIgnoresMetadata() throws {
        // A document re-exported with a new title and author is the same
        // document: every anchor in it still resolves. Hashing the metadata
        // would invalidate every saved note and reading position for no reason.
        let original = try parse(PDFDocumentFixture.outlined())
        let reexported = try parse(
            PDFDocumentFixture.outlined(info: ["Title": "Different", "Author": "Someone Else"])
        )
        #expect(original.title != reexported.title)
        #expect(original.documentFingerprint == reexported.documentFingerprint)
    }

    @Test("a non-PDF is rejected as such")
    func rejectsNonPDF() {
        #expect(throws: PDFDocumentParser.ParseError.notAPDF) {
            _ = try PDFDocumentParser().parse(bytes: Array("plain text".utf8), bookID: "x")
        }
    }

    @Test("an encrypted document is reported as encrypted, not as broken")
    func reportsEncryptionDistinctly() {
        // An encrypted PDF opens in Preview and can be read; it just cannot be
        // annotated. Reporting it as unparseable would offer a repair action that
        // cannot possibly help.
        #expect(throws: PDFDocumentParser.ParseError.encrypted) {
            _ = try PDFDocumentParser().parse(
                bytes: PDFFixture.encryptedDocument(), bookID: "x"
            )
        }
    }
}

@Suite("PDF page label styles")
struct PDFPageLabelStyleTests {
    @Test("decimal labels count from the start value")
    func decimal() {
        let style = PDFPageLabelStyle(style: .decimal, start: 1)
        #expect(style.label(for: 0) == "1")
        #expect(style.label(for: 9) == "10")
    }

    @Test("roman labels use the subtractive form")
    func roman() {
        // "IIII" for four is wrong; the accepted form is "IV".
        let style = PDFPageLabelStyle(style: .lowerRoman, start: 1)
        #expect(style.label(for: 0) == "i")
        #expect(style.label(for: 3) == "iv")
        #expect(style.label(for: 8) == "ix")
        #expect(style.label(for: 13) == "xiv")
        #expect(PDFPageLabelStyle(style: .upperRoman, start: 1).label(for: 0) == "I")
    }

    @Test("a number beyond the roman range falls back to arabic")
    func romanOverflow() throws {
        // There is no accepted representation past 3999. "4000" is honest;
        // "MMMM" would look authoritative and be wrong.
        let style = PDFPageLabelStyle(style: .upperRoman, start: 3999)
        #expect(style.label(for: 0) == "MMMCMXCIX")
        #expect(style.label(for: 1) == "4000")
    }

    @Test("alphabetic labels are bijective base 26")
    func letters() {
        // 26 is "z", not "ba": reading this as plain base-26 shifts every label
        // after the 26th page.
        let style = PDFPageLabelStyle(style: .lowerLetters, start: 1)
        #expect(style.label(for: 0) == "a")
        #expect(style.label(for: 25) == "z")
        #expect(style.label(for: 26) == "aa")
        #expect(PDFPageLabelStyle(style: .upperLetters, start: 1).label(for: 26) == "AA")
    }

    @Test("a prefix is placed before the number")
    func prefix() {
        let style = PDFPageLabelStyle(style: .decimal, start: 1, prefix: "A-")
        #expect(style.label(for: 4) == "A-5")
    }

    @Test("a style of none produces no label at all")
    func noStyle() {
        // Some documents deliberately leave a page range unlabelled. Producing
        // "1" there would invent a number the document declined to state.
        #expect(PDFPageLabelStyle(style: .none).label(for: 0) == nil)
    }

    @Test("an invalid start is treated as 1")
    func invalidStart() {
        // A `/St` of 0 or below is invalid. Rendering it would produce "0" or a
        // negative page number, which is worse than restarting from 1: the reader
        // would say "page 0" out loud.
        #expect(PDFPageLabelStyle(style: .decimal, start: 0).label(for: 0) == "1")
        #expect(PDFPageLabelStyle(style: .decimal, start: -5).label(for: 2) == "3")
    }
}

@Suite("PDF content scanner")
struct PDFContentScannerTests {
    @Test("recognises the four text-showing operators")
    func recognisesOperators() {
        #expect(PDFContentScanner.containsTextOperator(Array("BT /F1 12 Tf (hi) Tj ET".utf8)))
        #expect(PDFContentScanner.containsTextOperator(Array("[(a) -20 (b)] TJ".utf8)))
        #expect(PDFContentScanner.containsTextOperator(Array("(x) '".utf8)))
        #expect(PDFContentScanner.containsTextOperator(Array("(x) \"".utf8)))
    }

    @Test("does not mistake a word containing an operator's letters for one")
    func rejectsSubstrings() {
        // The image stream of a scanned page can contain any bytes at all, so
        // matching without a token boundary reports text on a scan.
        #expect(!PDFContentScanner.containsTextOperator(Array("/Tjunk".utf8)))
        #expect(!PDFContentScanner.containsTextOperator(Array("xTj".utf8)))
        #expect(!PDFContentScanner.containsTextOperator(Array("/TJFont".utf8)))
    }

    @Test("does not look inside a string literal")
    func ignoresStringContents() {
        // A caption reading "(see Tj)" must not make a scanned page look textual.
        #expect(!PDFContentScanner.containsTextOperator(Array("q (see Tj) Q".utf8)))
        #expect(!PDFContentScanner.containsTextOperator(Array("q <546A> Q".utf8)))
    }

    @Test("a page with only graphics is not textual")
    func graphicsOnly() {
        let body = "q 612 0 0 792 0 0 cm /Im0 Do Q 1 0 0 RG 5 w 10 10 m 100 100 l S"
        #expect(!PDFContentScanner.containsTextOperator([UInt8](body.utf8)))
    }

    @Test("decodes ASCIIHex")
    func asciiHex() throws {
        #expect(PDFContentScanner.asciiHexDecode(Array("48656C6C6F>".utf8)) == Array("Hello".utf8))
        // An odd trailing digit is padded with a zero, per the spec.
        #expect(PDFContentScanner.asciiHexDecode(Array("4>".utf8)) == [0x40])
    }

    @Test("decodes RunLength")
    func runLength() throws {
        // 2 = copy the next 3 bytes; 254 = repeat the next byte 3 times; 128 ends.
        let encoded: [UInt8] = [2, 0x41, 0x42, 0x43, 254, 0x5A, 128]
        #expect(PDFContentScanner.runLengthDecode(encoded) == Array("ABCZZZ".utf8))
    }

    @Test("decodes ASCII85")
    func ascii85() throws {
        // The canonical example from the specification: "Man " encodes to "9jqo^".
        #expect(PDFContentScanner.ascii85Decode(Array("9jqo^".utf8)) == Array("Man ".utf8))
        // A short final group is padded and emits fewer bytes.
        #expect(PDFContentScanner.ascii85Decode(Array("z~>".utf8)) == [0, 0, 0, 0])
    }
}

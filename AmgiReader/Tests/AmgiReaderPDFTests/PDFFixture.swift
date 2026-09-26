import Compression
import Foundation
@testable import AmgiReaderPDF

/// Builds small, structurally valid PDFs for tests.
///
/// Written by hand rather than generated, so a failure points at a specific
/// byte rather than at whatever a PDF library happened to emit. The
/// cross-reference offsets are **computed** as the document is assembled, not
/// typed in: a fixture with plausible-looking but wrong offsets would pass
/// through the object-scan recovery and never exercise the table at all, which
/// is the thing most worth testing.
enum PDFFixture {
    /// Accumulates a document and records where each object landed.
    private struct Builder {
        private(set) var bytes: [UInt8] = []
        private(set) var offsets: [Int: Int] = [:]

        mutating func append(_ text: String) {
            bytes.append(contentsOf: text.utf8)
        }

        mutating func append(_ raw: [UInt8]) {
            bytes.append(contentsOf: raw)
        }

        /// Starts a document.
        ///
        /// The binary comment line is appended as explicit bytes because
        /// `"\u{E2}"` would be UTF-8 *encoded* — two bytes, not the one the
        /// marker is made of — and the resulting header would not be the header
        /// a real file has.
        static func header() -> [UInt8] {
            var out: [UInt8] = Array("%PDF-1.7\n%".utf8)
            out.append(contentsOf: [0xE2, 0xE3, 0xCF, 0xD3])
            out.append(0x0A)
            return out
        }

        mutating func addObject(_ number: Int, _ body: String) {
            offsets[number] = bytes.count
            append("\(number) 0 obj\n\(body)\nendobj\n")
        }

        /// Writes the cross-reference table and trailer.
        mutating func finish(root: Int, size: Int, extraTrailer: String = "", fileID: String? = "<0102>") {
            let xrefOffset = bytes.count
            var table = "xref\n0 \(size)\n0000000000 65535 f \n"
            for number in 1..<size {
                let offset = offsets[number] ?? 0
                table += String(format: "%010d 00000 n \n", offset)
            }
            let identity = fileID.map { "/ID [\($0) \($0)] " } ?? ""
            append(table)
            append("trailer\n<< /Size \(size) /Root \(root) 0 R \(identity)\(extraTrailer) >>\n")
            append("startxref\n\(xrefOffset)\n%%EOF\n")
        }
    }

    /// A one-page document with a classic cross-reference table.
    static func classicDocument(
        title: String = "Test Document",
        pageWidth: Int = 612,
        pageHeight: Int = 792
    ) -> [UInt8] {
        var builder = Builder()
        builder.append(Builder.header())
        builder.addObject(1, "<< /Type /Catalog /Pages 2 0 R >>")
        builder.addObject(2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
        builder.addObject(3, """
        << /Type /Page /Parent 2 0 R /MediaBox [0 0 \(pageWidth) \(pageHeight)] \
        /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>
        """)
        let content = "BT /F1 24 Tf 72 700 Td (\(title)) Tj ET"
        builder.addObject(4, "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream")
        builder.addObject(5, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
        builder.finish(root: 1, size: 6)
        return builder.bytes
    }

    /// A two-page document, for tests that need more than one page.
    static func twoPageDocument() -> [UInt8] {
        var builder = Builder()
        builder.append(Builder.header())
        builder.addObject(1, "<< /Type /Catalog /Pages 2 0 R >>")
        builder.addObject(2, "<< /Type /Pages /Kids [3 0 R 5 0 R] /Count 2 >>")
        builder.addObject(3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R >>")
        let one = "BT /F1 24 Tf 72 700 Td (Page one) Tj ET"
        builder.addObject(4, "<< /Length \(one.utf8.count) >>\nstream\n\(one)\nendstream")
        builder.addObject(5, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 6 0 R >>")
        let two = "BT /F1 24 Tf 72 700 Td (Page two) Tj ET"
        builder.addObject(6, "<< /Length \(two.utf8.count) >>\nstream\n\(two)\nendstream")
        builder.finish(root: 1, size: 7)
        return builder.bytes
    }

    /// A document whose cross-reference offsets are deliberately wrong, which is
    /// common in the wild and must be recovered from by the object scan.
    static func documentWithBrokenXref() -> [UInt8] {
        var builder = Builder()
        builder.append("%PDF-1.7\n")
        builder.addObject(1, "<< /Type /Catalog /Pages 2 0 R >>")
        builder.addObject(2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
        builder.addObject(3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>")
        let xrefOffset = builder.bytes.count
        // Every offset points past the end of the file. A reader that trusts
        // the table cannot open this; a reader that scans for objects can.
        builder.append("xref\n0 4\n0000000000 65535 f \n0000009999 00000 n \n0000009999 00000 n \n0000009999 00000 n \n")
        builder.append("trailer\n<< /Size 4 /Root 1 0 R >>\n")
        builder.append("startxref\n\(xrefOffset)\n%%EOF\n")
        return builder.bytes
    }

    /// A document with an `/Encrypt` entry, which must be refused for
    /// annotation rather than corrupted.
    static func encryptedDocument() -> [UInt8] {
        var builder = Builder()
        builder.append("%PDF-1.7\n")
        builder.addObject(1, "<< /Type /Catalog /Pages 2 0 R >>")
        builder.addObject(2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
        builder.addObject(3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>")
        let xrefOffset = builder.bytes.count
        builder.append("xref\n0 4\n0000000000 65535 f \n0000000009 00000 n \n0000000056 00000 n \n0000000113 00000 n \n")
        builder.append("trailer\n<< /Size 4 /Root 1 0 R /Encrypt 4 0 R >>\n")
        builder.append("startxref\n\(xrefOffset)\n%%EOF\n")
        return builder.bytes
    }

    /// A document whose cross-reference table is a compressed stream rather
    /// than plain text, which is what PDF 1.5 and later producers emit.
    ///
    /// The payload is a zlib stream because that is what a real `/FlateDecode`
    /// cross-reference stream contains, and the difference matters: the
    /// platform's DEFLATE codec reads bare DEFLATE, so a reader that forgets
    /// the two-byte zlib header decodes this into plausible garbage rather than
    /// failing.
    static func documentWithXrefStream() -> [UInt8] {
        // Five objects: catalogue, page tree, page, content stream, font. The
        // xref stream itself is object 6, and object 0 is the free head.
        //
        // The content stream's `/Length` is computed rather than written by hand.
        // PDFKit reads `/Length` literally and our own parser repairs a
        // disagreement, so a fixture with the wrong number would pass here and
        // fail in Preview — which is the opposite of what a fixture is for.
        let content = "BT /F1 24 Tf 72 700 Td (Streamed) Tj ET"
        let bodies: [(Int, String)] = [
            (1, "<< /Type /Catalog /Pages 2 0 R >>"),
            (2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            (
                3,
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R "
                    + "/Resources << /Font << /F1 5 0 R >> >> >>"
            ),
            (4, "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream"),
            (5, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"),
        ]
        // A single pass suffices. The cross-reference stream is written last, so
        // nothing preceding it can be affected by how long it turns out to be,
        // and its own offset is known before its payload is built: the row width
        // is fixed at `/W [1 8 2]`, so a longer offset number does not change the
        // payload's shape.
        var bytes = Builder.header()
        var offsets: [Int: Int] = [:]
        for (number, body) in bodies {
            offsets[number] = bytes.count
            bytes.append(contentsOf: Array("\(number) 0 obj\n\(body)\nendobj\n".utf8))
        }
        let xrefObjectNumber = 6
        offsets[xrefObjectNumber] = bytes.count

        // One row per object, 11 bytes: a 1-byte type, an 8-byte offset and a
        // 2-byte generation.
        var payload: [UInt8] = []
        func appendRow(type: UInt8, offset: Int, generation: UInt16) {
            payload.append(type)
            for shift in stride(from: 56, through: 0, by: -8) {
                payload.append(UInt8(offset >> shift & 0xFF))
            }
            payload.append(UInt8(generation >> 8 & 0xFF))
            payload.append(UInt8(generation & 0xFF))
        }
        // Object 0 is the head of the free list: type 0, pointing at itself with
        // the generation that marks the list as terminated.
        appendRow(type: 0, offset: 0, generation: 65_535)
        for number in 1...xrefObjectNumber {
            appendRow(type: 1, offset: offsets[number]!, generation: 0)
        }

        // The payload is zlib-wrapped, as a real `/FlateDecode` stream is. That
        // wrapper is the thing a reader most easily gets wrong: the platform's
        // DEFLATE codec decodes the bare form and returns plausible garbage for
        // the wrapped one rather than failing.
        let compressed = zlibCompress(payload)
        let dictionary = "<< /Type /XRef /Size 7 /Root 1 0 R /W [1 8 2] /Index [0 7] "
            + "/Filter /FlateDecode /Length \(compressed.count) >>"
        bytes.append(contentsOf: Array(
            "\(xrefObjectNumber) 0 obj\n\(dictionary)\nstream\n".utf8
        ))
        bytes.append(contentsOf: compressed)
        bytes.append(contentsOf: Array("\nendstream\nendobj\n".utf8))
        bytes.append(contentsOf: Array(
            "startxref\n\(offsets[xrefObjectNumber]!)\n%%EOF\n".utf8
        ))
        return bytes
    }

    /// Compresses with a zlib wrapper, as a PDF `/FlateDecode` stream has.
    private static func zlibCompress(_ data: [UInt8]) -> [UInt8] {
        // zlib header: DEFLATE with a 32K window, and the check value that
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
        // Adler-32 of the uncompressed data, big-endian.
        let checksum = adler32(data)
        out.append(contentsOf: [
            UInt8(checksum >> 24 & 0xFF), UInt8(checksum >> 16 & 0xFF),
            UInt8(checksum >> 8 & 0xFF), UInt8(checksum & 0xFF),
        ])
        return out
    }

    private static func adler32(_ data: [UInt8]) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % 65_521
            b = (b + a) % 65_521
        }
        return b << 16 | a
    }

    /// An annotation object in the shape Preview writes.
    static func highlightAnnotation(
        rect: PDFRect,
        contents: String,
        page: PDFReference,
        name: String = "amgi-\(UUID().uuidString)"
    ) -> PDFDictionary {
        var annotation = PDFDictionary()
        annotation["Type"] = .name("Annot")
        annotation["Subtype"] = .name("Highlight")
        annotation["Rect"] = .array([
            .integer(Int(rect.x)), .integer(Int(rect.y)),
            .integer(Int(rect.x + rect.width)), .integer(Int(rect.y + rect.height)),
        ])
        annotation["Contents"] = .string(bytes: PDFStringLiteral.utf16(contents).bytes, isHex: false)
        annotation["P"] = .reference(page)
        annotation["F"] = .integer(4)
        // `/NM` is the annotation's unique name, and the one entry every
        // conformant reader uses to identify it. Giving our annotations a
        // namespaced value is what lets them be recognised as ours rather than
        // as a stray highlight a reader added.
        annotation["NM"] = .string(bytes: Array(name.utf8), isHex: false)
        annotation["C"] = .array([.integer(1), .integer(1), .integer(0)])
        return annotation
    }
}

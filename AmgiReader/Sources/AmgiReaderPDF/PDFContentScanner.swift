/// Reports whether a page draws text, by reading its content stream.
///
/// This exists to answer one question honestly: *does this page have a text
/// layer, or is it a scan?* That question decides whether OCR is worth running,
/// and it has to be right in both directions — a false "no text" sends a
/// perfectly readable document through OCR, and a false "yes text" leaves a
/// scanned book producing cards full of empty strings.
///
/// The tempting shortcut is to look for a `/Font` resource. It is not good
/// enough in either direction: a scan with an OCR layer has fonts and a usable
/// text layer, and a born-digital page can reference a font it never uses.
///
/// Counting the text-showing operators in the content stream is the direct
/// question instead. A page with no `Tj`, `TJ`, `'` or `"` operator draws no
/// glyphs, so it has no text layer regardless of what its resources claim.
///
/// The limit is deliberate: this does not *extract* text, it detects its
/// presence. Decoding glyphs needs each font's encoding and widths map, which
/// PDFKit already implements and reimplementing would be neither smaller nor
/// better. Presence is enough to choose between "read it" and "OCR it".
public enum PDFContentScanner {
    /// What a page's content stream says about text.
    public struct TextPresence: Sendable, Equatable {
        /// Operators that show text were found.
        public var hasText: Bool
        /// The stream could not be read at all.
        ///
        /// Distinct from "no text": a stream in a filter this scanner does not
        /// implement might well contain text, so it must not be reported as a
        /// scan. Callers treat it as "assume text", which costs a wasted OCR
        /// pass at worst and a wrong "this is a scan" verdict never.
        public var wasUnreadable: Bool

        public static let hasTextOnly = TextPresence(hasText: true, wasUnreadable: false)
        public static let noText = TextPresence(hasText: false, wasUnreadable: false)
        public static let unreadable = TextPresence(hasText: false, wasUnreadable: true)
    }

    /// Inspects one page.
    public static func textPresence(
        of page: PDFPageReference,
        in file: PDFAppendableFile
    ) -> TextPresence {
        var sawAnyStream = false
        for bytes in contentStreams(of: page, in: file) {
            sawAnyStream = true
            if containsTextOperator(bytes) {
                return .hasTextOnly
            }
        }
        // A page with no content stream at all is a legitimately blank page, not
        // an unreadable one. A page whose stream exists but could not be
        // decoded is unreadable, and must not be called a scan.
        return sawAnyStream ? .noText : .unreadable
    }

    /// A page's content streams, decoded, in the order they are concatenated.
    ///
    /// `/Contents` is either one stream or an array of streams that are
    /// concatenated as if they were one. A page split across several streams is
    /// unusual but legal, and treating only the first as the whole page would
    /// report "no text" for a page that has some.
    ///
    /// A stream that cannot be decoded is *omitted* rather than passed through
    /// raw. Handing compressed bytes to a caller that scans them for operators
    /// finds nothing and reports no text, which for a born-digital page means
    /// being mistaken for a scan.
    public static func contentStreams(
        of page: PDFPageReference,
        in file: PDFAppendableFile
    ) -> [[UInt8]] {
        let contents = file.resolve(page.dictionary["Contents"] ?? .null)
        let entries = contents.asArray ?? [contents]
        return entries.compactMap { entry in
            guard let stream = file.resolve(entry).streamValue else { return nil }
            return decode(stream)
        }
    }

    /// Applies a stream's filter chain.
    static func decode(_ stream: PDFStream) -> [UInt8]? {
        var bytes = stream.rawBytes
        // `/Filter` is a single name or an array naming the chain in order.
        let filters = filterNames(stream.dictionary["Filter"])
        guard !filters.isEmpty else { return bytes }
        for filter in filters {
            switch filter {
            case "FlateDecode", "Fl":
                guard let inflated = PDFInflate.decode(bytes) else { return nil }
                bytes = inflated
            case "ASCIIHexDecode", "AHx":
                guard let decoded = asciiHexDecode(bytes) else { return nil }
                bytes = decoded
            case "ASCII85Decode", "A85":
                guard let decoded = ascii85Decode(bytes) else { return nil }
                bytes = decoded
            case "LZWDecode", "LZW":
                // Not implemented. Reported as unreadable rather than guessed
                // at: LZW appears in older documents, and returning the
                // compressed bytes would find no operators and misreport a
                // perfectly textual page as a scan.
                return nil
            case "RunLengthDecode", "RL":
                guard let decoded = runLengthDecode(bytes) else { return nil }
                bytes = decoded
            case "DCTDecode", "JPXDecode", "JBIG2Decode", "CCITTFaxDecode":
                // An image codec. The stream is a picture, so there is no text
                // in it by construction.
                return []
            default:
                return nil
            }
        }
        return bytes
    }

    private static func filterNames(_ object: PDFObject?) -> [String] {
        guard let object else { return [] }
        if let name = object.asName { return [name] }
        return (object.asArray ?? []).compactMap(\.asName)
    }

    /// Whether a decoded content stream shows any text.
    ///
    /// A lexical scan for the four text-showing operators, requiring each to be
    /// a standalone token. Matching the bytes alone would false-positive on any
    /// string or name containing those letters — `/Tj` inside a font name, a
    /// literal `(Tj)` in a caption — and report text on a scanned page whose
    /// image stream happens to contain those bytes.
    static func containsTextOperator(_ bytes: [UInt8]) -> Bool {
        let operators: [[UInt8]] = [
            Array("Tj".utf8), Array("TJ".utf8),
            Array("'".utf8), Array("\"".utf8),
        ]
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            for op in operators where matches(op, in: bytes, at: index) {
                return true
            }
            // Step over a string literal whole, so its contents are never
            // mistaken for operators.
            if byte == 0x28 {  // '('
                index = skipLiteralString(bytes, from: index)
                continue
            }
            if byte == 0x3C, index + 1 < bytes.count, bytes[index + 1] != 0x3C {
                index = skipHexString(bytes, from: index)
                continue
            }
            index += 1
        }
        return false
    }

    private static func matches(_ op: [UInt8], in bytes: [UInt8], at index: Int) -> Bool {
        guard index + op.count <= bytes.count else { return false }
        guard Array(bytes[index..<(index + op.count)]) == op else { return false }
        // The byte before must end a token, or this is the tail of a longer
        // word. The byte after must too, or `Tjunk` would match.
        if index > 0 {
            let before = bytes[index - 1]
            if before > 0x20 && !PDFByteCursor.isDelimiterByte(before) { return false }
        }
        let afterIndex = index + op.count
        if afterIndex < bytes.count {
            let after = bytes[afterIndex]
            if after > 0x20 && !PDFByteCursor.isDelimiterByte(after) { return false }
        }
        return true
    }

    private static func skipLiteralString(_ bytes: [UInt8], from start: Int) -> Int {
        var index = start + 1
        var depth = 1
        while index < bytes.count, depth > 0 {
            switch bytes[index] {
            case 0x5C:  // backslash escape
                index += 1
            case 0x28:
                depth += 1
            case 0x29:
                depth -= 1
            default:
                break
            }
            index += 1
        }
        return index
    }

    private static func skipHexString(_ bytes: [UInt8], from start: Int) -> Int {
        var index = start + 1
        while index < bytes.count, bytes[index] != 0x3E { index += 1 }
        return index + 1
    }

    // MARK: - Filters

    static func asciiHexDecode(_ bytes: [UInt8]) -> [UInt8]? {
        var out: [UInt8] = []
        var high: UInt8?
        for byte in bytes {
            if byte == 0x3E { break }  // '>' ends the data
            guard let value = PDFByteCursor.hexValue(byte) else { continue }
            if let pending = high {
                out.append(pending << 4 | value)
                high = nil
            } else {
                high = value
            }
        }
        // An odd trailing digit is padded with a zero, per the spec.
        if let high { out.append(high << 4) }
        return out
    }

    static func ascii85Decode(_ bytes: [UInt8]) -> [UInt8]? {
        var out: [UInt8] = []
        var group: [UInt32] = []
        var index = 0
        // An optional `<~` introducer.
        if bytes.count >= 2, bytes[0] == 0x3C, bytes[1] == 0x7E { index = 2 }

        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x7E { break }  // '~' begins the terminator
            if byte == 0x7A, group.isEmpty {  // 'z' is shorthand for four zeros
                out.append(contentsOf: [0, 0, 0, 0])
                index += 1
                continue
            }
            guard byte > 0x20, !PDFByteCursor.isDelimiterByte(byte) else {
                index += 1
                continue
            }
            guard let value = PDFByteCursor.base85Value(byte) else { return nil }
            group.append(UInt32(value))
            if group.count == 5 {
                var value32: UInt32 = 0
                for digit in group { value32 = value32 &* 85 &+ UInt32(digit) }
                out.append(UInt8(value32 >> 24 & 0xFF))
                out.append(UInt8(value32 >> 16 & 0xFF))
                out.append(UInt8(value32 >> 8 & 0xFF))
                out.append(UInt8(value32 & 0xFF))
                group.removeAll(keepingCapacity: true)
            }
            index += 1
        }
        // A short final group is padded with 'u' (84) to five digits and emits
        // one byte fewer than a full group.
        if !group.isEmpty {
            let missing = 5 - group.count
            var value32: UInt32 = 0
            for digit in group { value32 = value32 &* 85 &+ UInt32(digit) }
            for _ in 0..<missing { value32 = value32 &* 85 &+ 84 }
            let full = [
                UInt8(value32 >> 24 & 0xFF), UInt8(value32 >> 16 & 0xFF),
                UInt8(value32 >> 8 & 0xFF), UInt8(value32 & 0xFF),
            ]
            out.append(contentsOf: full.prefix(4 - missing))
        }
        return out
    }

    static func runLengthDecode(_ bytes: [UInt8]) -> [UInt8]? {
        var out: [UInt8] = []
        var index = 0
        while index < bytes.count {
            let length = Int(bytes[index])
            index += 1
            if length == 128 { break }  // end of data
            if length < 128 {
                let count = length + 1
                guard index + count <= bytes.count else { return nil }
                out.append(contentsOf: bytes[index..<(index + count)])
                index += count
            } else {
                guard index < bytes.count else { return nil }
                let count = 257 - length
                out.append(contentsOf: [UInt8](repeating: bytes[index], count: count))
                index += 1
            }
        }
        return out
    }
}

extension PDFByteCursor {
    /// The 5-bit value of an ASCII85 digit, or nil if it is not one.
    static func base85Value(_ byte: UInt8) -> UInt8? {
        // '!' through 'u' are the digits 0 through 84.
        guard byte >= 0x21, byte <= 0x75 else { return nil }
        return byte - 0x21
    }
}

extension PDFObject {
    /// The stream payload, if this value is one.
    var streamValue: PDFStream? {
        if case .stream(let stream) = self { return stream }
        return nil
    }
}

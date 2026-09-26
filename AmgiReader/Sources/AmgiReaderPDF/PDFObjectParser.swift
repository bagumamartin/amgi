public import Foundation

/// Parses a single indirect object starting at the cursor.
public enum PDFObjectParser {
    public enum ParseFailure: Error, Equatable {
        case unexpectedEnd
        case unknownToken
    }

    /// Parses one object. Returns nil at end of input.
    public static func parseObject(_ cursor: inout PDFByteCursor) throws -> PDFObject? {
        cursor.skipWhitespace()
        guard let byte = cursor.peek() else { return nil }

        switch byte {
        case 0x2F:  // '/'
            guard let name = cursor.readName() else { throw ParseFailure.unknownToken }
            return .name(name)
        case 0x28:  // '('
            guard let literal = cursor.readLiteralString() else {
                throw ParseFailure.unexpectedEnd
            }
            return .string(bytes: literal.bytes, isHex: literal.isHex)
        case 0x3C:  // '<'
            if cursor.peek(1) == 0x3C {
                return try parseDictionary(&cursor)
            }
            guard let hex = cursor.readHexString() else { throw ParseFailure.unexpectedEnd }
            return .string(bytes: hex.bytes, isHex: true)
        case 0x5B:  // '['
            return try parseArray(&cursor)
        case 0x5D, 0x3E:  // stray ']' or '>'
            return .null
        case 0x7B, 0x7D:  // '{' '}' are PostScript function bodies: skip
            _ = cursor.readKeyword()
            return .null
        default:
            break
        }

        // Numbers and keywords are lexically indistinguishable — `true`, `6`
        // and `-3.5` are all runs of "regular" characters — so the decision
        // has to be made from the first byte rather than by trying one and
        // falling back to the other. Getting this backwards is quiet: reading a
        // reference as a keyword turns every `1 0 R` into the name "1", which
        // leaves the document parsing cleanly and with no page tree at all.
        if byte >= 0x30, byte <= 0x39 || byte == 0x2D || byte == 0x2B || byte == 0x2E {
            return try parseNumber(&cursor, firstByte: byte)
        }

        if let keyword = cursor.readKeyword() {
            switch keyword {
            case "true": return .boolean(true)
            case "false": return .boolean(false)
            case "null": return .null
            default:
                // A bare word that is not a keyword. Real PDFs contain these
                // from broken generators; treating them as a name is the
                // lenient-reader behaviour and keeps parsing aligned.
                return .name(keyword)
            }
        }

        throw ParseFailure.unknownToken
    }

    /// Parses a number, or an indirect reference `N G R`.
    ///
    /// A reference and a plain integer are told apart by what follows: an
    /// integer is `N`, a reference is `N G R`, and a real has a sign or a
    /// decimal point.
    private static func parseNumber(
        _ cursor: inout PDFByteCursor,
        firstByte: UInt8
    ) throws -> PDFObject {
        // A signed or fractional real with no leading digit: `-3.2`, `+.5`.
        guard firstByte >= 0x30, firstByte <= 0x39 else {
            guard let value = readReal(from: &cursor, integerPrefix: nil) else {
                throw ParseFailure.unknownToken
            }
            return .real(value)
        }

        guard let first = cursor.readDigits() else {
            throw ParseFailure.unknownToken
        }
        let afterFirst = cursor.index

        if let second = cursor.readDigits() {
            let mark = cursor.index
            cursor.skipWhitespace()
            // `R` must be followed by a real delimiter or end of input. Without
            // that check, the `1 0 R` inside a content stream's inline data would
            // be read as a reference and desynchronise the whole stream.
            let afterR = cursor.peek(1)
            if cursor.peek() == 0x52,
               afterR == nil || afterR! <= 0x20 || PDFByteCursor.isDelimiterByte(afterR!) {
                cursor.seek(to: cursor.index + 1)
                return .reference(PDFReference(number: first, generation: second))
            }
            cursor.seek(to: mark)
        }
        cursor.seek(to: afterFirst)

        // A real number: `12.5`, `4.`, or a plain integer.
        if let value = readReal(from: &cursor, integerPrefix: first) { return .real(value) }
        return .integer(first)
    }

    private static func readReal(
        from cursor: inout PDFByteCursor,
        integerPrefix: Int?
    ) -> Double? {
        if integerPrefix == nil { cursor.skipWhitespace() }
        let start = cursor.index
        if let byte = cursor.peek(), byte == 0x2D || byte == 0x2B || byte == 0x2E {
            cursor.seek(to: cursor.index + 1)
        }
        var sawDigit = false
        while let byte = cursor.peek() {
            if byte >= 0x30, byte <= 0x39 {
                sawDigit = true
                cursor.seek(to: cursor.index + 1)
            } else {
                break
            }
        }
        if cursor.peek() == 0x2E {
            sawDigit = true
            cursor.seek(to: cursor.index + 1)
            while let byte = cursor.peek(), byte >= 0x30, byte <= 0x39 {
                cursor.seek(to: cursor.index + 1)
            }
        }
        guard sawDigit else { return nil }
        let text = String(decoding: cursor.bytes[start..<cursor.index], as: UTF8.self)
        return Double(text)
    }

    private static func parseDictionary(_ cursor: inout PDFByteCursor) throws -> PDFObject {
        // Consume '<<'
        cursor.seek(to: cursor.index + 2)
        var dictionary = PDFDictionary()
        while true {
            cursor.skipWhitespace()
            guard let byte = cursor.peek() else { throw ParseFailure.unexpectedEnd }
            if byte == 0x3E, cursor.peek(1) == 0x3E {
                cursor.seek(to: cursor.index + 2)
                break
            }
            guard let key = cursor.readName() else {
                // Not a name: skip a byte and keep going, so one malformed
                // entry cannot make the rest of the dictionary unreadable.
                cursor.seek(to: cursor.index + 1)
                continue
            }
            guard let value = try parseObject(&cursor) else { break }
            dictionary[key] = value
        }

        // A `stream` keyword directly after a dictionary makes this a stream
        // object. The bytes between `stream` and `endstream` are carried
        // through untouched — they may be compressed in a way we do not model.
        let mark = cursor.index
        if cursor.readKeyword() == "stream" {
            if cursor.peek() == 0x0D { cursor.seek(to: cursor.index + 1) }
            if cursor.peek() == 0x0A { cursor.seek(to: cursor.index + 1) }
            let start = cursor.index
            if let end = findEndstream(from: start, in: cursor.bytes) {
                let raw = Array(cursor.bytes[start..<end])
                cursor.seek(to: end)
                if cursor.readKeyword() == "endstream" {
                    // Repair the length entry if it disagrees with what is
                    // actually there, so a later rewrite writes a stream the
                    // reader will accept.
                    if let declared = dictionary["Length"]?.asInteger,
                       declared != raw.count
                    {
                        dictionary["Length"] = .integer(raw.count)
                    }
                    return .stream(PDFStream(dictionary: dictionary, rawBytes: raw))
                }
                return .stream(PDFStream(dictionary: dictionary, rawBytes: raw))
            }
            cursor.seek(to: start)
        } else {
            cursor.seek(to: mark)
        }

        return .dictionary(dictionary)
    }

    private static func findEndstream(from start: Int, in bytes: [UInt8]) -> Int? {
        let needle = Array("endstream".utf8)
        var index = start
        while index + needle.count <= bytes.count {
            if Array(bytes[index..<(index + needle.count)]) == needle { return index }
            index += 1
        }
        return nil
    }

    private static func parseArray(_ cursor: inout PDFByteCursor) throws -> PDFObject {
        cursor.seek(to: cursor.index + 1)  // '['
        var elements: [PDFObject] = []
        while true {
            cursor.skipWhitespace()
            guard let byte = cursor.peek() else { throw ParseFailure.unexpectedEnd }
            if byte == 0x5D {  // ']'
                cursor.seek(to: cursor.index + 1)
                return .array(elements)
            }
            if let element = try parseObject(&cursor) {
                elements.append(element)
            }
        }
    }
}

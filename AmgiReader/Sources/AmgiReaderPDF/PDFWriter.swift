public import Foundation

/// Writes a `PDFObject` back to bytes.
///
/// The output is deliberately plain: classic syntax, no compression, ASCII
/// names. That matters because this writer exists to *append* an update, and
/// an update's whole safety argument is that the bytes it adds are simple
/// enough to be obviously correct. A compressed or object-streamed update
/// would be smaller and far harder to verify.
public enum PDFWriter {
    /// Serialises an object as it appears inside a dictionary or array —
    /// that is, without the `N G obj … endobj` wrapper.
    public static func serialize(_ object: PDFObject) -> [UInt8] {
        var out: [UInt8] = []
        append(object, to: &out)
        return out
    }

    /// Serialises a complete indirect object.
    public static func serializeIndirect(
        _ object: PDFObject,
        number: Int,
        generation: Int = 0
    ) -> [UInt8] {
        var out: [UInt8] = []
        out.append(contentsOf: "\(number) \(generation) obj\n".utf8)
        append(object, to: &out)
        out.append(contentsOf: "\nendobj\n".utf8)
        return out
    }

    private static func append(_ object: PDFObject, to out: inout [UInt8]) {
        switch object {
        case .null:
            out.append(contentsOf: "null".utf8)
        case .boolean(let value):
            out.append(contentsOf: (value ? "true" : "false").utf8)
        case .integer(let value):
            out.append(contentsOf: String(value).utf8)
        case .real(let value):
            out.append(contentsOf: formatReal(value).utf8)
        case .name(let name):
            appendName(name, to: &out)
        case .string(let bytes, let isHex):
            out.append(contentsOf: escape(PDFStringLiteral(bytes: bytes, isHex: isHex)).utf8)
        case .array(let elements):
            out.append(contentsOf: "[".utf8)
            for (index, element) in elements.enumerated() {
                if index > 0 { out.append(contentsOf: " ".utf8) }
                append(element, to: &out)
            }
            out.append(contentsOf: "]".utf8)
        case .dictionary(let dictionary):
            appendDictionary(dictionary, to: &out)
        case .stream(let stream):
            appendDictionary(stream.dictionary, to: &out)
            out.append(contentsOf: "\nstream\n".utf8)
            out.append(contentsOf: stream.rawBytes)
            out.append(contentsOf: "\nendstream".utf8)
        case .reference(let reference):
            out.append(contentsOf: "\(reference.number) \(reference.generation) R".utf8)
        }
    }

    private static func appendDictionary(_ dictionary: PDFDictionary, to out: inout [UInt8]) {
        out.append(contentsOf: "<<".utf8)
        var wroteSeparator = false
        for key in dictionary.order {
            guard let value = dictionary.entries[key] else { continue }
            if wroteSeparator { out.append(contentsOf: " ".utf8) }
            appendName(key, to: &out)
            out.append(contentsOf: " ".utf8)
            append(value, to: &out)
            wroteSeparator = true
        }
        // A single space so an empty dictionary is still `<< >>` with a gap,
        // which some lenient readers prefer over `<<>>`.
        out.append(contentsOf: (wroteSeparator ? " >>" : ">>").utf8)
    }

    /// Writes a name, escaping the characters that would otherwise terminate
    /// it or change its meaning.
    static func appendName(_ name: String, to out: inout [UInt8]) {
        out.append(0x2F)  // '/'
        for byte in name.utf8 {
            // Delimiters and whitespace must be escaped, as must `#` because
            // it introduces a hex escape. Everything else is passed through,
            // which keeps the output readable.
            let isRegular = (byte >= 0x21 && byte <= 0x7E)
            let needsEscape = byte < 0x21
                || byte > 0x7E
                || isDelimiter(byte)
                || byte == 0x23  // '#'
            if needsEscape {
                out.append(contentsOf: String(format: "#%02X", byte).utf8)
            } else {
                out.append(byte)
            }
        }
    }

    private static func isDelimiter(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x28, 0x29, 0x3C, 0x3E, 0x5B, 0x5D, 0x7B, 0x7D, 0x2F, 0x25:
            return true
        default:
            return false
        }
    }

    /// Writes a string, choosing hex when the bytes are not safely literal.
    static func escape(_ literal: PDFStringLiteral) -> String {
        let isPrintableASCII = literal.bytes.allSatisfy { $0 >= 0x20 && $0 <= 0x7E }
        if isPrintableASCII {
            var out = "("
            for byte in literal.bytes {
                switch byte {
                case 0x28, 0x29, 0x5C:  // ( ) backslash
                    out.append(contentsOf: "\\" + String(UnicodeScalar(byte)))
                default:
                    out.append(Character(UnicodeScalar(byte)))
                }
            }
            out.append(")")
            return out
        }
        // Anything outside printable ASCII goes out as hex, which has no
        // escaping rules to get wrong.
        var out = "<"
        for byte in literal.bytes {
            out.append(String(format: "%02X", byte))
        }
        out.append(">")
        return out
    }

    /// Formats a real so it is never mistaken for an integer on re-parse.
    static func formatReal(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        if value == value.rounded(), abs(value) < 1e15 {
            return String(format: "%.1f", value)
        }
        return String(format: "%.6f", value)
    }
}

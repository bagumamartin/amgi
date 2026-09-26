/// A cursor over PDF bytes.
///
/// The lexer is written against raw bytes rather than `String` on purpose:
/// PDF is a binary format where a string literal can contain bytes that are
/// not valid UTF-8, and decoding first would corrupt them. Only the pieces
/// that are genuinely text (names, numbers, keywords) become `String`.
public struct PDFByteCursor {
    public let bytes: [UInt8]
    public var index: Int

    public init(_ bytes: [UInt8], from start: Int = 0) {
        self.bytes = bytes
        self.index = start
    }

    public var isAtEnd: Bool { index >= bytes.count }
    public var remaining: Int { max(0, bytes.count - index) }

    public mutating func seek(to newIndex: Int) {
        index = min(max(0, newIndex), bytes.count)
    }

    public func peek(_ offset: Int = 0) -> UInt8? {
        let target = index + offset
        return target < bytes.count ? bytes[target] : nil
    }

    public mutating func skipWhitespace() {
        while let byte = peek() {
            if byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09
                || byte == 0x00 || byte == 0x0C {
                index += 1
            } else {
                return
            }
        }
    }

    /// Consumes and returns a bare keyword such as `obj` or `stream`.
    public mutating func readKeyword() -> String? {
        skipWhitespace()
        let start = index
        while let byte = peek(), Self.isRegular(byte) {
            index += 1
        }
        guard index > start else { return nil }
        return String(decoding: bytes[start..<index], as: UTF8.self)
    }

    public mutating func readName() -> String? {
        skipWhitespace()
        guard peek() == 0x2F else { return nil }  // '/'
        index += 1
        var out: [UInt8] = []
        while let byte = peek() {
            if byte == 0x23, let high = peek(1), let low = peek(2),
               let h = Self.hexValue(high), let l = Self.hexValue(low) {
                out.append(h << 4 | l)
                index += 3
                continue
            }
            // A name ends at whitespace or a delimiter.
            guard byte > 0x20, !Self.isDelimiterByte(byte) else { break }
            out.append(byte)
            index += 1
        }
        return String(decoding: out, as: UTF8.self)
    }

    public mutating func readLiteralString() -> PDFStringLiteral? {
        skipWhitespace()
        guard peek() == 0x28 else { return nil }  // '('
        index += 1
        var out: [UInt8] = []
        var depth = 1
        while let byte = peek() {
            index += 1
            switch byte {
            case 0x5C:  // backslash escape
                guard let escaped = peek() else { return nil }
                index += 1
                switch escaped {
                case 0x6E: out.append(0x0A)       // n
                case 0x72: out.append(0x0D)       // r
                case 0x74: out.append(0x09)       // t
                case 0x62: out.append(0x08)       // b
                case 0x66: out.append(0x0C)       // f
                case 0x28: out.append(0x28)       // (
                case 0x29: out.append(0x29)       // )
                case 0x5C: out.append(0x5C)       // backslash
                case 0x0D:                          // line continuation
                    if peek() == 0x0A { index += 1 }
                case 0x0A:
                    break
                default:
                    if let octal = Self.octalValue(escaped) {
                        out.append(octal)
                    } else {
                        out.append(escaped)
                    }
                }
            case 0x28:
                depth += 1
                out.append(byte)
            case 0x29:
                depth -= 1
                if depth == 0 { return PDFStringLiteral(bytes: out, isHex: false) }
                out.append(byte)
            default:
                out.append(byte)
            }
        }
        return nil
    }

    public mutating func readHexString() -> PDFStringLiteral? {
        skipWhitespace()
        guard peek() == 0x3C else { return nil }  // '<'
        index += 1
        var out: [UInt8] = []
        var high: UInt8?
        while let byte = peek() {
            index += 1
            if byte == 0x3E {  // '>'
                // An odd number of digits means the last nibble is treated as
                // if followed by a zero, per the spec.
                if let high, out.isEmpty || true {
                    out.append(high << 4)
                }
                return PDFStringLiteral(bytes: out, isHex: true)
            }
            guard let value = Self.hexValue(byte) else { continue }
            if let pending = high {
                out.append(pending << 4 | value)
                high = nil
            } else {
                high = value
            }
        }
        return nil
    }

    /// Reads a run of digits, leaving the cursor after them.
    public mutating func readDigits() -> Int? {
        skipWhitespace()
        let start = index
        while let byte = peek(), byte >= 0x30, byte <= 0x39 {
            index += 1
        }
        guard index > start else { return nil }
        return Int(String(decoding: bytes[start..<index], as: UTF8.self))
    }

    static func isRegular(_ byte: UInt8) -> Bool {
        byte > 0x20 && byte <= 0x7E && !isDelimiterByte(byte)
    }

    static func isDelimiterByte(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x28, 0x29, 0x3C, 0x3E, 0x5B, 0x5D, 0x7B, 0x7D, 0x2F, 0x25:
            return true
        default:
            return false
        }
    }

    static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: byte - 0x30
        case 0x41...0x46: byte - 0x41 + 10
        case 0x61...0x66: byte - 0x61 + 10
        default: nil
        }
    }

    private static func octalValue(_ byte: UInt8) -> UInt8? {
        guard byte >= 0x30, byte <= 0x37 else { return nil }
        return byte - 0x30
    }
}

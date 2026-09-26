/// An object in a PDF's object graph.
///
/// PDF is a graph of indirect objects, each written as
/// `N G obj … endobj` and located through a cross-reference table. Almost
/// everything the reader needs — the page tree, annotations, the catalog — is
/// an indirect object, because a cross-reference can only point at a whole
/// object, never at a value inside one.
///
/// Only the subset of the format that annotation actually needs is modelled
/// here. Real-world documents do contain things this does not represent
/// (content streams with inline images, unusual filters, encryption); the
/// parser's job is to *skip* what it does not understand rather than to
/// mis-model it, because a mis-modelled object corrupts a file on rewrite.
public indirect enum PDFObject: Sendable, Equatable {
    case null
    case boolean(Bool)
    case integer(Int)
    case real(Double)
    case string(bytes: [UInt8], isHex: Bool)
    case name(String)
    case array([PDFObject])
    case dictionary(PDFDictionary)
    /// A stream object: its dictionary plus raw (still encoded) bytes.
    case stream(PDFStream)
    /// An indirect reference: object `number`, generation `generation`.
    case reference(PDFReference)

    /// Whether this value is one that must be written as `N G obj`.
    ///
    /// Only a `reference` needs the indirection; everything else is written
    /// inline. Getting this backwards produces a file that still opens but
    /// whose structure is wrong in ways that surface much later.
    public var isIndirectOnly: Bool {
        if case .reference = self { return true }
        return false
    }

    public var asDictionary: PDFDictionary? {
        switch self {
        case .dictionary(let dictionary): dictionary
        case .stream(let stream): stream.dictionary
        default: nil
        }
    }

    public var asArray: [PDFObject]? {
        if case .array(let elements) = self { return elements }
        return nil
    }

    public var asName: String? {
        if case .name(let name) = self { return name }
        return nil
    }

    public var asInteger: Int? {
        if case .integer(let value) = self { return value }
        return nil
    }

    /// The value as a `Double`, whether it was written as an integer or a real.
    ///
    /// Rectangles in particular arrive as a mix of both, because a producer
    /// emits `612` for a whole number and `612.5` when it does not. Reading
    /// only `/Integer` would drop the fractional page of a rect.
    public var asNumber: Double? {
        switch self {
        case .integer(let value): Double(value)
        case .real(let value): value
        default: nil
        }
    }

    public var asReference: PDFReference? {
        if case .reference(let reference) = self { return reference }
        return nil
    }

    public var asBool: Bool? {
        if case .boolean(let value) = self { return value }
        return nil
    }
}

/// An indirect reference: `N G R`.
public struct PDFReference: Sendable, Equatable, Hashable, Codable, Comparable {
    public var number: Int
    public var generation: Int

    public init(number: Int, generation: Int = 0) {
        self.number = number
        self.generation = generation
    }

    public static func < (lhs: PDFReference, rhs: PDFReference) -> Bool {
        lhs.number == rhs.number
            ? lhs.generation < rhs.generation
            : lhs.number < rhs.number
    }
}

/// A PDF dictionary.
///
/// Insertion order is preserved because it costs nothing and makes diffing two
/// saved files meaningful; semantically a dictionary is unordered.
public struct PDFDictionary: Sendable, Equatable {
    public private(set) var entries: [String: PDFObject]
    public private(set) var order: [String]

    public init(_ entries: [String: PDFObject] = [:]) {
        self.entries = entries
        self.order = Array(entries.keys)
    }

    public subscript(key: String) -> PDFObject? {
        get { entries[key] }
        set {
            if let newValue {
                if entries[key] == nil { order.append(key) }
                entries[key] = newValue
            } else {
                entries.removeValue(forKey: key)
                order.removeAll { $0 == key }
            }
        }
    }

    public var keys: [String] { order }
    public var isEmpty: Bool { entries.isEmpty }

    public mutating func set(_ value: PDFObject?, for key: String) {
        self[key] = value
    }
}

/// A stream object.
///
/// `rawBytes` holds the *still-encoded* bytes. Annotation work never needs to
/// decode a content stream, and decoding one we cannot fully model is how a
/// rewrite silently corrupts a document — so the bytes are carried verbatim
/// and written back unchanged.
public struct PDFStream: Sendable, Equatable {
    public var dictionary: PDFDictionary
    public var rawBytes: [UInt8]

    public init(dictionary: PDFDictionary, rawBytes: [UInt8]) {
        self.dictionary = dictionary
        self.rawBytes = rawBytes
    }
}

/// A PDF string, which is a byte sequence rather than text.
///
/// Kept as bytes because PDF strings are not Unicode: they are either
/// literal bytes, hex bytes, or UTF-16BE with a byte-order mark. Decoding to
/// `String` on the way in loses information that matters for text strings, so
/// the conversion happens only where it is needed.
public struct PDFStringLiteral: Sendable, Equatable, Hashable {
    public var bytes: [UInt8]
    public var isHex: Bool

    public init(bytes: [UInt8], isHex: Bool) {
        self.bytes = bytes
        self.isHex = isHex
    }

    /// Decodes as PDFDocEncoding or UTF-16BE, whichever the bytes claim.
    ///
    /// A UTF-16BE string is marked by a leading `FE FF`; anything else is
    /// treated as PDFDocEncoding, which is single-byte and close enough to
    /// Latin-1 for the text annotations we round-trip.
    public var text: String {
        if bytes.count >= 2, bytes[0] == 0xFE, bytes[1] == 0xFF {
            var units: [UInt16] = []
            var index = 2
            while index + 1 < bytes.count {
                units.append(UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1]))
                index += 2
            }
            return String(decoding: units, as: UTF16.self)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Encodes a string as UTF-16BE with a byte-order mark.
    ///
    /// Preferred for anything the user typed, because it round-trips
    /// characters outside Latin-1 that PDFDocEncoding cannot represent.
    public static func utf16(_ text: String) -> PDFStringLiteral {
        var bytes: [UInt8] = [0xFE, 0xFF]
        for unit in text.utf16 {
            bytes.append(UInt8(unit >> 8 & 0xFF))
            bytes.append(UInt8(unit & 0xFF))
        }
        return PDFStringLiteral(bytes: bytes, isHex: false)
    }
}

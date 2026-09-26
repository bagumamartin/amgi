public import Foundation

/// A parsed PDF file, positioned so it can be appended to.
///
/// This is the type that makes concurrent annotation tractable. Rather than
/// loading a document model and writing it back, it keeps the file's bytes and
/// *appends* an update: new objects, a cross-reference table covering only what
/// changed, and a trailer pointing at the previous one with `/Prev`. The
/// original bytes are never touched, so:
///
/// - the file on disk is always a conformant PDF that Preview opens with our
///   annotations in place, with no export step
/// - two devices annotating produce two update sections rather than two
///   competing rewrites of one binary
/// - `PDFLineariser` can fold several such sections back into one file
///
/// The cost is that appended objects are never garbage-collected, so a heavily
/// annotated document grows. That is a property of the format, not of this
/// design; `PDFLineariser` is the answer when a compact file is wanted.
public final class PDFAppendableFile: @unchecked Sendable {
    public enum LoadError: Error, Equatable, LocalizedError {
        case unreadable
        case notAPDF
        case encrypted
        case malformedXref

        public var errorDescription: String? {
            switch self {
            case .unreadable: "The PDF could not be read."
            case .notAPDF: "This file is not a PDF."
            // Never attempt an update on an encrypted document: the strings
            // and streams in an incremental update would have to be encrypted
            // with the document's key, and writing them in the clear would
            // corrupt it while looking fine in our own reader.
            case .encrypted: "This PDF is encrypted, so it cannot be annotated."
            case .malformedXref: "This PDF's cross-reference information could not be read."
            }
        }
    }

    /// Every object number the cross-reference data and the object scan found,
    /// excluding those marked free.
    public var objectNumbers: [Int] {
        xrefEntries.keys.sorted()
    }

    /// The generation recorded for an object.
    public func generation(of number: Int) -> Int {
        xrefEntries[number]?.generation ?? 0
    }

    /// The file's bytes, exactly as read.
    ///
    /// An update is *not* applied to this type: appending is the caller's job,
    /// by concatenating the bytes `PDFIncrementalUpdate` produces onto these and
    /// reloading. Keeping the loaded document immutable means the offsets it
    /// resolved cannot drift away from the bytes they came from.
    public let bytes: [UInt8]
    /// The document catalogue, from the trailer.
    public let trailer: PDFDictionary
    /// Highest object number in use, so a new update starts after it.
    public let highestObjectNumber: Int
    /// The document's persistent identity, preserved across updates so
    /// readers can tell it is the same document.
    public let fileIdentifier: [UInt8]?

    /// Parsed offsets, by object number. Values are `(offset, generation)`.
    private var xrefEntries: [Int: (offset: Int, generation: Int)]
    /// Cache of resolved objects.
    private var objectCache: [Int: PDFObject] = [:]
    private let lock = NSLock()

    /// Object numbers the cross-reference data marks free.
    ///
    /// Kept separately from the absence of an entry because the difference is
    /// the whole point: a free object is one a reader must not display, even
    /// though its bytes are still in the file.
    public let freedObjectNumbers: Set<Int>

    /// Loads a file from disk.
    ///
    /// A factory rather than an initialiser because the byte-based
    /// initialiser is the designated one, and a class's designated
    /// initialiser may not delegate to another.
    public static func load(contentsOf url: URL) throws -> PDFAppendableFile {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw LoadError.unreadable
        }
        return try PDFAppendableFile(bytes: Array(data))
    }

    public init(bytes raw: [UInt8]) throws {
        guard raw.count > 8 else { throw LoadError.unreadable }
        // A PDF may carry up to 1024 bytes of junk before `%PDF-`, so the
        // header is searched for rather than required at offset zero.
        guard let headerRange = raw.firstRange(of: Array("%PDF-".utf8)) else {
            throw LoadError.notAPDF
        }
        self.bytes = raw
        self._headerOffset = headerRange.lowerBound

        guard let xref = PDFCrossReferenceTable.parse(bytes: raw, headerOffset: headerRange.lowerBound)
        else { throw LoadError.malformedXref }

        var entries = xref.entries
        self.freedObjectNumbers = xref.freed
        // A full scan is the safety net. Damaged cross-reference data is
        // extremely common — enough that every real reader falls back to it —
        // and without it, annotation would be offered on files whose offsets
        // are wrong and produce a corrupt append.
        let scanned = PDFCrossReferenceTable.scanForObjects(in: raw, from: headerRange.lowerBound)
        for (number, found) in scanned {
            // A freed number stays freed. Its bytes are still in the file — the
            // format never reclaims them — so without this the scan would
            // resurrect a deleted annotation and display it again, which is the
            // one outcome a deletion must not have.
            guard !freedObjectNumbers.contains(number) else { continue }
            // Trust the table only when the bytes at its offset really do open
            // that object. An offset that points somewhere else is worse than
            // no entry at all, because resolution would silently return the
            // wrong object's contents.
            if let existing = entries[number],
               PDFAppendableFile.opensObject(number, at: existing.offset, in: raw) {
                continue
            }
            entries[number] = found
        }
        self.xrefEntries = entries

        var mergedTrailer = xref.trailer
        // Later sections win, and a hybrid-reference file keeps its earlier
        // entries for the parts the xref stream did not carry.
        for partial in xref.mergedTrailers {
            for key in partial.keys where mergedTrailer[key] == nil {
                mergedTrailer[key] = partial[key]
            }
        }
        self.trailer = mergedTrailer

        if trailer["Encrypt"] != nil { throw LoadError.encrypted }

        self.highestObjectNumber = max(entries.keys.max() ?? 0, (trailer["Size"]?.asInteger ?? 0) - 1)
        if case .string(let idBytes, _)? = trailer["ID"]?.asArray?.first {
            self.fileIdentifier = idBytes
        } else {
            self.fileIdentifier = nil
        }
    }

    /// Whether the bytes at `offset` really begin `N G obj`.
    ///
    /// This is the check that makes a recovered cross-reference safe to append
    /// to. A wrong offset does not fail loudly — it resolves to a *different*
    /// object, or to bytes that do not parse — and the resulting annotation
    /// would be written into a document whose structure is now nonsense.
    private static func opensObject(_ number: Int, at offset: Int, in bytes: [UInt8]) -> Bool {
        guard offset >= 0, offset < bytes.count else { return false }
        var cursor = PDFByteCursor(bytes, from: offset)
        guard cursor.readDigits() == number,
              cursor.readDigits() != nil,
              cursor.readKeyword() == "obj"
        else { return false }
        return true
    }

    private var _headerOffset: Int = 0

    /// The byte offset of `%PDF-`.
    public var headerOffset: Int { _headerOffset }

    /// The offset of the last cross-reference section, which a new update's
    /// `/Prev` must point at.
    public var lastXrefOffset: Int? {
        PDFCrossReferenceTable.lastStartXref(in: bytes)
    }

    // MARK: - Object access

    /// Resolves an object by number, reading through the xref and parsing on
    /// first use.
    public func object(number: Int) -> PDFObject? {
        lock.lock()
        if let cached = objectCache[number] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        guard let entry = xrefEntries[number] else { return nil }
        var cursor = PDFByteCursor(bytes, from: entry.offset)
        // Each indirect object starts `N G obj`. Skip that preamble.
        guard cursor.readDigits() == number,
              cursor.readDigits() != nil,
              cursor.readKeyword() == "obj",
              let parsed = try? PDFObjectParser.parseObject(&cursor)
        else { return nil }

        lock.lock()
        objectCache[number] = parsed
        lock.unlock()
        return parsed
    }

    /// Resolves a reference.
    public func resolve(_ object: PDFObject) -> PDFObject {
        var current = object
        // Bounded so a cyclic `/Parent` chain cannot spin forever.
        var depth = 0
        while let reference = current.asReference, depth < 32 {
            current = self.object(number: reference.number) ?? .null
            depth += 1
        }
        return current
    }

    /// The document catalogue.
    public var catalog: PDFDictionary? {
        guard let root = trailer["Root"] else { return nil }
        return resolve(root).asDictionary
    }

    /// The page tree, flattened in reading order.
    ///
    /// Order matters: it is what "page 12" means, and a document with a
    /// correctly-constructed tree can still list pages out of order if the
    /// `/Kids` array is not sorted the way the reader expects.
    public var pages: [PDFPageReference] {
        guard let root = trailer["Root"] else { return [] }
        var out: [PDFPageReference] = []
        var visited: Set<Int> = []
        collectPages(from: resolve(root).asDictionary?["Pages"], into: &out, visited: &visited)
        return out
    }

    private func collectPages(
        from node: PDFObject?,
        into out: inout [PDFPageReference],
        visited: inout Set<Int>
    ) {
        guard let dictionary = resolve(node ?? .null).asDictionary else { return }
        let type = dictionary["Type"]?.asName

        if type == "Page", let reference = node?.asReference {
            out.append(PDFPageReference(reference: reference, dictionary: dictionary))
            return
        }
        // Guard against a `/Kids` cycle, which some damaged files contain and
        // which would otherwise recurse until the stack gave out.
        if let reference = node?.asReference {
            guard visited.insert(reference.number).inserted else { return }
        }
        let kids = resolve(dictionary["Kids"] ?? .null).asArray ?? []
        for kid in kids {
            collectPages(from: kid, into: &out, visited: &visited)
        }
    }

    /// The existing annotations on a page, in document order.
    public func annotations(on page: PDFPageReference) -> [PDFAnnotationRecord] {
        let annots = resolve(page.dictionary["Annots"] ?? .null).asArray ?? []
        return annots.compactMap { entry in
            guard let reference = entry.asReference,
                  let dictionary = object(number: reference.number)?.asDictionary
            else { return nil }
            return PDFAnnotationRecord(reference: reference, dictionary: dictionary)
        }
    }
}

/// A page, as an object reference plus its resolved dictionary.
public struct PDFPageReference: Sendable {
    public let reference: PDFReference
    public let dictionary: PDFDictionary

    /// The page's media box, in PDF user space.
    ///
    /// Inherited from the page tree when the page does not carry its own.
    /// Inheritance is the normal case: most producers put `/MediaBox` on the
    /// `/Pages` node and leave the leaves bare, so reading only the page would
    /// report "no size" for most of a real document.
    public func mediaBox(inheritingFrom ancestors: [PDFDictionary]) -> PDFRect? {
        if let own = PDFDictionary.rect(dictionary["MediaBox"]) {
            return PDFDictionary.normalised(own)
        }
        for ancestor in ancestors {
            if let inherited = PDFDictionary.rect(ancestor["MediaBox"]) {
                return PDFDictionary.normalised(inherited)
            }
        }
        return nil
    }

    /// The page's own media box, without consulting the page tree.
    public var mediaBox: PDFRect? {
        dictionary["MediaBox"].flatMap(PDFDictionary.rect).map(PDFDictionary.normalised)
    }
}

/// One annotation object already in the file.
public struct PDFAnnotationRecord: Sendable {
    public let reference: PDFReference
    public let dictionary: PDFDictionary

    public var subtype: String? { dictionary["Subtype"]?.asName }

    public var contents: String? {
        guard case .string(let bytes, let isHex)? = dictionary["Contents"] else { return nil }
        return PDFStringLiteral(bytes: bytes, isHex: isHex).text
    }

    public var rect: PDFRect? {
        dictionary["Rect"].flatMap(PDFDictionary.rect).map(PDFDictionary.normalised)
    }
}

extension PDFDictionary {
    /// Reads a four-number rectangle, in either corner order.
    static func rect(_ object: PDFObject?) -> PDFRect? {
        guard let array = object?.asArray, array.count == 4 else { return nil }
        let values = array.map(\.asNumber)
        guard values.allSatisfy({ $0 != nil }) else { return nil }
        return PDFRect(
            x: values[0]!,
            y: values[1]!,
            width: values[2]! - values[0]!,
            height: values[3]! - values[1]!
        )
    }

    /// Puts a rectangle in the form callers expect: origin at the minimum
    /// corner, positive extents.
    ///
    /// A `/MediaBox` or `/Rect` may be written with its corners in any order,
    /// so normalising here is what stops every consumer from having to know
    /// that.
    static func normalised(_ rect: PDFRect) -> PDFRect {
        PDFRect(
            x: min(rect.x, rect.x + rect.width),
            y: min(rect.y, rect.y + rect.height),
            width: abs(rect.width),
            height: abs(rect.height)
        )
    }
}

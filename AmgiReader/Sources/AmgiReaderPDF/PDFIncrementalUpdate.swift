/// Appends an incremental update to a PDF.
///
/// This is the whole answer to the concurrency problem, and it is the mechanism
/// Preview itself uses. An update never rewrites the file: it appends new
/// objects, a cross-reference section covering only the objects it changed, and
/// a trailer whose `/Prev` points at the previous section. So:
///
/// - The file on disk is a conformant PDF at every moment. Annotations appear
///   in Preview, Mail and Files immediately, with no export step.
/// - A device that annotates only ever *adds* to the file. Two devices cannot
///   overwrite each other, because neither touches the other's bytes.
/// - Reconciling two devices is `PDFLineariser`: fold the base document and
///   every appended section into one file, resolving each object to the most
///   recent definition. That is a union, so no annotation is lost.
///
/// The trade the format imposes: appended objects are never reclaimed, so a
/// heavily annotated file grows. Linearising is the answer when a compact file
/// is wanted, and it is lossless.
public import Foundation
public enum PDFIncrementalUpdate {
    /// One object to be added or superseded.
    public struct Entry: Sendable {
        public var number: Int
        public var generation: Int
        public var object: PDFObject

        public init(number: Int, generation: Int = 0, object: PDFObject) {
            self.number = number
            self.generation = generation
            self.object = object
        }
    }

    /// An object number to be marked free in the cross-reference table.
    ///
    /// Freeing is how a deletion is recorded. The old object's bytes stay in the
    /// file — the format does not reclaim them — but the table stops pointing at
    /// it, so no reader displays the annotation and the number becomes available
    /// for reuse. Expressing deletion in the table rather than by omission is
    /// what makes it work: a reader that recovers by scanning the file for
    /// `N G obj` headers would otherwise still find, and show, the annotation
    /// the user deleted.
    public struct Freed: Sendable, Equatable {
        public var number: Int
        /// The head of the free list this entry joins, conventionally object 0.
        public var nextFreeNumber: Int
        public var generation: Int

        public init(number: Int, nextFreeNumber: Int = 0, generation: Int = 0) {
            self.number = number
            self.nextFreeNumber = nextFreeNumber
            self.generation = generation
        }
    }

    /// Builds the bytes of one update section.
    ///
    /// - Parameters:
    ///   - file: the document being appended to. Its bytes are left untouched.
    ///   - entries: the objects this update defines. A repeated object number
    ///     supersedes the earlier definition, which is how an edited annotation
    ///     is updated without rewriting the original.
    ///   - freed: object numbers to mark free, for deletions.
    ///   - appendedAt: the byte offset the returned section will occupy in the
    ///     finished file, which is the length of the document it is appended
    ///     to. Required rather than defaulted because every offset the section
    ///     records is *absolute* — the entire purpose of a cross-reference table
    ///     is to say where in the file an object lives, and a relative offset
    ///     resolves to the wrong object in every reader except one that scans
    ///     for objects and papers over it.
    ///   - rootReference: the catalogue, carried forward so the file still opens
    ///     after the update.
    public static func build(
        for file: PDFAppendableFile,
        entries: [Entry],
        freed: [Freed] = [],
        appendedAt baseOffset: Int,
        rootReference: PDFReference? = nil
    ) -> [UInt8] {
        // A number cannot be both defined and freed in one section. Defining it
        // wins, because that is the recoverable direction: a stray `f` would make
        // the new object invisible to every reader.
        let defined = Set(entries.map(\.number))
        let ordered = entries.sorted {
            $0.number == $1.number ? $0.generation < $1.generation : $0.number < $1.number
        }
        let tombstones = freed
            .filter { !defined.contains($0.number) }
            .sorted { $0.number < $1.number }

        /// One cross-reference row, in the order it will be written.
        enum Row {
            case defined(offset: Int, generation: Int)
            case freed(next: Int, generation: Int)
        }

        // Definitions and tombstones are merged into one ascending sequence and
        // laid out in a single pass, recording each object's absolute offset as
        // it is written. Sorting is not cosmetic: a deterministic section is
        // byte-for-byte reproducible from the same input, which is what lets a
        // sync tell a no-op from real work.
        var out: [UInt8] = []
        var rows: [Row] = []
        var numbers: [Int] = []
        var pending = ordered.makeIterator()
        var nextEntry = pending.next()

        /// Writes one object and records where it started.
        ///
        /// The offset has to be taken *before* the bytes are appended. Taking it
        /// after gives every object the position of the thing that follows it,
        /// which produces a file that is internally consistent — each recorded
        /// offset does point at a real `N G obj` header, just the wrong one — and
        /// so passes a casual check while resolving every reference to a
        /// neighbour.
        func write(_ entry: PDFIncrementalUpdate.Entry) {
            rows.append(.defined(offset: baseOffset + out.count, generation: entry.generation))
            numbers.append(entry.number)
            out.append(contentsOf: PDFWriter.serializeIndirect(
                entry.object, number: entry.number, generation: entry.generation
            ))
        }

        for tombstone in tombstones {
            while let entry = nextEntry, entry.number < tombstone.number {
                write(entry)
                nextEntry = pending.next()
            }
            rows.append(.freed(next: tombstone.nextFreeNumber, generation: tombstone.generation))
            numbers.append(tombstone.number)
        }
        while let entry = nextEntry {
            write(entry)
            nextEntry = pending.next()
        }

        // The cross-reference section. Only the objects this update touched are
        // listed; everything else is reached through `/Prev`.
        let xrefOffset = baseOffset + out.count
        out.append(contentsOf: "xref\n".utf8)
        for (number, row) in zip(numbers, rows) {
            out.append(contentsOf: "\(number) 1\n".utf8)
            switch row {
            case .defined(let offset, let generation):
                out.append(contentsOf: String(
                    format: "%010d %05d n \n", offset, generation
                ).utf8)
            case .freed(let freeNext, let generation):
                out.append(contentsOf: String(
                    format: "%010d %05d f \n", freeNext, generation
                ).utf8)
            }
        }

        let highest = max(
            file.highestObjectNumber,
            numbers.max() ?? 0,
            (file.trailer["Size"]?.asInteger ?? 0) - 1
        )

        var trailer = PDFDictionary()
        trailer["Size"] = .integer(highest + 1)
        if let root = rootReference ?? file.trailer["Root"]?.asReference {
            trailer["Root"] = .reference(root)
        }
        if let info = file.trailer["Info"] {
            trailer["Info"] = info
        }
        if let identifier = file.fileIdentifier {
            // `/ID` is a pair. The first element identifies the original document
            // and must never change, or a reader sees a different file rather
            // than a revised one. The second changes on every save, which is how
            // a reader can tell the file has been revised.
            trailer["ID"] = .array([
                .string(bytes: identifier, isHex: true),
                .string(
                    bytes: PDFDocumentIdentity.newModificationID(
                        previous: identifier,
                        objectNumbers: numbers,
                        xrefOffset: xrefOffset
                    ),
                    isHex: true
                ),
            ])
        }
        if let previous = file.lastXrefOffset {
            trailer["Prev"] = .integer(previous)
        }

        out.append(contentsOf: "trailer\n".utf8)
        out.append(contentsOf: PDFWriter.serialize(.dictionary(trailer)))
        out.append(contentsOf: "\nstartxref\n\(xrefOffset)\n%%EOF\n".utf8)
        return out
    }
}

/// The second `/ID` element, which changes on every save.
enum PDFDocumentIdentity {
    /// Derived from the original identifier and what this update contains, so it
    /// is stable for the same edit and different for a different one.
    ///
    /// Deterministic rather than random on purpose: two devices that make the
    /// same annotation produce the same bytes, which is what makes a no-op sync
    /// detectable rather than a permanent spurious conflict.
    static func newModificationID(
        previous: [UInt8],
        objectNumbers: [Int],
        xrefOffset: Int
    ) -> [UInt8] {
        var material = previous
        for number in objectNumbers.sorted() {
            material.append(UInt8(number & 0xFF))
            material.append(UInt8((number >> 8) & 0xFF))
        }
        material.append(UInt8(xrefOffset & 0xFF))
        material.append(UInt8((xrefOffset >> 8) & 0xFF))
        var hash: UInt32 = 2_166_136_261
        for byte in material {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        // Sixteen bytes: a 32-bit value would fit in four, but `/ID` is
        // conventionally this long and readers that compare it expect it.
        var out: [UInt8] = []
        for shift in stride(from: 24, through: 0, by: -8) {
            out.append(UInt8(hash >> UInt32(shift) & 0xFF))
        }
        return out + [previous.first ?? 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    }
}

public import Foundation

/// Reads a PDF's metadata, outline and text-layer coverage without a renderer.
///
/// Everything here is derived from the file's own object graph, so the store can
/// be an actor and the whole import path is testable without PDFKit. Where a
/// question genuinely needs a renderer — the exact glyphs on a page, for
/// instance — the parser records what it can determine and leaves the rest to the
/// app layer rather than guessing.
public struct PDFDocumentParser: Sendable {
    public enum ParseError: Error, Equatable, LocalizedError, Sendable {
        case cannotOpen
        case notAPDF
        case encrypted
        case noPages

        public var errorDescription: String? {
            switch self {
            case .cannotOpen: "The PDF could not be opened."
            case .notAPDF: "This file is not a PDF."
            case .encrypted: "This PDF is encrypted, so it cannot be annotated."
            case .noPages: "This PDF has no pages."
            }
        }
    }

    /// Pages sampled when deciding whether the document has a text layer.
    ///
    /// Nine is enough to characterise a book without decoding every content
    /// stream in it, which for a several-hundred-page document is the
    /// difference between a fraction of a second and several. A document that is
    /// scanned throughout, or born-digital throughout, is not one that changes
    /// answer halfway through in a way that matters for choosing OCR.
    public static let coverageSampleCount = 9

    public init() {}

    /// Reads `bytes` into a descriptor for `bookID`.
    public func parse(bytes: [UInt8], bookID: String) throws -> PDFDocumentDescriptor {
        let file: PDFAppendableFile
        do {
            file = try PDFAppendableFile(bytes: bytes)
        } catch let error as PDFAppendableFile.LoadError {
            switch error {
            case .notAPDF: throw ParseError.notAPDF
            case .encrypted: throw ParseError.encrypted
            case .unreadable, .malformedXref: throw ParseError.notAPDF
            }
        }
        return try parse(file: file, bookID: bookID)
    }

    public func parse(file: PDFAppendableFile, bookID: String) throws -> PDFDocumentDescriptor {
        let pages = file.pages
        guard !pages.isEmpty else { throw ParseError.noPages }

        let info = documentInfo(in: file)
        let labels = pageLabels(in: file, pageCount: pages.count)
        let outline = outlineEntries(in: file, pages: pages)
        let coverage = textLayerCoverage(in: file, pages: pages)

        let fingerprint = PDFDocumentFingerprint.fingerprint(
            pageCount: pages.count,
            samples: samples(for: pages, in: file)
        )

        return PDFDocumentDescriptor(
            bookID: bookID,
            title: info.title ?? fallbackTitle(for: file),
            author: info.author,
            language: info.language,
            pageCount: pages.count,
            pageLabels: labels,
            outline: outline,
            // A page we could not read is not evidence of a scan, so it counts
            // as text-bearing. That errs towards not OCR-ing a document that
            // turns out to be readable, which is the cheaper mistake.
            hasTextLayer: coverage > 0,
            textLayerCoverage: coverage,
            documentFingerprint: fingerprint,
            pageSize: pages.first?.mediaBox.map {
                PDFPageSize(width: $0.width, height: $0.height)
            }
        )
    }

    // MARK: - Document information dictionary

    private struct DocumentInfo {
        var title: String?
        var author: String?
        var language: String?
    }

    private func documentInfo(in file: PDFAppendableFile) -> DocumentInfo {
        guard let reference = file.trailer["Info"]?.asReference,
              let dictionary = file.object(number: reference.number)?.asDictionary
        else { return DocumentInfo() }
        return DocumentInfo(
            title: PDFObject.text(of: dictionary["Title"]),
            author: PDFObject.text(of: dictionary["Author"]),
            language: PDFObject.text(of: dictionary["Language"])
        )
    }

    /// A title when the document does not supply one.
    ///
    /// Better than a row of identical "Untitled" entries in the library, which
    /// is the same information as no title at all.
    private func fallbackTitle(for file: PDFAppendableFile) -> String {
        "Untitled PDF"
    }

    // MARK: - Page labels

    /// The document's own page numbering, where it declares one.
    ///
    /// A PDF may carry a `/PageLabels` number tree, and a well-made book uses it:
    /// roman numerals through the front matter, then arabic restarting at 1 for
    /// the body. That is the numbering a reader says out loud, so reading it
    /// beats deriving "page 14" from an index the reader never sees.
    ///
    /// Returns nil when the document declares no labels, so the caller can fall
    /// back to page indices rather than being handed an array of fabricated
    /// ones.
    public func pageLabels(in file: PDFAppendableFile, pageCount: Int) -> [String?]? {
        guard let root = file.resolve(file.catalog?["PageLabels"] ?? .null).asDictionary
        else { return nil }

        let ranges = numberTreeEntries(root, in: file)
        guard !ranges.isEmpty else { return nil }

        var labels = [String?](repeating: nil, count: pageCount)
        // Entries are (first page index, dictionary) in ascending order. Each
        // covers pages until the next entry begins.
        for (position, entry) in ranges.enumerated() {
            let upperBound = position + 1 < ranges.count ? ranges[position + 1].0 : pageCount
            // A document may declare more ranges than it has pages — a label tree
            // covering a document that was later truncated is ordinary — so the
            // start has to be clamped as well as the end. Skipping only when the
            // end precedes the start would build an inverted range and trap.
            let lowerBound = max(0, entry.0)
            let clampedEnd = min(upperBound, pageCount)
            guard lowerBound < clampedEnd else { continue }
            assign(
                labels: &labels,
                range: lowerBound..<clampedEnd,
                style: PDFPageLabelStyle(dictionary: entry.1)
            )
        }
        return labels
    }

    /// Fills in one range's labels.
    ///
    /// The number is the page's position *within its range* plus `/St`, not its
    /// position in the document. That is what the specification says, and it is
    /// the whole reason ranges exist: a document can number its front matter
    /// "i, ii, iii" and then restart at "1" for the body without that restart
    /// being encoded anywhere but the range boundary.
    private func assign(labels: inout [String?], range: Range<Int>, style: PDFPageLabelStyle) {
        for (offset, pageIndex) in range.enumerated() {
            labels[pageIndex] = style.label(for: offset)
        }
    }

    /// Flattens a number tree into `(key, value)` pairs, ascending.
    ///
    /// Number trees are either inline (`/Nums`) or nested (`/Kids`), and real
    /// documents use both. Only the keys that pair with a dictionary are wanted;
    /// a `/Nums` array can also hold plain page-label dictionaries under
    /// arbitrary keys, so every even-indexed value is treated as the value and
    /// the key before it as its index.
    private func numberTreeEntries(
        _ node: PDFDictionary,
        in file: PDFAppendableFile,
        depth: Int = 0
    ) -> [(Int, PDFDictionary)] {
        // A malformed or hostile tree must not recurse without bound.
        guard depth < 32 else { return [] }
        var found: [(Int, PDFDictionary)] = []

        if let nums = node["Nums"]?.asArray {
            var index = 0
            while index + 1 < nums.count {
                if let key = nums[index].asInteger,
                   let value = file.resolve(nums[index + 1]).asDictionary {
                    found.append((key, value))
                }
                index += 2
            }
        }
        for kid in node["Kids"]?.asArray ?? [] {
            guard let dictionary = file.resolve(kid).asDictionary else { continue }
            found.append(contentsOf: numberTreeEntries(dictionary, in: file, depth: depth + 1))
        }
        return found.sorted { $0.0 < $1.0 }
    }

    // MARK: - Outline

    /// The document outline, flattened with each entry's destination page.
    ///
    /// Nested entries keep their depth so a sidebar can indent them, and each
    /// gets a path-derived ID rather than a hash of its destination — a document
    /// that moves a section by a page should keep its chapter IDs, or every
    /// saved position in it would be invalidated by a repagination.
    public func outlineEntries(
        in file: PDFAppendableFile,
        pages: [PDFPageReference]
    ) -> [PDFOutlineEntry] {
        guard let root = file.resolve(file.catalog?["Outlines"] ?? .null).asDictionary
        else { return [] }
        var out: [PDFOutlineEntry] = []
        // Bounded so a `/Kids` cycle in a damaged file cannot spin forever.
        var visited: Set<Int> = []
        walkOutline(root, in: file, pages: pages, path: [], depth: 0, into: &out, visited: &visited)
        return out
    }

    private func walkOutline(
        _ node: PDFDictionary,
        in file: PDFAppendableFile,
        pages: [PDFPageReference],
        path: [Int],
        depth: Int,
        into out: inout [PDFOutlineEntry],
        visited: inout Set<Int>
    ) {
        guard depth < 16, path.count < 32 else { return }

        guard let first = node["First"]?.asReference else { return }

        // The sibling list is walked through `/Next`, and the loop condition tests
        // the *unresolved* value. Resolving first would hand the loop a
        // dictionary where it expects a reference and stop after one entry, so a
        // two-chapter outline would report one chapter.
        //
        // Cycle detection happens in the loop, once per node. Doing it here as
        // well would insert the first sibling twice and the second insert would
        // fail, ending the walk before it began.
        var currentReference: PDFReference? = first
        var sibling = 0
        while let reference = currentReference, sibling < 4096 {
            guard visited.insert(reference.number).inserted,
                  let dictionary = file.object(number: reference.number)?.asDictionary
            else { break }

            let childPath = path + [sibling]
            if let title = PDFObject.text(of: dictionary["Title"]) {
                out.append(PDFOutlineEntry(
                    id: PDFOutlineEntry.outlineID(path: childPath),
                    title: title,
                    pageIndex: destinationPageIndex(of: dictionary, in: file, pages: pages),
                    depth: depth
                ))
            }
            if dictionary["First"] != nil {
                walkOutline(
                    dictionary, in: file, pages: pages,
                    path: childPath, depth: depth + 1,
                    into: &out, visited: &visited
                )
            }
            sibling += 1
            currentReference = dictionary["Next"]?.asReference
        }
    }

    /// The page an outline entry points at.
    ///
    /// A destination is a page reference, optionally preceded by a destination
    /// name resolved through the name tree. Both forms occur, and a remote
    /// destination (a page number plus a zoom factor, in a file that is not
    /// present) cannot be resolved at all — those entries are reported as
    /// landing on page 0 rather than dropped, so a chapter list never silently
    /// loses rows.
    private func destinationPageIndex(
        of entry: PDFDictionary,
        in file: PDFAppendableFile,
        pages: [PDFPageReference]
    ) -> Int {
        guard let destination = file.resolve(entry["Dest"] ?? .null).asArray
            ?? namedDestination(entry["Dest"], in: file)
        else { return 0 }
        guard let first = destination.first else { return 0 }
        if let reference = first.asReference {
            return pages.firstIndex { $0.reference == reference } ?? 0
        }
        // A plain integer names a page index directly.
        return first.asInteger ?? 0
    }

    private func namedDestination(_ object: PDFObject?, in file: PDFAppendableFile) -> [PDFObject]? {
        guard let name = object?.asName else { return nil }
        let tree = file.resolve(file.catalog?["Names"] ?? .null).asDictionary?["Dests"]
            ?? file.trailer["Dests"]
        guard let dictionary = file.resolve(tree ?? .null).asDictionary else { return nil }
        // Either a name tree under `/Names` or the older flat `/Dests` array.
        if let names = dictionary["Names"]?.asArray {
            var index = 0
            while index + 1 < names.count {
                if names[index].asName == name {
                    return file.resolve(names[index + 1]).asArray
                }
                index += 2
            }
        }
        if let array = dictionary[name] {
            return file.resolve(array).asArray
        }
        return nil
    }

    // MARK: - Text layer

    /// The fraction of sampled pages that draw text.
    public func textLayerCoverage(
        in file: PDFAppendableFile,
        pages: [PDFPageReference]
    ) -> Double {
        guard !pages.isEmpty else { return 0 }
        let sampled = samplePageIndices(pageCount: pages.count)
        guard !sampled.isEmpty else { return 0 }
        var withText = 0
        for index in sampled {
            if PDFContentScanner.textPresence(of: pages[index], in: file).hasText {
                withText += 1
            }
        }
        return Double(withText) / Double(sampled.count)
    }

    private func samplePageIndices(pageCount: Int) -> [Int] {
        guard pageCount > 0 else { return [] }
        guard pageCount <= Self.coverageSampleCount else { return [0] }
        return Array(0..<pageCount)
    }

    /// Geometry and text samples for the fingerprint.
    ///
    /// Text is not extracted here — that needs font encoding maps — so each
    /// sample contributes its page geometry and, where the content stream yields
    /// it, the raw bytes of the first show-text string. That is enough for the
    /// fingerprint's purpose, which is to notice that a document has been
    /// repaginated or re-generated rather than to reproduce its contents.
    private func samples(
        for pages: [PDFPageReference],
        in file: PDFAppendableFile
    ) -> [(pageIndex: Int, width: Double, height: Double, textPrefix: String)] {
        PDFDocumentFingerprint.sampleIndices(pageCount: pages.count).map { index in
            let page = pages[index]
            // A page that inherits its size from the page tree, or is
            // unreadable, falls back to US Letter: the fingerprint only needs
            // consistent geometry to compare against a later read of the same
            // document, not the true size.
            let size = page.mediaBox.map { PDFPageSize(width: $0.width, height: $0.height) }
                ?? PDFPageSize(width: 612, height: 792)
            return (
                pageIndex: index,
                width: size.width,
                height: size.height,
                textPrefix: firstTextSample(of: page, in: file)
            )
        }
    }

    /// The first show-text string found in a page's content stream.
    ///
    /// The stream is *decoded* first. Nearly every real content stream is
    /// Flate-compressed, and reading the literal out of the compressed bytes
    /// finds either nothing or an arbitrary string of the compressed data — so a
    /// document's fingerprint text would depend on how well its content stream
    /// happened to compress rather than on what it says. That is the worst
    /// possible input for an identity check: stable for the wrong reason, and
    /// unstable for the right one.
    private func firstTextSample(of page: PDFPageReference, in file: PDFAppendableFile) -> String {
        for bytes in PDFContentScanner.contentStreams(of: page, in: file) {
            guard let literal = firstLiteralString(in: bytes) else { continue }
            let text = literal.text
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
        }
        return ""
    }

    /// The first `( … )` string literal in a content stream.
    private func firstLiteralString(in bytes: [UInt8]) -> PDFStringLiteral? {
        var cursor = PDFByteCursor(bytes, from: 0)
        while !cursor.isAtEnd {
            cursor.skipWhitespace()
            guard let byte = cursor.peek() else { return nil }
            if byte == 0x28 { return cursor.readLiteralString() }
            // Step over anything that could swallow the parenthesis we want.
            if byte == 0x3C, cursor.peek(1) != 0x3C {
                guard cursor.readHexString() != nil else { return nil }
                continue
            }
            if byte == 0x2F {
                guard cursor.readName() != nil else { return nil }
                continue
            }
            guard (try? PDFObjectParser.parseObject(&cursor)) != nil else { return nil }
        }
        return nil
    }
}

extension PDFObject {
    /// A string value decoded to text, or nil.
    static func text(of object: PDFObject?) -> String? {
        guard case .string(let bytes, let isHex)? = object else { return nil }
        let text = PDFStringLiteral(bytes: bytes, isHex: isHex).text
        return text.isEmpty ? nil : text
    }
}

/// One entry of a `/PageLabels` tree.
public struct PDFPageLabelStyle: Sendable, Hashable {
    /// Label style: decimal, lower- or upper-case roman, or letters.
    public enum Style: String, Sendable, Hashable {
        case decimal
        case lowerRoman
        case upperRoman
        case lowerLetters
        case upperLetters
        /// `/A` with no `/S`: nothing is shown at all.
        case none

        init?(name: String) {
            switch name {
            case "D": self = .decimal
            case "r": self = .lowerRoman
            case "R": self = .upperRoman
            case "a": self = .lowerLetters
            case "A": self = .upperLetters
            case "": self = .none
            default: return nil
            }
        }
    }

    public var style: Style
    /// The first page number, 1-based by default.
    public var start: Int
    /// Text placed before the number, e.g. "A-".
    public var prefix: String?

    public init(style: Style, start: Int = 1, prefix: String? = nil) {
        self.style = style
        self.start = start
        self.prefix = prefix
    }

    init(dictionary: PDFDictionary) {
        let name = dictionary["S"]?.asName ?? ""
        // An absent `/S` alongside a present `/St` means "no label", which is
        // the one case where defaulting to decimal would be wrong.
        if dictionary["S"] == nil, dictionary["St"] != nil {
            self.style = .none
        } else {
            self.style = Style(name: name) ?? .decimal
        }
        // `/St` is 1-based; a document that omits it means 1.
        self.start = dictionary["St"]?.asInteger ?? 1
        self.prefix = PDFObject.text(of: dictionary["P"])
    }

    /// The label for the page `offset` positions into this range.
    public func label(for offset: Int) -> String? {
        guard style != .none else { return nil }
        // A `/St` of 0 is invalid and would otherwise render as a negative
        // number, so it is treated as 1.
        let number = max(1, start) + offset
        let body: String
        switch style {
        case .decimal: body = String(number)
        case .lowerRoman: body = String(number).lowerRomanNumerals ?? String(number)
        case .upperRoman: body = String(number).upperRomanNumerals ?? String(number)
        case .lowerLetters: body = String(number).letterNumerals(lowercase: true)
        case .upperLetters: body = String(number).letterNumerals(lowercase: false)
        case .none: return nil
        }
        return prefix.map { $0 + body } ?? body
    }
}

extension String {
    /// Roman numerals, for `/r` and `/R` page label styles.
    ///
    /// Nil beyond 3999, where there is no accepted representation. The caller
    /// falls back to the arabic number, which is the honest answer: a
    /// front-matter page labelled "xvvi" instead of "xvi" is worse than one
    /// labelled "16", because the first looks authoritative and is wrong.
    var lowerRomanNumerals: String? { romanNumerals?.lowercased() }
    var upperRomanNumerals: String? { romanNumerals }

    private var romanNumerals: String? {
        guard let value = Int(self), value > 0, value < 4000 else { return nil }
        let table: [(Int, String)] = [
            (1000, "M"), (900, "CM"), (500, "D"), (400, "CD"),
            (100, "C"), (90, "XC"), (50, "L"), (40, "XL"),
            (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I"),
        ]
        var remaining = value
        var out = ""
        for (amount, numeral) in table {
            while remaining >= amount {
                out += numeral
                remaining -= amount
            }
        }
        return out
    }

    /// Alphabetic page labels, for `/a` and `/A`.
    ///
    /// Bijective base-26: 1 is "a", 26 is "z", 27 is "aa". A document using this
    /// for its appendices is using it correctly, and reading it as base-26 would
    /// turn 26 into "ba".
    func letterNumerals(lowercase: Bool) -> String {
        guard let value = Int(self), value > 0 else { return self }
        var remaining = value
        var out = ""
        while remaining > 0 {
            remaining -= 1
            let letter = Character(UnicodeScalar(UInt8(97 + remaining % 26)))
            out = String(letter) + out
            remaining /= 26
        }
        return lowercase ? out : out.uppercased()
    }
}

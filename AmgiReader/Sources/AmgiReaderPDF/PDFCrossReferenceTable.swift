/// Reads a PDF's cross-reference information.
///
/// Two forms have to be handled. A *classic* table is plain text
/// (`xref … trailer << … >>`). A *stream* is a compressed object holding the
/// same information, introduced in PDF 1.5 and used by most modern producers,
/// including anything that has been optimised for the web.
///
/// Both are needed because the writer's job is to append to a file it did not
/// create, and appending requires knowing where the last section ended and
/// which objects the newest section supersedes.
public enum PDFCrossReferenceTable {
    public struct Parsed {
        /// Object number to byte offset and generation, for objects in use.
        public var entries: [Int: (offset: Int, generation: Int)]
        /// Object numbers the newest section that mentions them marks free.
        ///
        /// Kept apart from `entries` rather than simply omitted, because "free"
        /// and "never mentioned" mean different things: a free object is one a
        /// reader must not display, even though its bytes are still in the file
        /// and a recovery scan will find them.
        public var freed: Set<Int>
        /// The newest trailer.
        public var trailer: PDFDictionary
        /// Trailers from earlier sections, for hybrid-reference files where a
        /// classic table only supplements a stream.
        public var mergedTrailers: [PDFDictionary]
    }

    /// Parses every cross-reference section in the file, newest first.
    ///
    /// The obvious implementation follows `startxref` and then chains back
    /// through each section's `/Prev`. That is what the format describes, and it
    /// is what this used to do — but it makes the whole file's readability depend
    /// on a single number being correct, and in practice that number is often
    /// wrong. Bytes prepended to a file (a mail gateway, a scanner, a transfer
    /// agent) shift every offset without rewriting the numbers that point at
    /// them, and plenty of producers emit a `startxref` that is simply stale.
    ///
    /// Every conforming reader falls back to scanning for exactly this reason,
    /// and a fallback that only covers *object* offsets while still trusting
    /// `startxref` is no fallback at all: it recovers the objects but never gets
    /// as far as looking at them. So all sections are found by scanning and
    /// merged newest-first, with position in the file as the ordering — a
    /// section written later is a later revision, which is the one assumption
    /// the incremental-update model actually guarantees.
    public static func parse(bytes: [UInt8], headerOffset: Int) -> Parsed? {
        var entries: [Int: (offset: Int, generation: Int)] = [:]
        var freed: Set<Int> = []
        var trailers: [PDFDictionary] = []
        var newestTrailer: PDFDictionary?

        for offset in sectionOffsets(in: bytes, headerOffset: headerOffset).sorted(by: >) {
            guard let found = parseSection(bytes: bytes, at: offset) else { continue }

            // Newest first, so the first section to mention a number wins, and a
            // newer section that frees an object beats an older one that defined
            // it. Without the second half, filling the entry back in from the
            // older section resurrects exactly the annotation a deletion
            // removed.
            freed.formUnion(found.freed)
            for number in found.freed { entries[number] = nil }
            for (number, entry) in found.entries
            where entries[number] == nil && !freed.contains(number) {
                entries[number] = entry
            }
            trailers.append(found.trailer)
            newestTrailer = newestTrailer ?? found.trailer
        }

        guard let trailer = newestTrailer else { return nil }
        return Parsed(
            entries: entries,
            freed: freed,
            trailer: trailer,
            mergedTrailers: trailers
        )
    }

    /// Every byte offset at which a cross-reference section might begin.
    ///
    /// Three sources, in descending order of trust: the recorded `startxref`,
    /// each `xref` keyword, and each indirect object whose dictionary is
    /// `/Type /XRef`. The first is a hint; the other two are the scan. A false
    /// positive costs only a failed parse, since a section is accepted solely on
    /// producing a trailer.
    static func sectionOffsets(in bytes: [UInt8], headerOffset: Int) -> [Int] {
        var found: Set<Int> = []
        if let recorded = lastStartXref(in: bytes) {
            found.insert(recorded)
        }

        let xrefKeyword = Array("xref".utf8)
        var index = max(0, headerOffset)
        while index + xrefKeyword.count <= bytes.count {
            if Array(bytes[index..<(index + xrefKeyword.count)]) == xrefKeyword {
                // The keyword must stand alone: `xref` inside a longer word, or
                // the text `xref` inside a string literal, is not a section.
                let before = index > 0 ? bytes[index - 1] : 0x20
                let afterIndex = index + xrefKeyword.count
                let after = afterIndex < bytes.count ? bytes[afterIndex] : 0x20
                if (before <= 0x20 || PDFByteCursor.isDelimiterByte(before))
                    && (after <= 0x20 || PDFByteCursor.isDelimiterByte(after)) {
                    found.insert(index)
                }
            }
            index += 1
        }

        // `/Type /XRef` inside an object dictionary. Found by byte pattern
        // rather than by parsing every object, because the object could be
        // anything and the pattern is unambiguous enough at this position.
        let typeMarker = Array("/Type/XRef".utf8)
        index = max(0, headerOffset)
        while index + typeMarker.count <= bytes.count {
            if Array(bytes[index..<(index + typeMarker.count)]) == typeMarker {
                // Walk back to the `N G obj` header that begins this object.
                if let objectStart = objectStart(before: index, in: bytes) {
                    found.insert(objectStart)
                }
            }
            index += 1
        }

        return Array(found)
    }

    /// Finds the start of the indirect object containing `position`.
    private static func objectStart(before position: Int, in bytes: [UInt8]) -> Int? {
        var index = position
        while index > 0 {
            index -= 1
            // `N G obj` — the `obj` keyword, preceded by the generation number.
            guard index + 3 <= bytes.count,
                  Array(bytes[index..<(index + 3)]) == Array("obj".utf8)
            else { continue }
            var cursor = PDFByteCursor(bytes, from: index)
            _ = cursor.readDigits()
            guard cursor.readDigits() != nil, cursor.readKeyword() == "obj" else { continue }
            // The digits start at the beginning of the first number.
            var start = index
            while start > 0, bytes[start - 1] >= 0x30, bytes[start - 1] <= 0x39 { start -= 1 }
            return start
        }
        return nil
    }

    private struct Section {
        var entries: [Int: (offset: Int, generation: Int)]
        var freed: Set<Int> = []
        var trailer: PDFDictionary
    }

    private static func parseSection(bytes: [UInt8], at offset: Int) -> Section? {
        var cursor = PDFByteCursor(bytes, from: offset)
        cursor.skipWhitespace()

        if let keyword = cursor.readKeyword() {
            switch keyword {
            case "xref":
                return parseClassicTable(&cursor)
            default:
                // Not a table. An xref stream begins with an indirect object
                // header, which `readKeyword` will not have consumed cleanly,
                // so rewind and try that shape.
                return parseXrefStream(bytes: bytes, at: offset)
            }
        }
        return parseXrefStream(bytes: bytes, at: offset)
    }

    /// Parses the subsections of a classic table, positioned just after `xref`.
    ///
    /// Each subsection is a header pair — first object number, then how many
    /// consecutive objects it covers — followed by that many fixed-width entries.
    /// The header's first number is read as a keyword and then re-parsed, since
    /// `0` and `6` are lexically identical to a keyword and a lexer cannot tell
    /// them apart from position alone.
    private static func parseClassicTable(_ cursor: inout PDFByteCursor) -> Section? {
        var entries: [Int: (offset: Int, generation: Int)] = [:]
        var freed: Set<Int> = []
        var sawTrailer = false

        while true {
            // Each iteration reads either a subsection header, whose first
            // number is lexically just a keyword, or the `trailer` keyword
            // that ends the table.
            guard let keyword = cursor.readKeyword() else { break }
            if keyword == "trailer" {
                sawTrailer = true
                break
            }
            guard let subsectionStart = Int(keyword), let count = cursor.readDigits() else {
                return Section(entries: entries, freed: freed, trailer: PDFDictionary())
            }

            // A damaged table can claim more entries than the file has bytes
            // for. Each entry occupies at least 18 bytes, so a larger count is
            // a lie and must not become an unbounded loop.
            let bytesPerEntry = 18
            let affordable = max(0, cursor.bytes.count - cursor.index) / bytesPerEntry
            guard count > 0, count <= affordable else {
                return Section(entries: entries, freed: freed, trailer: PDFDictionary())
            }

            for offsetInSubsection in 0..<count {
                guard let offset = cursor.readDigits(),
                      let generation = cursor.readDigits()
                else { return Section(entries: entries, freed: freed, trailer: PDFDictionary()) }
                cursor.skipWhitespace()
                guard let marker = cursor.peek() else {
                    return Section(entries: entries, freed: freed, trailer: PDFDictionary())
                }
                cursor.seek(to: cursor.index + 1)
                let objectNumber = subsectionStart + offsetInSubsection
                if marker == 0x6E {  // 'n' — in use
                    entries[objectNumber] = (offset, generation)
                } else {
                    // A free object is recorded, not merely skipped. Skipping it
                    // makes it indistinguishable from an object the table never
                    // mentioned, and a reader that recovers a damaged table by
                    // scanning the file will then find the deleted annotation's
                    // bytes and display it again.
                    freed.insert(objectNumber)
                }
            }
        }

        // The trailer keyword is consumed by the loop, so it is not re-read
        // here; only the dictionary that follows it is.
        guard sawTrailer, let parsed = try? PDFObjectParser.parseObject(&cursor) else {
            return nil
        }
        return Section(
            entries: entries,
            freed: freed,
            trailer: parsed.asDictionary ?? PDFDictionary()
        )
    }

    /// Parses an xref stream: an indirect object whose dictionary has
    /// `/Type /XRef` and whose decoded bytes are fixed-width triples.
    private static func parseXrefStream(bytes: [UInt8], at offset: Int) -> Section? {
        var cursor = PDFByteCursor(bytes, from: offset)
        guard cursor.readDigits() != nil,
              cursor.readDigits() != nil,
              cursor.readKeyword() == "obj",
              let parsed = try? PDFObjectParser.parseObject(&cursor),
              case .stream(let stream) = parsed
        else { return nil }

        let dictionary = stream.dictionary
        guard dictionary["Type"]?.asName == "XRef" else { return nil }

        let widths = (dictionary["W"]?.asArray ?? []).compactMap(\.asInteger)
        guard widths.count >= 3 else { return nil }

        // The payload is a FlateDecode stream in the overwhelming majority of
        // files. Any other filter is honoured only when it is `/Identity`; a
        // stream we cannot decompress is skipped rather than misread, and the
        // object scan in the caller covers for it.
        let filter = (dictionary["Filter"]?.asName) ?? ""
        let payload: [UInt8]
        if filter == "FlateDecode" {
            payload = PDFInflate.decode(stream.rawBytes) ?? []
        } else if filter.isEmpty || filter == "Identity" {
            payload = stream.rawBytes
        } else {
            return nil
        }

        let size = dictionary["Size"]?.asInteger ?? 0
        let index = (dictionary["Index"]?.asArray ?? [.integer(0), .integer(size)])
            .compactMap(\.asInteger)
        var entries: [Int: (offset: Int, generation: Int)] = [:]
        var freed: Set<Int> = []

        // W = [w0 w1 w2] where w0 is the type field (0 = free, 1 = offset,
        // 2 = in an object stream). A zero width means the field is absent and
        // takes its default.
        let typeWidth = widths[0]
        let offsetWidth = widths[1]
        let generationWidth = widths[2]
        let rowWidth = typeWidth + offsetWidth + generationWidth
        guard rowWidth > 0 else { return nil }

        var cursorIndex = 0
        var pairIndex = 0
        while pairIndex + 1 < index.count {
            let first = index[pairIndex]
            let count = index[pairIndex + 1]
            for objectNumber in first..<(first + count) {
                guard cursorIndex + rowWidth <= payload.count else { break }
                func field(_ start: Int, _ width: Int, default defaultValue: Int) -> Int {
                    guard width > 0 else { return defaultValue }
                    var value = 0
                    for offset in 0..<width {
                        value = value << 8 | Int(payload[cursorIndex + start + offset])
                    }
                    return value
                }
                let type = field(0, typeWidth, default: 1)
                let objectOffset = field(typeWidth, offsetWidth, default: 0)
                let generation = field(typeWidth + offsetWidth, generationWidth, default: 0)
                switch type {
                case 1:
                    entries[objectNumber] = (objectOffset, generation)
                case 0:
                    // Free. Recorded, for the same reason the classic table
                    // records it: a recovery scan would otherwise find the
                    // deleted object's bytes and show it again.
                    freed.insert(objectNumber)
                default:
                    // Type 2 lives inside an object stream, which this reader
                    // does not expand; the caller's object scan recovers those.
                    break
                }
                cursorIndex += rowWidth
            }
            pairIndex += 2
        }

        return Section(entries: entries, freed: freed, trailer: dictionary)
    }

    /// Finds the byte offset of the last `startxref`.
    public static func lastStartXref(in bytes: [UInt8]) -> Int? {
        // Scan back from the end over the `%%EOF` tail, which is the last thing
        // in the file by definition.
        let marker = Array("startxref".utf8)
        var searchEnd = bytes.count
        // The trailer plus its `%%EOF` is bounded in practice; 2 KB of tail is
        // generous and keeps the scan from walking a whole large file.
        searchEnd = max(0, bytes.count - 2048)
        var index = bytes.count - marker.count
        while index >= searchEnd {
            if Array(bytes[index..<(index + marker.count)]) == marker {
                var cursor = PDFByteCursor(bytes, from: index + marker.count)
                if let value = cursor.readDigits() { return value }
            }
            index -= 1
        }
        return nil
    }

    /// Scans the whole file for `N G obj` headers.
    ///
    /// The recovery path for documents whose cross-reference data is missing or
    /// wrong, which is common enough in the wild that refusing to annotate them
    /// would exclude a large share of real files. An offset found this way is
    /// only trusted when the bytes at it really do begin that object, which
    /// `PDFAppendableFile` checks.
    public static func scanForObjects(
        in bytes: [UInt8],
        from start: Int
    ) -> [Int: (offset: Int, generation: Int)] {
        var found: [Int: (offset: Int, generation: Int)] = [:]
        let keyword = Array("obj".utf8)
        var index = max(0, start)

        while index + keyword.count <= bytes.count {
            guard Array(bytes[index..<(index + keyword.count)]) == keyword else {
                index += 1
                continue
            }
            // `obj` is always preceded by whitespace, so the generation number
            // sits *before* that whitespace, not immediately before the
            // keyword. Requiring a digit right before "obj" would therefore
            // match nothing at all in a well-formed file.
            var back = index
            while back > 0, isWhitespace(bytes[back - 1]) { back -= 1 }
            if let header = readObjectHeader(bytes: bytes, objKeywordIndex: index, back) {
                found[header.number] = (header.offset, header.generation)
            }
            index += 1
        }
        return found
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09 || byte == 0x00 || byte == 0x0C
    }

    /// Reads `N G obj` backwards from the position of `obj`.
    ///
    /// Working backwards is what makes the two numbers recoverable: a forward
    /// reader cannot tell where the first number began, but a backward one can
    /// walk off the digits and then forward-parse the pair.
    private static func readObjectHeader(
        bytes: [UInt8],
        objKeywordIndex: Int,
        _ back: Int
    ) -> (number: Int, generation: Int, offset: Int)? {
        // Generation.
        let generationEnd = back
        var generationStart = back
        while generationStart > 0, bytes[generationStart - 1] >= 0x30, bytes[generationStart - 1] <= 0x39 {
            generationStart -= 1
        }
        guard generationStart < generationEnd,
              let generation = Int(String(decoding: bytes[generationStart..<generationEnd], as: UTF8.self))
        else { return nil }

        // Whitespace between the two numbers.
        let numberEnd = generationStart
        var numberStart = generationStart
        while numberStart > 0, isWhitespace(bytes[numberStart - 1]) { numberStart -= 1 }
        guard numberStart < numberEnd else { return nil }

        // Object number.
        var objectStart = numberStart
        while objectStart > 0, bytes[objectStart - 1] >= 0x30, bytes[objectStart - 1] <= 0x39 {
            objectStart -= 1
        }
        guard objectStart < numberStart,
              let number = Int(String(decoding: bytes[objectStart..<numberStart], as: UTF8.self)),
              number > 0
        else { return nil }

        return (number, generation, objectStart)
    }
}

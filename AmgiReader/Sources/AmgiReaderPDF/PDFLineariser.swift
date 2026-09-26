public import Foundation

/// Folds several copies of a PDF into one.
///
/// The reconciliation step. Each device that annotates produces the base file
/// plus one appended section; a device that receives a sibling's file and then
/// annotates again produces a longer chain. Reconciling two such files means
/// resolving every object to the most recent definition that mentions it, across
/// both files' sections.
///
/// The output is a single clean file with one cross-reference table. That is
/// also how the append-only growth gets reclaimed: linearising is lossless, so a
/// document can be linearised as often as is convenient.
///
/// ## Why a plain union is not enough
///
/// Taking every object from either input and renumbering is almost the whole
/// story, but not quite, and the gap is the interesting part. Adding an
/// annotation does not only append the annotation object: it also *redefines the
/// page* so the page's `/Annots` array lists it. So two devices annotating the
/// same page both write object 3, and a union that lets the secondary win keeps
/// one device's page and orphans the other device's annotation — an object that
/// is present in the file, referenced by nothing, and therefore invisible.
///
/// Losing one side's work is exactly the failure this whole design exists to
/// avoid, so the merge repairs it: after resolving objects, each page's
/// `/Annots` is rebuilt from the annotation objects actually present in the
/// merged file. The annotations are found by their `/P` back-reference, which is
/// why the annotation writer always sets it. The result is that both devices'
/// annotations appear, whichever page definition happened to win.
public enum PDFLineariser {
    public struct Result: Sendable {
        /// The rewritten, compact file.
        public var bytes: [UInt8]
        /// How many objects the result defines.
        public var objectCount: Int
        /// Objects that came only from the secondary input, i.e. work a
        /// last-writer-wins rewrite would have discarded.
        public var objectsFromSecondary: Int
        /// Annotations rescued by rebuilding a page's `/Annots` from the
        /// annotation objects present, rather than from the winning page
        /// definition's array. Zero in the ordinary case; non-zero whenever two
        /// devices annotated the same page independently.
        public var annotationsRelinked: Int
    }

    public enum Failure: Error, Equatable, LocalizedError {
        case unreadable

        public var errorDescription: String? {
            "The annotated PDF could not be combined."
        }
    }

    /// Merges `secondary` into `primary`.
    ///
    /// The ordering of the arguments does not change *which* annotations
    /// survive — every annotation present in either input is present in the
    /// result. It only decides which version wins where both sides edited the
    /// same annotation, and that is the one case where a difference is
    /// legitimate rather than a loss.
    public static func merge(
        primary: [UInt8],
        secondary: [UInt8]
    ) throws -> Result {
        guard let primaryFile = try? PDFAppendableFile(bytes: primary),
              let secondaryFile = try? PDFAppendableFile(bytes: secondary)
        else { throw Failure.unreadable }

        // Start from everything the primary defines, then let the secondary's
        // definitions win. A device may have edited an annotation the other
        // device also edited, and the newer file is the better answer for that
        // one object; every other object is a union.
        var resolved: [Int: PDFObject] = [:]
        var secondaryOnly = 0
        for number in primaryFile.objectNumbers {
            guard let object = primaryFile.object(number: number) else { continue }
            resolved[number] = object
        }
        for number in secondaryFile.objectNumbers {
            guard let object = secondaryFile.object(number: number) else { continue }
            if resolved[number] == nil { secondaryOnly += 1 }
            resolved[number] = object
        }

        let relinked = relinkPageAnnotations(in: &resolved)

        // Renumber densely. Preserving the union of both files' numbers would
        // leave large gaps, which is legal but wasteful and makes later diffs
        // meaningless.
        var renumbered: [Int: PDFReference] = [:]
        for (index, number) in resolved.keys.sorted().enumerated() {
            renumbered[number] = PDFReference(number: index + 1, generation: 0)
        }

        var out: [UInt8] = Array("%PDF-1.7\n%".utf8)
        // The binary marker that tells a reader the file holds binary data it
        // must not translate. Four raw bytes: written as `"\u{E2}"` it would be
        // UTF-8 encoded into two bytes each and the marker would be wrong.
        out.append(contentsOf: [0xE2, 0xE3, 0xCF, 0xD3])
        out.append(0x0A)

        var offsets: [Int: Int] = [:]
        for number in resolved.keys.sorted() {
            guard let definition = resolved[number], let target = renumbered[number] else { continue }
            offsets[target.number] = out.count
            out.append(contentsOf: PDFWriter.serializeIndirect(
                translate(definition, using: renumbered),
                number: target.number,
                generation: target.generation
            ))
        }

        // One cross-reference table, covering everything.
        let xrefOffset = out.count
        out.append(contentsOf: "xref\n0 \(resolved.count + 1)\n".utf8)
        out.append(contentsOf: "0000000000 65535 f \n".utf8)
        for number in 1...max(1, resolved.count) {
            let offset = offsets[number] ?? 0
            out.append(contentsOf: String(format: "%010d 00000 n \n", offset).utf8)
        }

        var trailer = PDFDictionary()
        trailer["Size"] = .integer(resolved.count + 1)
        // The catalogue is the one object that must keep its identity, since
        // everything else is reached from it.
        if let root = primaryFile.trailer["Root"] ?? secondaryFile.trailer["Root"],
           let rootReference = root.asReference,
           let translated = renumbered[rootReference.number] {
            trailer["Root"] = .reference(translated)
        }
        if let info = primaryFile.trailer["Info"] ?? secondaryFile.trailer["Info"] {
            trailer["Info"] = info
        }
        // An encrypted document cannot be linearised: its strings and streams
        // are encrypted with the document's key, and rewriting them would need
        // that key. Encryption is refused at load, so this is belt-and-braces.
        if let identifier = primaryFile.fileIdentifier ?? secondaryFile.fileIdentifier {
            trailer["ID"] = .array([
                .string(bytes: identifier, isHex: true),
                .string(bytes: identifier, isHex: true),
            ])
        }

        out.append(contentsOf: "trailer\n".utf8)
        out.append(contentsOf: PDFWriter.serialize(.dictionary(trailer)))
        out.append(contentsOf: "\nstartxref\n\(xrefOffset)\n%%EOF\n".utf8)

        return Result(
            bytes: out,
            objectCount: resolved.count,
            objectsFromSecondary: secondaryOnly,
            annotationsRelinked: relinked
        )
    }

    /// Rebuilds every page's `/Annots` from the annotation objects present.
    ///
    /// Returns how many references were added that the winning page definition
    /// did not list — that is, how many annotations were rescued.
    private static func relinkPageAnnotations(in resolved: inout [Int: PDFObject]) -> Int {
        // Group annotation objects by the page they name in `/P`. A bare
        // dictionary cannot be re-referenced, so those are left in the page's
        // existing array where they already are.
        var byPage: [Int: [Int]] = [:]
        for (number, object) in resolved {
            guard let dictionary = object.asDictionary,
                  dictionary["Type"]?.asName == "Annot",
                  let page = dictionary["P"]?.asReference?.number
            else { continue }
            byPage[page, default: []].append(number)
        }
        guard !byPage.isEmpty else { return 0 }

        var rescued = 0
        for (pageNumber, annotations) in byPage {
            guard var page = resolved[pageNumber]?.asDictionary else { continue }
            var references: [PDFObject] = page["Annots"]?.asArray ?? []
            let present = Set(references.compactMap { $0.asReference?.number })

            for number in annotations.sorted() where !present.contains(number) {
                references.append(.reference(PDFReference(number: number)))
                rescued += 1
            }
            page["Annots"] = .array(references)
            resolved[pageNumber] = .dictionary(page)
        }
        return rescued
    }

    /// Rewrites references to the new object numbers, leaving values alone.
    private static func translate(_ object: PDFObject, using map: [Int: PDFReference]) -> PDFObject {
        switch object {
        case .reference(let reference):
            return .reference(map[reference.number] ?? reference)
        case .array(let elements):
            return .array(elements.map { translate($0, using: map) })
        case .dictionary(let dictionary):
            var out = PDFDictionary()
            for key in dictionary.keys {
                if let value = dictionary[key] {
                    out[key] = translate(value, using: map)
                }
            }
            return .dictionary(out)
        case .stream(let stream):
            var dictionary = PDFDictionary()
            for key in stream.dictionary.keys {
                if let value = stream.dictionary[key] {
                    dictionary[key] = translate(value, using: map)
                }
            }
            // Stream bytes are carried through untouched: they may be
            // compressed in a way this file does not model, and re-encoding them
            // would corrupt the page content.
            dictionary["Length"] = .integer(stream.rawBytes.count)
            return .stream(PDFStream(dictionary: dictionary, rawBytes: stream.rawBytes))
        default:
            return object
        }
    }
}

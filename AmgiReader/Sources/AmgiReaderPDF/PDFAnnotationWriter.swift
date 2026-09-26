public import Foundation

/// Writes annotations into a PDF, in the way Preview does.
///
/// Two things make this more than "append an object", and both are the reason
/// a naive implementation produces a file that opens but shows no annotation:
///
/// 1. A reader finds a page's annotations by reading the page dictionary's
///    `/Annots` array. The `/P` entry on the annotation is only a *back*
///    reference, used to say which page an orphaned annotation belongs to; it is
///    not how the annotation is discovered. So adding an annotation means
///    redefining the page object with one more entry in its `/Annots`.
/// 2. Redefining a page means carrying every key it already had forward. A page
///    dictionary holds `/Resources`, `/Rotate`, `/MediaBox`, `/CropBox`,
///    `/Annots` and whatever else the producer felt like, and a writer that
///    reconstructs a page from a known list of keys silently drops the rest —
///    which is how a re-saved page loses its fonts or its crop marks.
///
/// Both changes are coupled, so they are offered together: a caller cannot
/// append the annotation without also linking it to its page.
public enum PDFAnnotationWriter {
    /// The result of preparing an annotation change.
    public struct Change: Sendable {
        /// Objects to define, in no particular order.
        public var entries: [PDFIncrementalUpdate.Entry]
        /// Objects to mark free, for removals.
        public var freed: [PDFIncrementalUpdate.Freed]

        public var isEmpty: Bool { entries.isEmpty && freed.isEmpty }
    }

    /// Prepares an addition or edit of one annotation on one page.
    ///
    /// - Parameters:
    ///   - annotation: the annotation dictionary. `/P` and `/NM` are filled in if
    ///     absent, because an annotation without a name cannot be identified
    ///     again after a round trip through another reader.
    ///   - replacing: the annotation this supersedes, if it is an edit rather
    ///     than a new annotation. Its object number is reused so the file does
    ///     not accumulate a copy per keystroke.
    public static func add(
        _ annotation: PDFDictionary,
        to page: PDFPageReference,
        on file: PDFAppendableFile,
        objectNumber: Int,
        name: String,
        replacing existing: PDFAnnotationRecord? = nil
    ) -> Change {
        var dictionary = annotation
        dictionary["Type"] = .name("Annot")
        dictionary["P"] = .reference(page.reference)
        // `/NM` is the one entry every conforming reader uses to identify an
        // annotation. A namespaced value is what lets our annotations be
        // recognised as ours rather than as a stray highlight someone left.
        if dictionary["NM"] == nil {
            dictionary["NM"] = .string(bytes: Array(name.utf8), isHex: false)
        }
        // `/F` is the flags bitfield. Value 4 is `Print`, which Preview sets so
        // an annotation survives printing; without it some readers treat an
        // annotation as screen-only and drop it on export. Nothing else is set:
        // the neighbouring bits are `NoZoom`, `NoRotate` and `NoView`, and
        // setting one of those by mistaking it for `Print` changes the
        // annotation's behaviour rather than failing visibly.
        dictionary["F"] = .integer(4)

        var entries: [PDFIncrementalUpdate.Entry] = [
            .init(number: objectNumber, object: .dictionary(dictionary))
        ]
        // An edit reuses the original's object number, so the page's `/Annots`
        // array does not change and the file gains no new object.
        if let existing, existing.reference.number != objectNumber {
            entries.append(.init(
                number: existing.reference.number,
                object: .dictionary(dictionary)
            ))
        }
        entries.append(pageEntry(for: page, on: file, annotationReference: .init(number: objectNumber)))
        return Change(entries: entries, freed: [])
    }

    /// Prepares the removal of one annotation.
    ///
    /// The object is freed rather than merely unlinked, so a reader that
    /// recovers a damaged cross-reference table by scanning the file does not
    /// find and re-display an annotation the user deleted.
    public static func remove(
        _ annotation: PDFAnnotationRecord,
        from page: PDFPageReference,
        on file: PDFAppendableFile
    ) -> Change {
        Change(
            entries: [pageEntry(for: page, on: file, removing: annotation.reference)],
            freed: [.init(number: annotation.reference.number, generation: file.generation(of: annotation.reference.number))]
        )
    }

    /// A new definition of the page dictionary with its `/Annots` array changed.
    ///
    /// Every existing key is carried forward verbatim. That is not a
    /// convenience: the page dictionary is where `/Resources`, `/Rotate` and
    /// `/CropBox` live, and a page rebuilt from a known set of keys loses
    /// whatever it did not know about — the fonts in `/Resources` most visibly,
    /// which turns a saved page into a page of blank boxes.
    private static func pageEntry(
        for page: PDFPageReference,
        on file: PDFAppendableFile,
        annotationReference: PDFReference? = nil,
        removing: PDFReference? = nil
    ) -> PDFIncrementalUpdate.Entry {
        var dictionary = page.dictionary
        var references: [PDFObject] = resolveReferences(file.resolve(page.dictionary["Annots"] ?? .null))

        if let annotationReference {
            // Replace rather than append when the number is already listed, so
            // an edit does not leave the same annotation in the array twice.
            references.removeAll { $0.asReference?.number == annotationReference.number }
            references.append(.reference(annotationReference))
        }
        if let removing {
            references.removeAll { $0.asReference?.number == removing.number }
        }
        dictionary["Annots"] = .array(references)

        // The generation is carried forward rather than incremented. The
        // cross-reference table is the authority on where an object lives, and
        // every reference to the page in the rest of the document — the page
        // tree's `/Kids`, most importantly — still names the generation the
        // table records. Incrementing it here would make those references
        // nominally stale for a strict reader in exchange for no benefit.
        return .init(
            number: page.reference.number,
            generation: page.reference.generation,
            object: .dictionary(dictionary)
        )
    }

    /// Turns a resolved `/Annots` value into a list of references.
    ///
    /// An entry that is a bare dictionary rather than a reference is kept as it
    /// is. It cannot be re-referenced because there is no object number to point
    /// at, and dropping it would silently delete an annotation this app did not
    /// create.
    private static func resolveReferences(_ object: PDFObject) -> [PDFObject] {
        if let array = object.asArray { return array }
        if case .dictionary = object { return [object] }
        return []
    }

    /// The next unused object number, for a new annotation.
    ///
    /// Prefers a number that was freed, which is what makes a long editing
    /// session not grow the file without bound: deleted annotations leave their
    /// numbers available.
    public static func nextObjectNumber(
        in file: PDFAppendableFile,
        usedByExistingAnnotations: Set<Int>
    ) -> Int {
        var candidate = file.highestObjectNumber + 1
        // One past the end is tried first, then the gaps left by deletions.
        // Bounded so a document with a pathological free list cannot spin.
        var attempts = 0
        while attempts < 1024, usedByExistingAnnotations.contains(candidate) {
            candidate += 1
            attempts += 1
        }
        return candidate
    }
}

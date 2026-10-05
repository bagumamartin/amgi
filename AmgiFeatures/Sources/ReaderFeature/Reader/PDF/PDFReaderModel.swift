import AmgiReader
import AmgiReaderPDF
import AnkiClients
import Dependencies
import Foundation
import Observation
import PDFKit

/// Owns the open PDF and every change made to it.
///
/// The central responsibility is that **no annotation exists only in memory**.
/// `PDFKit` will accept `addAnnotation` and keep it in its in-memory document
/// until something asks it to write, which may be never: closing the reader
/// discards it, and the file on disk — the one Preview, Mail and a second
/// device will see — is unchanged. So every mutation is two steps: apply it to
/// the live document *and* append an incremental update to the managed file.
/// Only the first means the user sees nothing; only the second means the change
/// is not there at all.
@MainActor
@Observable
final class PDFReaderModel {
    enum State {
        case loading
        case ready
        case failed(String)
    }

    private(set) var state: State = .loading

    /// The open document. Main-actor isolated because `PDFDocument` is not
    /// `Sendable`, which is also why the store holds bytes rather than one.
    private(set) var document: PDFDocument?
    private(set) var descriptor: PDFDocumentDescriptor?
    private(set) var documentID = UUID()
    private(set) var managedURL: URL?

    /// Annotations we have written, keyed by page index.
    ///
    /// Read from the document rather than accumulated locally, so what the
    /// sidebar shows is what is actually there — including markup added in
    /// Preview, by Acrobat, or by a sync from another device.
    private(set) var annotationsByPage: [Int: [PDFPageAnnotation]] = [:]
    private(set) var bookmarks: [PDFBookmark] = []

    /// The most recent failure from a write, surfaced rather than swallowed.
    ///
    /// A failed annotation write is the one failure the user must see: without
    /// it they highlight something, close the book, and find it gone.
    var writeError: String?

    /// The annotation the user has selected, if any.
    var selectedAnnotationID: String?

    let book: ReaderBook
    private let progress: ReaderProgressCoordinator
    @ObservationIgnored private let thumbnailCache = PDFThumbnailCache()

    @ObservationIgnored @Dependency(\.pdfLibraryClient) private var client

    init(book: ReaderBook, progress: ReaderProgressCoordinator) {
        self.book = book
        self.progress = progress
    }

    // MARK: - Loading

    func load() async {
        state = .loading
        guard case .pdf(let sourceURL) = book.source else {
            state = .failed("This book is not a PDF.")
            return
        }
        // The managed copy is authoritative, not the URL recorded on the book:
        // it is where annotations are written, and after a sync it may differ
        // from what the index held at import time.
        let managed = await client.sourceURL(book.id) ?? sourceURL
        guard let document = PDFDocument(url: managed) else {
            state = .failed("This PDF could not be opened.")
            return
        }
        documentID = UUID()
        managedURL = managed
        thumbnailCache.clear()
        self.document = document
        self.descriptor = await client.descriptor(book.id)
        refreshAnnotations()
        refreshBookmarks()
        state = .ready
    }

    var pageCount: Int { document?.pageCount ?? 0 }

    /// A thumbnail keyed to this document and render size. The cache belongs to
    /// this reader model so two open PDFs cannot display each other's pages.
    func thumbnail(forPage index: Int, size: CGSize) -> PlatformImage? {
        guard let document, let page = document.page(at: index) else { return nil }
        if let cached = thumbnailCache.get(
            documentID: documentID,
            pageIndex: index,
            size: size
        ) {
            return cached
        }
        guard let image = PDFThumbnailRenderer.render(page: page, size: size) else { return nil }
        thumbnailCache.set(image, documentID: documentID, pageIndex: index, size: size)
        return image
    }

    /// The document's own label for a page, falling back to its 1-based index.
    ///
    /// The document's numbering, not the index: a book with roman front matter
    /// is "i, ii, iii, 1, 2" and a page field showing "4" for the first page of
    /// the body is wrong in the way the reader will notice.
    func label(forPage index: Int) -> String {
        descriptor?.label(forPageIndex: index) ?? String(index + 1)
    }

    var allAnnotations: [PDFPageAnnotation] {
        annotationsByPage.values.flatMap { $0 }.sorted {
            $0.pageIndex == $1.pageIndex
                ? $0.bounds.minY > $1.bounds.minY
                : $0.pageIndex < $1.pageIndex
        }
    }

    // MARK: - Reading annotations

    /// Re-reads every annotation in the document.
    func refreshAnnotations() {
        guard let document else { return }
        var found: [Int: [PDFPageAnnotation]] = [:]
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let pageAnnotations = page.annotations.compactMap {
                PDFPageAnnotation(pdfAnnotation: $0, pageIndex: index)
            }
            if !pageAnnotations.isEmpty {
                found[index] = pageAnnotations
            }
        }
        annotationsByPage = found
    }

    func refreshBookmarks() {
        guard let root = document?.outlineRoot else {
            bookmarks = []
            return
        }
        var found: [PDFBookmark] = []
        var visited: Set<ObjectIdentifier> = []
        collectBookmarks(root, depth: 0, path: [], into: &found, visited: &visited)
        bookmarks = found
    }

    /// Walks PDFKit's outline tree.
    ///
    /// `PDFOutline` is a tree with `numberOfChildren` and `childAtIndex(_:)`,
    /// not a linked list, and it is weakly held by its parent — so the whole
    /// subtree is flattened into values in one pass rather than being retained.
    /// A PDF with a `/Kids` cycle is malformed but not unknown, and the visited
    /// set is what keeps that from recursing until the stack gives out.
    private func collectBookmarks(
        _ outline: PDFOutline,
        depth: Int,
        path: [Int],
        into out: inout [PDFBookmark],
        visited: inout Set<ObjectIdentifier>
    ) {
        guard depth < 32, path.count < 64 else { return }
        let key = ObjectIdentifier(outline)
        guard visited.insert(key).inserted else { return }

        for index in 0..<outline.numberOfChildren {
            guard let child = outline.child(at: index) else { continue }
            let childPath = path + [index]
            let destination: Int?
            if let page = child.destination?.page, let document {
                destination = document.index(for: page)
            } else {
                destination = nil
            }
            out.append(PDFBookmark(
                id: "bookmark:" + childPath.map(String.init).joined(separator: "."),
                title: child.label ?? "Untitled",
                pageIndex: destination ?? 0,
                depth: depth,
                hasDestination: destination != nil
            ))
            if child.numberOfChildren > 0 {
                collectBookmarks(child, depth: depth + 1, path: childPath, into: &out, visited: &visited)
            }
        }
    }

    /// The annotation with a given identifier, if it is still present.
    func annotation(withIdentifier identifier: String) -> PDFPageAnnotation? {
        allAnnotations.first { $0.id == identifier }
    }

    // MARK: - Writing annotations

    /// Applies an annotation and appends it to the managed file.
    ///
    /// - Returns: whether the annotation reached the file. `false` means it is
    ///   visible now and will be lost, so the caller must say so — the
    ///   alternative is silently losing work.
    @discardableResult
    func addAnnotation(
        kind: PDFAnnotationKind,
        pageIndex: Int,
        bounds: CGRect,
        colour: PDFAnnotationColour = .yellow,
        contents: String? = nil
    ) async -> Bool {
        guard let document, let page = document.page(at: pageIndex) else { return false }
        // The identifier is ours and is written into the file, so it must be
        // decided before the PDFKit annotation is made rather than derived from
        // it afterwards.
        let identifier = "amgi-\(kind.pdfSubtype)-\(UUID().uuidString)"
        let annotation = PDFAnnotationFactory.make(
            kind: kind,
            bounds: bounds,
            colour: colour,
            contents: contents,
            identifier: identifier
        )
        page.addAnnotation(annotation)

        let committed = await appendToFile(onPage: pageIndex) { file, pageReference in
            guard let record = PDFAnnotationFactory.dictionary(
                kind: kind,
                bounds: bounds,
                colour: colour,
                contents: contents,
                identifier: identifier,
                page: pageReference.reference
            ) else { return nil }
            return PDFAnnotationWriter.add(
                record,
                to: pageReference,
                on: file,
                objectNumber: nextObjectNumber(after: file),
                name: identifier
            )
        }
        if committed {
            refreshAnnotations()
        } else {
            writeError = "That annotation could not be saved to the file."
        }
        return committed
    }

    /// Edits an existing annotation's text, in the file as well as in memory.
    @discardableResult
    func updateAnnotation(identifier: String, contents: String) async -> Bool {
        guard let located = locate(identifier) else { return false }
        located.annotation.contents = contents

        let committed = await appendToFile(onPage: located.pageIndex) { file, page in
            guard let record = file.annotations(on: page)
                .first(where: { $0.name == identifier })
            else { return nil }
            // An edit supersedes the same object rather than adding a second
            // one, so the file does not accumulate a copy per keystroke and the
            // page's `/Annots` does not grow a duplicate reference.
            var dictionary = record.dictionary
            dictionary["Contents"] = .string(
                bytes: PDFStringLiteral.utf16(contents).bytes,
                isHex: false
            )
            return PDFAnnotationWriter.add(
                dictionary,
                to: page,
                on: file,
                objectNumber: record.reference.number,
                name: identifier,
                replacing: record
            )
        }
        if committed {
            refreshAnnotations()
        } else {
            writeError = "That note could not be saved to the file."
        }
        return committed
    }

    /// Removes an annotation from the document and frees it in the file.
    @discardableResult
    func removeAnnotation(identifier: String) async -> Bool {
        guard let located = locate(identifier) else { return false }
        if let page = document?.page(at: located.pageIndex) {
            page.removeAnnotation(located.annotation)
        }
        let pageIndex = located.pageIndex
        let committed = await appendToFile(onPage: pageIndex) { file, page in
            guard let record = file.annotations(on: page)
                .first(where: { $0.name == identifier })
            else { return nil }
            return PDFAnnotationWriter.remove(record, from: page, on: file)
        }
        if selectedAnnotationID == identifier {
            selectedAnnotationID = nil
        }
        if committed {
            refreshAnnotations()
        } else {
            writeError = "That annotation could not be removed from the file."
        }
        return committed
    }

    private struct LocatedAnnotation {
        let annotation: PDFAnnotation
        let pageIndex: Int
    }

    private func locate(_ identifier: String) -> LocatedAnnotation? {
        guard let document else { return nil }
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            if let found = page.annotations.first(where: { $0.userName == identifier }) {
                return LocatedAnnotation(annotation: found, pageIndex: index)
            }
        }
        return nil
    }

    /// Runs one change against the managed file and appends it.
    ///
    /// The change is handed the parsed file and the page it applies to, and
    /// returns the objects to write — or nil if the annotation could not be
    /// located, in which case nothing is written at all. Writing a partial
    /// change is how a file ends up with a page whose `/Annots` lists an object
    /// that was never defined, which every reader then silently ignores.
    private func appendToFile(
        onPage pageIndex: Int,
        _ change: (PDFAppendableFile, PDFPageReference) -> PDFAnnotationWriter.Change?
    ) async -> Bool {
        guard case .pdf(let url) = book.source else { return false }
        do {
            let data = try Data(contentsOf: url)
            let file = try PDFAppendableFile(bytes: [UInt8](data))
            guard file.pages.indices.contains(pageIndex) else {
                writeError = "That page is not in the file."
                return false
            }
            let page = file.pages[pageIndex]
            guard let pageChange = change(file, page), !pageChange.isEmpty else { return false }
            let update = PDFIncrementalUpdate.build(
                for: file,
                entries: pageChange.entries,
                freed: pageChange.freed,
                // The update's offsets are absolute, so this must be the length
                // the appended bytes will actually land at. Getting it wrong
                // produces a cross-reference table pointing at the wrong bytes.
                appendedAt: data.count
            )
            try await client.appendUpdate(book.id, update)
            _ = try? await client.reload(book.id)
            return true
        } catch {
            writeError = error.localizedDescription
            return false
        }
    }

    /// The next object number for a new annotation.
    ///
    /// One past everything the file has used, rather than a scan for gaps: a
    /// freed number is reusable, but reusing one that another device is also
    /// about to use produces a file where two annotations share an object
    /// number, and the merge then silently drops one of them.
    private func nextObjectNumber(after file: PDFAppendableFile) -> Int {
        file.highestObjectNumber + 1
    }

    // MARK: - Reading position

    /// Records where the user is.
    ///
    /// Only ever called for a move the user made. A programmatic move —
    /// restoring a saved position, following an outline link — is not reading
    /// progress, and recording it makes the resume point follow the act of
    /// opening the book rather than the last place actually read.
    ///
    /// The position is stored as a fraction of the document rather than as a
    /// page number, because that is what the shared progress model carries and
    /// because it survives a document growing: a 300-page book with three pages
    /// inserted before the reader's place still resumes in the right place,
    /// whereas a stored page number would be three pages out.
    func persistPosition(_ pageIndex: Int) {
        guard pageIndex >= 0, pageCount > 0 else { return }
        let fraction = Double(pageIndex) / Double(max(1, pageCount - 1))
        progress.save(
            bookID: book.id,
            chapterID: chapterID(containingPage: pageIndex) ?? 0,
            progress: fraction
        )
    }

    /// The chapter containing a page, or nil when the book has no outline.
    func chapterID(containingPage pageIndex: Int) -> Int64? {
        let starts = book.chapters.compactMap { chapter -> (Int64, Int)? in
            guard let start = chapter.startPageIndex else { return nil }
            return (chapter.id, start)
        }.sorted { $0.1 < $1.1 }
        return starts.last { $0.1 <= pageIndex }?.0
    }

    /// Where the reader should resume, from saved progress.
    ///
    /// Async because the coordinator reconciles against the Anki collection
    /// before answering, and that answer is the one that should win: a position
    /// written on another device is newer than the local copy.
    func restoredPageIndex() async -> Int {
        guard let saved = await progress.resolved(bookID: book.id), pageCount > 0 else {
            return 0
        }
        let fraction = min(max(saved.progress, 0), 1)
        return max(0, min(Int((fraction * Double(max(0, pageCount - 1))).rounded()), pageCount - 1))
    }
}

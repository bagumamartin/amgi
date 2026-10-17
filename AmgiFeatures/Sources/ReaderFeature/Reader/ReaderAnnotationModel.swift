import AmgiAppCore
import AmgiReader
import AnkiClients
import Dependencies
import Foundation
import OSLog

/// Bookmarks, highlights, and full-book search for the EPUB reader.
///
/// Owns the persistent store and the translation between stored annotations
/// and the flat `{start, end, kind, id}` shape the page's mark applier
/// expects. Keeping that translation here means the WebView never sees an
/// anchor object and the store never deals with a DOM offset.
@Observable
@MainActor
final class ReaderAnnotationModel {
    private(set) var highlights: [ReaderAnnotation] = []
    private(set) var bookmarks: [ReaderAnnotation] = []
    /// Source passages of cards made while reading, drawn as the card mark.
    private(set) var cards: [ReaderAnnotation] = []
    private(set) var searchHits: [ReaderSearchHit] = []
    var searchError: String?

    private var store: ReaderAnnotationStore?
    private var currentBookID: String?

    /// Annotation kinds live beside the books, so the store follows the
    /// profile the same way the library does. Resolved per call rather than
    /// captured, so a profile switch is picked up on the next interaction.
    private func makeStore() -> ReaderAnnotationStore {
        ReaderAnnotationStore(
            libraryRoot: AccountStore.profileDirectory(for: AccountStore.shared.selectedID)
                .appendingPathComponent("EPUB", isDirectory: true)
        )
    }

    func load(bookID: String) async {
        let store = makeStore()
        self.store = store
        self.currentBookID = bookID
        await reload(for: bookID, using: store)
    }

    /// Re-reads both lists. Called after every mutation so the UI and the
    /// page's applied marks cannot drift apart.
    func reload(for bookID: String, using store: ReaderAnnotationStore? = nil) async {
        let active = store ?? self.store ?? makeStore()
        self.store = active
        do {
            highlights = try await active.annotations(inBook: bookID, kind: .highlight)
            bookmarks = try await active.annotations(inBook: bookID, kind: .bookmark)
            cards = try await active.annotations(inBook: bookID, kind: .card)
        } catch {
            searchError = error.localizedDescription
        }
    }

    // MARK: - Mutations

    /// Persists a mark captured from the page and refreshes the lists.
    ///
    /// The offset range is optional: a highlight created from a native
    /// selection has an anchor but no reliable DOM range, so it is stored
    /// without one and resolves by quote when the page is next opened.
    func addHighlight(
        in bookID: String,
        anchor: ReaderSourceAnchor,
        excerpt: String,
        range: ClosedRange<Int>? = nil,
        colorHex: String? = nil
    ) async {
        let annotation = ReaderAnnotation(
            bookID: bookID,
            kind: .highlight,
            anchor: anchor,
            excerpt: excerpt,
            colorHex: colorHex
        )
        await persist(annotation, range: range)
    }

    func addBookmark(
        in bookID: String,
        anchor: ReaderSourceAnchor,
        excerpt: String,
        range: ClosedRange<Int>? = nil
    ) async {
        let annotation = ReaderAnnotation(
            bookID: bookID,
            kind: .bookmark,
            anchor: anchor,
            excerpt: excerpt
        )
        await persist(annotation, range: range)
    }

    /// Records where a card came from — one mark per source passage, all
    /// carrying the note id so a tap on any of them opens the card. Returns
    /// the ids written, so an undo removes exactly these.
    @discardableResult
    func addCardMarks(
        in bookID: String,
        sources: [(anchor: ReaderSourceAnchor, excerpt: String)],
        noteID: Int64,
        colorHex: String? = nil
    ) async -> [UUID] {
        await addCardMarks(
            in: bookID,
            sources: sources.map { (anchor: $0.anchor, excerpt: $0.excerpt, region: nil, imageFile: nil) },
            noteID: noteID,
            colorHex: colorHex
        )
    }

    /// Card marks, each in the capture's colour; an area capture's mark
    /// carries its region.
    func addCardMarks(
        in bookID: String,
        sources: [(anchor: ReaderSourceAnchor, excerpt: String, region: ReaderPageRegion?, imageFile: String?)],
        noteID: Int64,
        colorHex: String?
    ) async -> [UUID] {
        let store = self.store ?? makeStore()
        self.store = store
        var written: [UUID] = []
        do {
            for source in sources {
                let annotation = ReaderAnnotation(
                    bookID: bookID,
                    kind: .card,
                    anchor: source.anchor,
                    excerpt: source.excerpt,
                    note: Self.cardNoteTag(noteID),
                    colorHex: colorHex,
                    region: source.region,
                    imageFile: source.imageFile
                )
                written.append(try await store.save(annotation).id)
            }
        } catch {
            searchError = error.localizedDescription
        }
        await reload(for: bookID, using: store)
        return written
    }

    func deleteAnnotations(_ ids: [UUID], inBook bookID: String) async {
        let store = self.store ?? makeStore()
        self.store = store
        do {
            for id in ids { try await store.delete(id: id, inBook: bookID) }
        } catch {
            searchError = error.localizedDescription
        }
        await reload(for: bookID, using: store)
    }

    /// Recolours marks, keeping everything else about them.
    func setColour(_ hex: String, ids: Set<UUID>, inBook bookID: String) async {
        let store = self.store ?? makeStore()
        self.store = store
        do {
            for var annotation in try await store.annotations(inBook: bookID) where ids.contains(annotation.id) {
                annotation.colorHex = hex
                annotation.updatedAt = .now
                _ = try await store.save(annotation)
            }
        } catch {
            searchError = error.localizedDescription
        }
        await reload(for: bookID, using: store)
    }

    /// Puts removed marks back exactly as they were — the undo for removal.
    func restore(_ annotations: [ReaderAnnotation]) async {
        guard let bookID = annotations.first?.bookID else { return }
        let store = self.store ?? makeStore()
        self.store = store
        do {
            for annotation in annotations { _ = try await store.save(annotation) }
        } catch {
            searchError = error.localizedDescription
        }
        await reload(for: bookID, using: store)
    }

    /// Card marks for a note, for undoing a one-tap capture.
    func cardMarkIDs(forNote noteID: Int64) -> [UUID] {
        cards.filter { $0.note == Self.cardNoteTag(noteID) }.map(\.id)
    }

    static func cardNoteTag(_ noteID: Int64) -> String { "nid:\(noteID)" }

    static func noteID(fromCardTag tag: String?) -> Int64? {
        guard let tag, tag.hasPrefix("nid:") else { return nil }
        return Int64(tag.dropFirst(4))
    }

    private func persist(_ annotation: ReaderAnnotation, range: ClosedRange<Int>?) async {
        let store = self.store ?? makeStore()
        self.store = store
        do {
            _ = try await store.save(annotation)
            await reload(for: annotation.bookID, using: store)
        } catch {
            searchError = error.localizedDescription
        }
    }

    func delete(_ annotation: ReaderAnnotation) async {
        let store = self.store ?? makeStore()
        self.store = store
        do {
            try await store.delete(id: annotation.id, inBook: annotation.bookID)
            await reload(for: annotation.bookID, using: store)
        } catch {
            searchError = error.localizedDescription
        }
    }

    func updateNote(_ annotation: ReaderAnnotation, note: String?) async {
        var updated = annotation
        updated.note = note
        await persist(updated, range: nil)
    }

    // MARK: - Search

    /// Full-book search. Empty query clears the list rather than returning
    /// everything, so a cleared field does not dump the whole library.
    func search(_ query: String, inBook bookID: String? = nil) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchHits = []
            searchError = nil
            return
        }
        let store = self.store ?? makeStore()
        self.store = store
        do {
            searchHits = try await store.search(query: trimmed, inBook: bookID)
            searchError = nil
        } catch {
            searchHits = []
            searchError = error.localizedDescription
        }
    }

    func clearSearch() {
        searchHits = []
        searchError = nil
    }

    // MARK: - Page bridge

    /// The flat mark descriptors the page's `__amgiApplyMarks` consumes.
    ///
    /// `start`/`end` are character offsets across the chapter's concatenated
    /// token text — the same basis the injected script measures progress and
    /// anchors with, which is what makes them line up.
    func markDescriptors(for bookID: String, chapterID: Int64) async -> [[String: Any]] {
        guard let store else { return [] }
        do {
            let all = try await store.annotations(inBook: bookID)
            return all.compactMap { annotation in
                // The chapter filter is applied natively because an anchor's
                // chapterID is a hint: a quote may resolve into a different
                // chapter after an edit, and dropping it silently would be
                // worse than drawing it once and letting resolution correct it.
                guard annotation.anchor.chapterID == chapterID else { return nil }
                var descriptor: [String: Any] = [
                    "id": annotation.id.uuidString,
                    "kind": annotation.kind.rawValue,
                ]
                if let region = annotation.region {
                    // An area capture: its box, inside the block that holds it.
                    guard let path = annotation.anchor.path, !path.isEmpty else { return nil }
                    descriptor["region"] = true
                    descriptor["path"] = path
                    descriptor["box"] = [region.x, region.y, region.width, region.height]
                    if let color = annotation.colorHex { descriptor["color"] = color }
                    return descriptor
                }
                if let start = annotation.anchor.cfi {
                    // The quote length is the highlighted span's extent; the
                    // quote itself is the sentence, so use the shorter of the
                    // two when both are present.
                    let length = max(1, annotation.excerpt.count)
                    descriptor["start"] = start
                    descriptor["end"] = start + length
                }
                // Lets the page check the offset against the words and
                // re-find them when it has drifted.
                descriptor["text"] = annotation.excerpt
                if let color = annotation.colorHex {
                    descriptor["color"] = color
                }
                return descriptor
            }
        } catch {
            searchError = error.localizedDescription
            return []
        }
    }

    /// Marks for the whole book, used when the page cannot narrow by chapter
    /// (e.g. a single-chapter book where the anchor carries no chapter hint).
    func allMarkDescriptors(for bookID: String) async -> [[String: Any]] {
        guard let store else { return [] }
        do {
            let all = try await store.annotations(inBook: bookID)
            return all.compactMap { annotation in
                guard let start = annotation.anchor.cfi else { return nil }
                let length = max(1, annotation.excerpt.count)
                return [
                    "id": annotation.id.uuidString,
                    "kind": annotation.kind.rawValue,
                    "start": start,
                    "end": start + length,
                    "text": annotation.excerpt,
                ]
            }
        } catch {
            searchError = error.localizedDescription
            return []
        }
    }
}

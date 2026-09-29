public import Foundation

/// A user-created mark inside a book: a highlight, a bookmark, or a note
/// anchor.
///
/// Unlike a page/fraction, an annotation stores a `ReaderSourceAnchor`, so it
/// resolves to the same words after a re-extraction, on another device, or at
/// a different typography — see `ReaderSourceAnchor` for why that needs three
/// independent handles rather than one.
public struct ReaderAnnotation: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable, Hashable, CaseIterable {
        case highlight
        case bookmark
    }

    public var id: UUID
    public var bookID: String
    public var kind: Kind
    public var anchor: ReaderSourceAnchor
    /// The anchored text as captured, kept for display before the anchor is
    /// ever resolved — a list row must render without loading the chapter.
    public var excerpt: String
    public var note: String?
    /// Highlight colour as a hex string, or nil for the reader default.
    public var colorHex: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        bookID: String,
        kind: Kind,
        anchor: ReaderSourceAnchor,
        excerpt: String,
        note: String? = nil,
        colorHex: String? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.bookID = bookID
        self.kind = kind
        self.anchor = anchor
        self.excerpt = excerpt
        self.note = note
        self.colorHex = colorHex
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// One hit from a full-book search.
public struct ReaderSearchHit: Sendable, Hashable, Identifiable {
    public var id: UUID { annotation.id }
    public let annotation: ReaderAnnotation
    /// Chapter title, resolved at search time so the list can show where the
    /// match is without loading the book.
    public let chapterTitle: String?
    /// Character offset within the chapter, when the anchor carries one.
    public let offset: Int?

    public init(annotation: ReaderAnnotation, chapterTitle: String?, offset: Int?) {
        self.annotation = annotation
        self.chapterTitle = chapterTitle
        self.offset = offset
    }
}

/// Persistent, profile-scoped annotation store for one book library.
///
/// Backed by a single JSON document per library root rather than the process
/// defaults: annotations are the one piece of reader state large enough to
/// want a durable, inspectable, backup-able file, and keeping them beside the
/// books means a backup that carries `original.epub` carries the marks too.
public actor ReaderAnnotationStore {
    public enum StoreError: Error, Sendable {
        case unreadable(String)
    }

    private static let fileName = "annotations.json"
    /// Guards against a runaway script filling the file. Well above any
    /// realistic personal library.
    private static let maximumAnnotations = 20_000

    private let rootDirectory: URL
    private let fileURL: URL
    private var annotationsByBook: [String: [ReaderAnnotation]] = [:]
    private var isLoaded = false

    /// - Parameter profileID: scopes the store the same way the library does,
    ///   so annotations follow their book when profiles switch.
    public init(libraryRoot: URL) {
        self.rootDirectory = libraryRoot
        self.fileURL = libraryRoot.appendingPathComponent(Self.fileName)
    }

    // MARK: - Reads

    public func annotations(
        inBook bookID: String,
        kind: ReaderAnnotation.Kind? = nil
    ) throws -> [ReaderAnnotation] {
        try loadIfNeeded()
        let all = annotationsByBook[bookID] ?? []
        let filtered = kind.map { kind in all.filter { $0.kind == kind } } ?? all
        return filtered.sorted { $0.createdAt > $1.createdAt }
    }

    public func allBooksWithAnnotations() throws -> [String] {
        try loadIfNeeded()
        return annotationsByBook.keys.sorted()
    }

    /// Full-text search across every book, or one.
    ///
    /// Deliberately a substring search over the stored excerpt rather than a
    /// search index: the corpus is a personal reading list, so a linear scan is
    /// fast enough to stay always-correct, whereas an index would need
    /// invalidation and would silently miss annotations added from the reader.
    public func search(
        query: String,
        inBook bookID: String? = nil
    ) throws -> [ReaderSearchHit] {
        try loadIfNeeded()
        let needle = ReaderAnnotationStore.normalizeForSearch(query)
        guard !needle.isEmpty else { return [] }

        let bookIDs = bookID.map { [$0] } ?? annotationsByBook.keys.sorted()
        var hits: [ReaderSearchHit] = []
        for candidate in bookIDs {
            for annotation in annotationsByBook[candidate] ?? [] {
                let haystacks = [annotation.excerpt, annotation.note ?? ""]
                guard haystacks.contains(where: {
                    ReaderAnnotationStore.normalizeForSearch($0).contains(needle)
                }) else { continue }
                hits.append(
                    ReaderSearchHit(
                        annotation: annotation,
                        chapterTitle: nil,
                        offset: annotation.anchor.cfi
                    )
                )
            }
        }
        // Newest first, with a stable tiebreak so repeated searches do not
        // reshuffle equal-timestamp results.
        return hits.sorted {
            if $0.annotation.createdAt != $1.annotation.createdAt {
                return $0.annotation.createdAt > $1.annotation.createdAt
            }
            return $0.annotation.id.uuidString < $1.annotation.id.uuidString
        }
    }

    // MARK: - Writes

    @discardableResult
    public func save(_ annotation: ReaderAnnotation) throws -> ReaderAnnotation {
        try loadIfNeeded()
        var stored = annotation
        stored.updatedAt = .now
        var list = annotationsByBook[stored.bookID] ?? []
        if let index = list.firstIndex(where: { $0.id == stored.id }) {
            // Preserve the original creation time on update.
            stored.createdAt = list[index].createdAt
            list[index] = stored
        } else {
            list.append(stored)
        }
        annotationsByBook[stored.bookID] = list
        try persist()
        return stored
    }

    public func delete(id: UUID, inBook bookID: String) throws {
        try loadIfNeeded()
        guard var list = annotationsByBook[bookID] else { return }
        list.removeAll { $0.id == id }
        if list.isEmpty {
            annotationsByBook.removeValue(forKey: bookID)
        } else {
            annotationsByBook[bookID] = list
        }
        try persist()
    }

    public func deleteAll(inBook bookID: String) throws {
        try loadIfNeeded()
        annotationsByBook.removeValue(forKey: bookID)
        try persist()
    }

    // MARK: - Search normalisation

    /// Case- and diacritic-insensitive folding, so "resume" finds "résumé"
    /// the way a reader expects rather than the way a byte compare does.
    static func normalizeForSearch(_ text: String) -> String {
        text
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Storage

extension ReaderAnnotationStore {
    private struct Document: Codable {
        var version: Int
        var books: [String: [ReaderAnnotation]]
    }

    private func loadIfNeeded() throws {
        guard !isLoaded else { return }
        defer { isLoaded = true }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw StoreError.unreadable(error.localizedDescription)
        }
        // A corrupt annotation file must not take the library down with it:
        // the books are still readable, so keep them and start annotations
        // over rather than propagating a decode error into the reader.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        guard let document = try? decoder.decode(Document.self, from: data) else {
            return
        }
        let legacy = JSONDecoder()
        legacy.dateDecodingStrategy = .iso8601
        if let decoded = try? legacy.decode(Document.self, from: data) {
            annotationsByBook = decoded.books
        } else {
            annotationsByBook = document.books
        }
    }

    private func persist() throws {
        try FileManager.default.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true
        )
        let document = Document(version: 1, books: annotationsByBook)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        try data.write(to: fileURL, options: .atomic)
    }
}

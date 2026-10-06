import Foundation

/// Why a book in the index can no longer be materialised on disk.
///
/// Persisted with the index entry rather than kept in memory so a book that
/// fails a *cold* rebuild (app relaunch, after a failed restore, missing source)
/// still reports a reason instead of silently vanishing from the library list.
public enum PDFLibraryEntryFault: String, Codable, Sendable, Hashable, CaseIterable {
    /// `original.pdf` is absent from the managed book directory.
    case sourceMissing
    /// The source exists but could not be read (permissions, I/O, truncated).
    case sourceUnreadable
    /// The file is not a PDF, or its structure is too damaged to read.
    case parseFailed
    /// The file is a PDF but carries a `/Encrypt` entry, so it can be read but
    /// not annotated — a different problem from being unreadable, and one the
    /// user can act on by removing the password.
    case encrypted
}

/// Public, UI-facing health for one managed book.
public struct PDFLibraryBookHealth: Sendable, Hashable {
    public enum State: Sendable, Hashable {
        case ready
        case needsRepair(fault: PDFLibraryEntryFault, detail: String?)
    }

    public let bookID: String
    public let state: State

    public var isReady: Bool {
        if case .ready = state { return true }
        return false
    }

    public var fault: PDFLibraryEntryFault? {
        if case .needsRepair(let fault, _) = state { return fault }
        return nil
    }

    /// Whether the book can be read even though it cannot be annotated.
    ///
    /// An encrypted PDF is perfectly readable — refusing to open it would be a
    /// worse answer than opening it and disabling the markup tools — so the
    /// distinction is carried all the way to the UI rather than collapsed into
    /// "broken".
    public var isReadable: Bool {
        fault != .encrypted
    }

    public init(bookID: String, state: State) {
        self.bookID = bookID
        self.state = state
    }
}

public struct PDFLibraryIndexChapter: Codable, Sendable, Hashable {
    public var id: Int64
    public var title: String
    public var order: String?
    public var pageCount: Int?

    public init(id: Int64, title: String, order: String? = nil, pageCount: Int? = nil) {
        self.id = id
        self.title = title
        self.order = order
        self.pageCount = pageCount
    }
}

/// On-disk shape persisted in `PDFLibrary/index.json`.
struct PDFLibraryIndexEntry: Codable, Sendable, Hashable {
    var bookID: String
    var title: String
    var author: String?
    var coverRelativePath: String?
    var language: String?
    var pageCount: Int
    /// Cached chapter list from previous parse, avoiding cold-start re-parsing.
    var chapters: [PDFLibraryIndexChapter]?
    /// Last local metadata/file update. Optional so indexes written before
    /// timestamped sync metadata remain readable.
    var updatedAt: Date?
    /// A local deletion tombstone. Keeping the entry in the index prevents an
    /// additive restore pass from resurrecting a book on this device.
    var deletedAt: Date?
    /// Last known reason this book could not be rebuilt, persisted so the
    /// library UI can offer a repair action after a cold start.
    var fault: PDFLibraryEntryFault?
    /// Human-readable detail for the fault. Shown in the repair sheet; not used
    /// for control flow.
    var faultDetail: String?

    init(
        bookID: String,
        title: String,
        author: String?,
        coverRelativePath: String?,
        language: String?,
        pageCount: Int,
        chapters: [PDFLibraryIndexChapter]? = nil,
        updatedAt: Date? = nil,
        deletedAt: Date? = nil,
        fault: PDFLibraryEntryFault? = nil,
        faultDetail: String? = nil
    ) {
        self.bookID = bookID
        self.title = title
        self.author = author
        self.coverRelativePath = coverRelativePath
        self.language = language
        self.pageCount = pageCount
        self.chapters = chapters
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.fault = fault
        self.faultDetail = faultDetail
    }

    var isDeleted: Bool { deletedAt != nil }

    var syncDate: Date {
        max(updatedAt ?? .distantPast, deletedAt ?? .distantPast)
    }
}

struct PDFLibraryIndexFile: Codable, Sendable {
    var version: Int
    var entries: [PDFLibraryIndexEntry]

    init(version: Int = 1, entries: [PDFLibraryIndexEntry] = []) {
        self.version = version
        self.entries = entries
    }
}

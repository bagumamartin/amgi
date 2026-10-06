internal import Foundation

/// Why a book in the index can no longer be materialised on disk.
///
/// Persisted with the index entry rather than kept in memory so a book that
/// fails a *cold* rebuild (app relaunch, after a failed restore, missing
/// source) still reports a reason instead of silently vanishing from the
/// library list.
public enum EPUBLibraryEntryFault: String, Codable, Sendable, Hashable, CaseIterable {
    /// `original.epub` is absent from the managed book directory.
    case sourceMissing
    /// The source exists but could not be read (permissions, I/O, truncated).
    case sourceUnreadable
    /// EPUBKit could not parse the source (malformed container / OPF).
    case parseFailed
}

/// Public, UI-facing health for one managed book.
public struct EPUBLibraryBookHealth: Sendable, Hashable {
    public enum State: Sendable, Hashable {
        case ready
        case needsRepair(fault: EPUBLibraryEntryFault, detail: String?)
    }

    public let bookID: String
    public let state: State

    public var isReady: Bool {
        if case .ready = state { return true }
        return false
    }

    public var fault: EPUBLibraryEntryFault? {
        if case .needsRepair(let fault, _) = state { return fault }
        return nil
    }

    public init(bookID: String, state: State) {
        self.bookID = bookID
        self.state = state
    }
}

public struct EPUBLibraryIndexChapter: Codable, Sendable, Hashable {
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

/// On-disk shape persisted in `EPUBLibrary/index.json`.
internal struct EPUBLibraryIndexEntry: Codable, Sendable, Hashable {
    var bookID: String
    var title: String
    var author: String?
    var coverRelativePath: String?
    var language: String?
    var pageCount: Int
    /// Cached chapter list from previous parse, avoiding cold-start re-unzips.
    var chapters: [EPUBLibraryIndexChapter]?
    /// Last local metadata/file update. Optional so indexes written before
    /// timestamped sync metadata remain readable.
    var updatedAt: Date?
    /// A local deletion tombstone. Keeping the entry in the index prevents
    /// the additive iCloud restore pass from resurrecting a book on this
    /// device.
    var deletedAt: Date?
    /// Last known reason this book could not be rebuilt, persisted so the
    /// library UI can offer a repair action after a cold start. Nil when the
    /// book is healthy.
    var fault: EPUBLibraryEntryFault?
    /// Human-readable detail (underlying error text) for the fault. Shown in
    /// the repair sheet; not used for control flow.
    var faultDetail: String?

    init(
        bookID: String,
        title: String,
        author: String?,
        coverRelativePath: String?,
        language: String?,
        pageCount: Int,
        chapters: [EPUBLibraryIndexChapter]? = nil,
        updatedAt: Date? = nil,
        deletedAt: Date? = nil,
        fault: EPUBLibraryEntryFault? = nil,
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

internal struct EPUBLibraryIndexFile: Codable, Sendable {
    var version: Int
    var entries: [EPUBLibraryIndexEntry]

    init(version: Int = 1, entries: [EPUBLibraryIndexEntry] = []) {
        self.version = version
        self.entries = entries
    }
}

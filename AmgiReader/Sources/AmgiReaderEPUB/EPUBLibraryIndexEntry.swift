internal import Foundation

/// On-disk shape persisted in `EPUBLibrary/index.json`.
internal struct EPUBLibraryIndexEntry: Codable, Sendable, Hashable {
    var bookID: String
    var title: String
    var author: String?
    var coverRelativePath: String?
    var language: String?
    var pageCount: Int
    /// Last local metadata/file update. Optional so indexes written before
    /// timestamped sync metadata remain readable.
    var updatedAt: Date?
    /// A local deletion tombstone. Keeping the entry in the index prevents
    /// the additive iCloud restore pass from resurrecting a book on this
    /// device.
    var deletedAt: Date?

    init(
        bookID: String,
        title: String,
        author: String?,
        coverRelativePath: String?,
        language: String?,
        pageCount: Int,
        updatedAt: Date? = nil,
        deletedAt: Date? = nil
    ) {
        self.bookID = bookID
        self.title = title
        self.author = author
        self.coverRelativePath = coverRelativePath
        self.language = language
        self.pageCount = pageCount
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
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

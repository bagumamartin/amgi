import AmgiReader
import AmgiReaderEPUB
import AmgiUI
import Foundation

struct ReaderLibraryViewData: Equatable {
    var continueReading: [ContinueReadingItem]
    /// Every book matching the search, sorted, ignoring collections.
    var allBooks: [BookCellItem]
    /// What the top-level grid shows: collections, then the books not in one.
    /// While searching, every match wherever it is filed.
    var grid: [LibraryGridItem] = []
    var hasAnkiConfig: Bool
}

/// One cell of the library grid.
enum LibraryGridItem: Identifiable, Equatable {
    case book(BookCellItem)
    case collection(CollectionCellItem)

    var id: String { ref.dragString }

    var ref: ReaderLibraryItemRef {
        switch self {
        case .book(let item): .book(item.id)
        case .collection(let item): .collection(item.id)
        }
    }
}

/// A collection's grid cell: its name, what is in it, and the covers its
/// collage is drawn from.
struct CollectionCellItem: Identifiable, Equatable {
    let id: String
    let name: String
    /// Books anywhere inside, nested collections included.
    let bookCount: Int
    /// Collections directly inside.
    let collectionCount: Int
    /// Up to `CollectionMosaic.maxCovers` books for the collage, nearest first.
    let covers: [BookCellItem]
}

struct ContinueReadingItem: Identifiable, Equatable {
    let id: String
    let title: String
    var author: String? = nil
    let surname: String?
    let progress: Double
    let updatedAt: Date
    let coverArt: CoverArtSource
    var formatLabel: String = "Book"
}

struct BookCellItem: Identifiable, Equatable {
    let id: String
    let title: String
    let author: String?
    let surname: String?
    let coverArt: CoverArtSource
    var progress: Double? = nil
    /// Non-nil when the book is present but unreadable (source missing or no
    /// longer parsing). The row still renders so the book does not silently
    /// disappear; the view turns this into a repair affordance.
    let repair: ReaderBookRepair?
}

enum CoverArtSource: Equatable {
    case epub(localFileURL: URL?)
    case epubFirstPage(EPUBFirstPageSource)
    case pdf(coverURL: URL?, documentURL: URL?)
    case anki(filePath: String?)
    case none
}

/// Where to render an EPUB's first-page cover thumbnail from.
///
/// Carried (rather than resolved in the view) so the model pays the store
/// lookups once per reload instead of every cell paying them per body pass.
struct EPUBFirstPageSource: Equatable, Sendable {
    /// The first chapter's content file.
    let contentURL: URL
    /// The WebView read-access scope (the book's content root).
    let readAccessURL: URL
}

enum ReaderLibraryViewDataBuilder {
    private static let continueReadingLimit = 6

    static func build(
        books: [ReaderBook],
        progressFor: (String) -> ReaderSavedProgress?,
        epubCoverURLFor: (String) -> URL?,
        epubFirstPageFor: (String) -> EPUBFirstPageSource? = { _ in nil },
        repairFor: (String) -> ReaderBookRepair? = { _ in nil },
        addedAt: (String) -> Date? = { _ in nil },
        continueHiddenAt: (String) -> Date? = { _ in nil },
        searchText: String,
        sortMode: BookshelfSortMode,
        hasAnkiConfig: Bool,
        collections: ReaderCollectionTree = ReaderCollectionTree()
    ) -> ReaderLibraryViewData {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered: [ReaderBook] = query.isEmpty ? books : books.filter { book in
            book.title.localizedCaseInsensitiveContains(query)
                || (book.author?.localizedCaseInsensitiveContains(query) ?? false)
        }

        let progressByID: [String: ReaderSavedProgress] = Dictionary(
            uniqueKeysWithValues: filtered.compactMap { book in
                progressFor(book.id).map { (book.id, $0) }
            }
        )

        // A book that needs repair has nothing readable to resume, so it stays
        // out of "continue reading" even if it still has a saved position.
        let continueReading: [ContinueReadingItem] = Array(
            filtered.compactMap { book -> ContinueReadingItem? in
                guard repairFor(book.id) == nil else { return nil }
                guard let p = progressByID[book.id], p.progress > 0, p.progress < 1 else {
                    return nil
                }
                // "Remove from Continue" holds until the book is read again.
                if let hiddenAt = continueHiddenAt(book.id), hiddenAt >= p.updatedAt {
                    return nil
                }
                return ContinueReadingItem(
                    id: book.id,
                    title: book.title,
                    author: book.author,
                    surname: BookMetaFormatters.surname(from: book.author),
                    progress: p.progress,
                    updatedAt: p.updatedAt,
                    coverArt: coverArt(for: book, epubCoverURLFor: epubCoverURLFor, epubFirstPageFor: epubFirstPageFor),
                    formatLabel: formatLabel(for: book)
                )
            }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(Self.continueReadingLimit)
        )

        let allBooks: [BookCellItem] = filtered
            .sorted { lhs, rhs in
                // Books needing repair sort last in every mode: they are not
                // really in the library until repaired.
                let lhsNeedsRepair = repairFor(lhs.id) != nil
                let rhsNeedsRepair = repairFor(rhs.id) != nil
                if lhsNeedsRepair != rhsNeedsRepair { return !lhsNeedsRepair }
                switch sortMode {
                case .recent:
                    // Recently read *or added*, as in Apple Books: a book
                    // imported a moment ago belongs at the front, not at its
                    // title's place among books never opened.
                    let lhsDate = max(progressByID[lhs.id]?.updatedAt ?? .distantPast, addedAt(lhs.id) ?? .distantPast)
                    let rhsDate = max(progressByID[rhs.id]?.updatedAt ?? .distantPast, addedAt(rhs.id) ?? .distantPast)
                    if lhsDate != rhsDate { return lhsDate > rhsDate }
                case .progress:
                    let lhsProgress = progressByID[lhs.id]?.progress ?? 0
                    let rhsProgress = progressByID[rhs.id]?.progress ?? 0
                    if lhsProgress != rhsProgress { return lhsProgress > rhsProgress }
                case .title:
                    break
                }
                let cmp = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
                if cmp != .orderedSame { return cmp == .orderedAscending }
                return lhs.id < rhs.id
            }
            .map { book in
                BookCellItem(
                    id: book.id,
                    title: book.title,
                    author: book.author,
                    surname: BookMetaFormatters.surname(from: book.author),
                    coverArt: coverArt(for: book, epubCoverURLFor: epubCoverURLFor, epubFirstPageFor: epubFirstPageFor),
                    progress: progressByID[book.id]?.progress,
                    repair: repairFor(book.id)
                )
            }

        return ReaderLibraryViewData(
            continueReading: continueReading,
            allBooks: allBooks,
            grid: grid(
                cells: allBooks,
                collections: collections,
                in: nil,
                matching: query.isEmpty ? nil : query
            ),
            hasAnkiConfig: hasAnkiConfig
        )
    }

    /// The grid for one level of the library (`collectionID` nil: the top).
    ///
    /// `cells` must already be in display order; collections go first, by
    /// name, then the books filed at this level. With a `query`, folders
    /// stop mattering: every matching collection and every book in `cells`
    /// (already filtered by the caller) is shown, wherever it is filed.
    static func grid(
        cells: [BookCellItem],
        collections: ReaderCollectionTree,
        in collectionID: String?,
        matching query: String? = nil
    ) -> [LibraryGridItem] {
        let order = cells.map(\.id)
        let cellByID = Dictionary(cells.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        let shownCollections: [ReaderCollection]
        let shownBooks: [BookCellItem]
        if let query {
            shownCollections = collections.liveCollections.filter {
                $0.name.localizedCaseInsensitiveContains(query)
            }
            shownBooks = cells
        } else {
            shownCollections = collections.childCollections(of: collectionID)
            shownBooks = cells.filter { collections.contains(bookID: $0.id, directlyIn: collectionID) }
        }

        let collectionItems = shownCollections
            .sorted {
                let cmp = $0.name.localizedCaseInsensitiveCompare($1.name)
                return cmp == .orderedSame ? $0.id < $1.id : cmp == .orderedAscending
            }
            .map { collection -> LibraryGridItem in
                let inside = collections.booksUnder(collection.id, ordering: order)
                return .collection(CollectionCellItem(
                    id: collection.id,
                    name: collection.name,
                    bookCount: inside.count,
                    collectionCount: collections.childCollections(of: collection.id).count,
                    covers: inside.prefix(CollectionMosaic.maxCovers).compactMap { cellByID[$0] }
                ))
            }
        return collectionItems + shownBooks.map(LibraryGridItem.book)
    }
}

private extension ReaderLibraryViewDataBuilder {
    static func coverArt(
        for book: ReaderBook,
        epubCoverURLFor: (String) -> URL?,
        epubFirstPageFor: (String) -> EPUBFirstPageSource?
    ) -> CoverArtSource {
        switch book.source {
        case .ankiDeck:
            return .anki(filePath: book.coverImagePath)
        case .epub:
            if let coverURL = epubCoverURLFor(book.id) {
                return .epub(localFileURL: coverURL)
            }
            // No embedded cover art. Most EPUBs still open onto their cover,
            // so the first page usually *is* the cover — render it rather
            // than falling back to a generic tile.
            if let firstPage = epubFirstPageFor(book.id) {
                return .epubFirstPage(firstPage)
            }
            return .epub(localFileURL: nil)
        case .pdf(let localURL):
            // The cover file is optional — many PDFs have no embedded cover.
            // Carry the managed document URL alongside so the view can fall
            // back to a first-page thumbnail instead of a generic placeholder.
            return .pdf(coverURL: epubCoverURLFor(book.id), documentURL: localURL)
        }
    }

    static func formatLabel(for book: ReaderBook) -> String {
        switch book.source {
        case .pdf:
            return "PDF"
        case .epub, .ankiDeck:
            return "Book"
        }
    }
}

/// A file being imported, shown as a placeholder tile until its book exists.
struct PendingImport: Identifiable, Equatable {
    let id = UUID()
    /// The file's name without its extension — the best title there is
    /// before the file has been parsed.
    let title: String

    init(url: URL) {
        title = url.deletingPathExtension().lastPathComponent
    }
}

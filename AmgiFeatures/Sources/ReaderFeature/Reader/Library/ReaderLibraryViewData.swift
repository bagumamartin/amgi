import AmgiReader
import AmgiReaderEPUB
import AmgiUI
import Foundation

struct ReaderLibraryViewData: Equatable {
    var continueReading: [ContinueReadingItem]
    var allBooks: [BookCellItem]
    var hasAnkiConfig: Bool
}

struct ContinueReadingItem: Identifiable, Equatable {
    let id: String
    let title: String
    let surname: String?
    let progress: Double
    let updatedAt: Date
    let coverArt: CoverArtSource
}

struct BookCellItem: Identifiable, Equatable {
    let id: String
    let title: String
    let author: String?
    let surname: String?
    let coverArt: CoverArtSource
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
        searchText: String,
        sortMode: BookshelfSortMode,
        hasAnkiConfig: Bool
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
                return ContinueReadingItem(
                    id: book.id,
                    title: book.title,
                    surname: BookMetaFormatters.surname(from: book.author),
                    progress: p.progress,
                    updatedAt: p.updatedAt,
                    coverArt: coverArt(for: book, epubCoverURLFor: epubCoverURLFor, epubFirstPageFor: epubFirstPageFor)
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
                    let lhsDate = progressByID[lhs.id]?.updatedAt ?? .distantPast
                    let rhsDate = progressByID[rhs.id]?.updatedAt ?? .distantPast
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
                    repair: repairFor(book.id)
                )
            }

        return ReaderLibraryViewData(
            continueReading: continueReading,
            allBooks: allBooks,
            hasAnkiConfig: hasAnkiConfig
        )
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
}

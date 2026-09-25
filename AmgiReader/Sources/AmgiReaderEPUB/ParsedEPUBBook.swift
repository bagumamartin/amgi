public import Foundation
public import AmgiReader

/// Output of `EPUBBookParser.parse(fileURL:)`.
///
/// Carries the parsed `ReaderBook` plus the side-channel data the reader
/// UI needs but that doesn't belong on the domain type itself: a map from
/// chapter ID to the on-disk URL of the chapter's HTML, the resolved
/// cover image (if any), the publication language, and the word-count
/// page estimate. The map keys match `ReaderChapter.id` values inside
/// `book.chapters`.
public struct ParsedEPUBBook: Sendable {
    public var book: ReaderBook
    public var chapterContentURLs: [Int64: URL]
    /// Root of the extracted EPUB archive. Keeping this alongside the
    /// content URLs lets a library move a successfully parsed publication
    /// from staging into its managed directory without leaving absolute
    /// URLs pointing at the staging path.
    public var documentDirectory: URL
    /// Directory containing the OPF — the book's content root. WebViews get
    /// read access to this, so sibling `Styles/` and `Images/` folders
    /// referenced by a chapter in `Text/` actually resolve.
    public var contentDirectory: URL
    public var coverImageURL: URL?
    public var language: String?
    public var pageCount: Int

    public init(
        book: ReaderBook,
        chapterContentURLs: [Int64: URL],
        documentDirectory: URL,
        contentDirectory: URL,
        coverImageURL: URL?,
        language: String?,
        pageCount: Int
    ) {
        self.book = book
        self.chapterContentURLs = chapterContentURLs
        self.documentDirectory = documentDirectory
        self.contentDirectory = contentDirectory
        self.coverImageURL = coverImageURL
        self.language = language
        self.pageCount = pageCount
    }
}

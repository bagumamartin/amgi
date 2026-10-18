import AssistantFeature
import AmgiReader
import AmgiTheme
import SwiftUI

/// Direct-to-reader destination router.
///
/// Matches Apple Books behavior: tapping a book immediately resumes reading
/// at the user's last saved progress point, seamlessly opening EPUB, PDF,
/// or Note chapters. The books are local, so nothing here waits: the saved
/// position is read from this device (iCloud's copy is merged in the
/// background by the library and the coordinator).
struct ReaderOpenView: View {
    let book: ReaderBook
    let progress: ReaderProgressCoordinator

    private let savedProgress: ReaderSavedProgress?
    /// The book with its chapter text, once read. Anki-deck books arrive
    /// from the shelf as outlines.
    @State private var loadedBook: ReaderBook?
    @State private var loadFailed = false

    /// Opens at this chapter instead of the saved position.
    private let chapterIndex: Int?

    init(book: ReaderBook, progress: ReaderProgressCoordinator, chapterIndex: Int? = nil) {
        self.book = book
        self.progress = progress
        self.chapterIndex = chapterIndex
        self.savedProgress = progress.store.load(bookID: book.id)
    }

    var body: some View {
        destination
            // The Ask AI pill reads the screen's context from here when the
            // reader has not published a more specific one.
            .transformPreference(AssistantScreenContextKey.self) { value in
                if value.isEmpty { value = [.book(id: book.id, title: book.title)] }
            }
    }

    @ViewBuilder
    private var destination: some View {
        if case .epub = book.source {
            EPUBChapterReaderView(
                book: book,
                chapterIndex: resumeChapterIndex,
                progressCoordinator: progress
            )
        } else if case .pdf = book.source {
            PDFReaderView(
                book: book,
                progressCoordinator: progress
            )
        } else if book.needsChapterContent && loadedBook == nil {
            if loadFailed {
                ContentUnavailableView("Couldn’t Open Book", systemImage: "book.closed")
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .task {
                        loadedBook = await ReaderBookContent.load(book)
                        loadFailed = loadedBook == nil
                    }
            }
        } else if !book.chapters.isEmpty {
            let book = loadedBook ?? book
            let idx = resumeChapterIndex
            ChapterReaderView(
                book: book,
                chapter: book.chapters[min(max(0, idx), book.chapters.count - 1)],
                progress: progress
            )
        } else {
            ContentUnavailableView("No Content", systemImage: "book.closed")
        }
    }

    private var resumeChapterIndex: Int {
        if let chapterIndex { return chapterIndex }
        guard let saved = savedProgress,
              let index = book.chapters.firstIndex(where: { $0.id == saved.chapterID }) else {
            return 0
        }
        return index
    }

}

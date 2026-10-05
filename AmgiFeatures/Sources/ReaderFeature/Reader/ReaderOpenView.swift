import AmgiReader
import AmgiTheme
import SwiftUI

/// Direct-to-reader destination router.
///
/// Matches Apple Books behavior: tapping a book immediately resumes reading
/// at the user's last saved progress point, seamlessly opening EPUB, PDF,
/// or Note chapters.
struct ReaderOpenView: View {
    let book: ReaderBook
    let progress: ReaderProgressCoordinator

    @State private var savedProgress: ReaderSavedProgress?
    @State private var hasLoadedProgress = false

    init(book: ReaderBook, progress: ReaderProgressCoordinator) {
        self.book = book
        self.progress = progress
    }

    var body: some View {
        Group {
            if hasLoadedProgress {
                destination
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            savedProgress = await progress.resolved(bookID: book.id)
            hasLoadedProgress = true
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
        } else if !book.chapters.isEmpty {
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
        guard let saved = savedProgress,
              let index = book.chapters.firstIndex(where: { $0.id == saved.chapterID }) else {
            return 0
        }
        return index
    }

}

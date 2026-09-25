import AmgiReader
import AmgiTheme
import AmgiUI
import Foundation
import SwiftUI

/// Centered content column for the book-detail screen, matching the
/// Library/Study columns so the header and chapter list stay readable on
/// regular-width layouts instead of stretching full-width.
private enum ReaderBookDetailColumn {
    static let maxWidth: CGFloat = 800
}

/// The chapter rail is a desktop composition, not a consequence of a
/// regular size class. A narrow iPad detail pane keeps the chapter list in
/// the document instead of reserving a fixed 220-point rail beside a tiny
/// reader canvas.
enum ReaderBookDetailLayout: Equatable {
    case narrow
    case wide

    static let minimumWideWidth: CGFloat = 720

    static func resolve(
        availableWidth: CGFloat,
        isAccessibilitySize: Bool
    ) -> ReaderBookDetailLayout {
        guard !isAccessibilitySize, availableWidth >= minimumWideWidth else {
            return .narrow
        }
        return .wide
    }
}

struct ReaderBookDetailView: View {
    let book: ReaderBook
    let progress: ReaderProgressCoordinator

    @State private var model = ReaderBookDetailModel()
    @State private var savedProgress: ReaderSavedProgress?
    @State private var selectedChapterIndex: Int?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        GeometryReader { proxy in
            let layout = ReaderBookDetailLayout.resolve(
                availableWidth: proxy.size.width,
                isAccessibilitySize: dynamicTypeSize.isAccessibilitySize
            )
            Group {
                if layout == .wide {
                    wideLayout
                } else {
                    bookSummary
                }
            }
        }
        .navigationTitle(book.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            savedProgress = await progress.resolved(bookID: book.id)
            await model.load(book: book)
        }
        .onReceive(NotificationCenter.default.publisher(for: .amgiReaderCardAdded)) { note in
            guard let bookID = note.userInfo?["bookID"] as? String,
                  bookID == book.id else { return }
            Task { await model.load(book: book) }
        }
    }

    private var bookSummary: some View {
        ReaderBookDetailContent(
            book: book,
            savedProgress: savedProgress,
            state: model.state,
            progress: progress,
            onSelectChapter: nil
        )
    }

    private var wideLayout: some View {
        HStack(spacing: 0) {
            ReaderChapterSidebar(
                book: book,
                selection: $selectedChapterIndex,
                savedProgress: savedProgress,
                pageRanges: pageRanges,
                cardsByChapter: cardsByChapter
            )
            .frame(minWidth: 220, idealWidth: 260, maxWidth: 300)

            Divider()

            Group {
                if let selectedChapterIndex,
                   book.chapters.indices.contains(selectedChapterIndex) {
                    chapterDestination(at: selectedChapterIndex)
                } else {
                    ReaderBookDetailContent(
                        book: book,
                        savedProgress: savedProgress,
                        state: model.state,
                        progress: progress,
                        onSelectChapter: nil
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var pageRanges: [Int64: ClosedRange<Int>] {
        if case .loaded(_, _, let ranges) = model.state { return ranges }
        return [:]
    }

    private var cardsByChapter: [Int64: Int] {
        if case .loaded(_, let counts, _) = model.state { return counts }
        return [:]
    }

    @ViewBuilder
    private func chapterDestination(at index: Int) -> some View {
        if case .epub = book.source {
            EPUBChapterReaderView(
                book: book,
                chapterIndex: index,
                progressCoordinator: progress,
                onClose: { selectedChapterIndex = nil }
            )
        } else if book.chapters.indices.contains(index) {
            ChapterReaderView(
                book: book,
                chapter: book.chapters[index],
                progress: progress,
                chapterIndex: index,
                onNavigateToChapter: { selectedChapterIndex = $0 }
            )
        }
    }
}

/// Persistent chapter rail used inside the regular-width book detail. It
/// remains mounted while a chapter reader is visible, so switching chapters
/// never pushes another opaque reader on top of the previous one.
private struct ReaderChapterSidebar: View {
    let book: ReaderBook
    @Binding var selection: Int?
    let savedProgress: ReaderSavedProgress?
    let pageRanges: [Int64: ClosedRange<Int>]
    let cardsByChapter: [Int64: Int]

    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("CHAPTERS")
                    .amgiFont(.captionBold)
                    .foregroundStyle(palette.textSecondary)
                Spacer()
                if selection != nil {
                    Button {
                        selection = nil
                    } label: {
                        Image(systemName: "book.closed")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Show book details")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            if book.chapters.isEmpty {
                ContentUnavailableView(
                    "No Chapters",
                    systemImage: "text.book.closed",
                    description: Text("This book does not contain readable chapters.")
                )
            } else {
                List(selection: $selection) {
                    ForEach(Array(book.chapters.enumerated()), id: \.element.id) { index, chapter in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(chapter.title)
                                .amgiFont(selection == index ? .bodyEmphasis : .body)
                                .lineLimit(2)
                            if let subline = subline(for: chapter) {
                                Text(subline)
                                    .amgiFont(.caption)
                                    .foregroundStyle(palette.textSecondary)
                            }
                            if savedProgress?.chapterID == chapter.id {
                                ProgressView(value: savedProgress?.progress ?? 0)
                                    .progressViewStyle(.linear)
                                    .tint(palette.accent)
                            }
                        }
                        .padding(.vertical, 3)
                        .tag(index)
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .background(palette.surface)
    }

    private func subline(for chapter: ReaderChapter) -> String? {
        var parts: [String] = []
        if let range = pageRanges[chapter.id] {
            parts.append(range.lowerBound == range.upperBound
                ? "\(range.lowerBound)"
                : "\(range.lowerBound)–\(range.upperBound)")
        }
        if let cards = cardsByChapter[chapter.id], cards > 0 {
            parts.append("\(cards) card\(cards == 1 ? "" : "s")")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

private struct ReaderBookDetailContent: View {
    let book: ReaderBook
    let savedProgress: ReaderSavedProgress?
    let state: ReaderBookDetailModel.ViewState
    let progress: ReaderProgressCoordinator
    let onSelectChapter: ((Int) -> Void)?

    private var coverURL: URL? {
        if case .loaded(let url, _, _) = state { return url }
        return nil
    }

    private var cardsByChapter: [Int64: Int] {
        if case .loaded(_, let counts, _) = state { return counts }
        return [:]
    }

    private var pageRanges: [Int64: ClosedRange<Int>] {
        if case .loaded(_, _, let ranges) = state { return ranges }
        return [:]
    }

    private var isEPUB: Bool {
        if case .epub = book.source { return true }
        return false
    }

    private var overallProgressPercent: Int {
        let total = book.chapters.count
        guard total > 0 else { return 0 }
        guard let saved = savedProgress,
              let savedIndex = book.chapters.firstIndex(where: { $0.id == saved.chapterID }) else {
            return 0
        }
        let completed = Double(savedIndex)
        let combined = (completed + saved.progress) / Double(total)
        return Int((combined * 100).rounded())
    }

    private var currentChapterIndex: Int? {
        guard let saved = savedProgress else { return nil }
        return book.chapters.firstIndex(where: { $0.id == saved.chapterID })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                BookHeaderView(
                    book: book,
                    coverURL: coverURL,
                    isEPUB: isEPUB
                )
                ContinueBlock(
                    percent: overallProgressPercent,
                    resumeIndex: resumeChapterIndex,
                    destination: destinationForChapter(at:),
                    onSelect: onSelectChapter
                )
                ChaptersSection(
                    book: book,
                    pageRanges: pageRanges,
                    cardsByChapter: cardsByChapter,
                    currentIndex: currentChapterIndex,
                    isChapterComplete: isChapterComplete(at:),
                    destination: destinationForChapter(at:),
                    onSelect: onSelectChapter
                )
            }
            .frame(maxWidth: ReaderBookDetailColumn.maxWidth)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
    }

    /// The chapter we resume into when the user taps "Continue". Defaults
    /// to the first chapter on a brand-new book; otherwise picks the
    /// last-read chapter index, falling back to 0 if the saved chapterID
    /// can't be matched (book mutated since last read, for example).
    private var resumeChapterIndex: Int {
        if let saved = savedProgress,
           let index = book.chapters.firstIndex(where: { $0.id == saved.chapterID }) {
            return index
        }
        return 0
    }
}

private extension ReaderBookDetailContent {
    @ViewBuilder
    func destinationForChapter(at index: Int) -> some View {
        if case .epub = book.source {
            EPUBChapterReaderView(
                book: book,
                chapterIndex: max(0, min(index, book.chapters.count - 1)),
                progressCoordinator: progress
            )
        } else if index >= 0, index < book.chapters.count {
            ChapterReaderView(
                book: book,
                chapter: book.chapters[index],
                progress: progress
            )
        }
    }

    func isChapterComplete(at index: Int) -> Bool {
        guard let saved = savedProgress,
              let savedIndex = book.chapters.firstIndex(where: { $0.id == saved.chapterID }) else {
            return false
        }
        if index < savedIndex { return true }
        if index == savedIndex { return saved.progress >= 0.99 }
        return false
    }
}

// MARK: - Header

private struct BookHeaderView: View {
    let book: ReaderBook
    let coverURL: URL?
    let isEPUB: Bool

    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 12) {
            cover
                .frame(width: 140, height: 190)
                .background(palette.separator, in: RoundedRectangle(cornerRadius: AmgiRadius.small))
                .clipShape(RoundedRectangle(cornerRadius: AmgiRadius.small))
                .amgiChromeShadow(RoundedRectangle(cornerRadius: AmgiRadius.small), radius: 8, y: 4, opacity: 0.18)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)

            Text(book.title)
                .amgiFont(.sectionHeading)
                .multilineTextAlignment(.center)
                .lineLimit(3)

            if let author = book.author {
                Text(author)
                    .amgiFont(.body)
                    .foregroundStyle(palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }

            if let meta = metaText {
                Text(meta)
                    .amgiFont(.caption)
                    .foregroundStyle(palette.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var cover: some View {
        if isEPUB {
            ReaderCoverImage(fileURL: coverURL, isEPUB: true) { placeholder }
        } else {
            ReaderCoverImage(path: book.coverImagePath) { placeholder }
        }
    }

    private var placeholder: some View {
        Image(systemName: "book.closed")
            .foregroundStyle(palette.textSecondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var metaText: String? {
        var parts: [String] = []
        if let pages = book.pageCount {
            parts.append("\(pages) pages")
        }
        if let language = book.language, !language.isEmpty {
            parts.append(language)
        }
        let chapters = book.chapters.count
        parts.append("\(chapters) chapter\(chapters == 1 ? "" : "s")")
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - Continue block

private struct ContinueBlock<Destination: View>: View {
    let percent: Int
    let resumeIndex: Int
    @ViewBuilder var destination: (Int) -> Destination
    let onSelect: ((Int) -> Void)?

    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 8) {
            Group {
                if let onSelect {
                    Button { onSelect(resumeIndex) } label: { label }
                } else {
                    NavigationLink { destination(resumeIndex) } label: { label }
                }
            }
            .buttonStyle(.pressScale)

            ProgressView(value: Double(percent), total: 100)
                .progressViewStyle(.linear)
                .tint(palette.accent)
        }
    }

    private var label: some View {
        Text("Continue · \(percent)%")
            .amgiFont(.cardTitle)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(palette.accent, in: RoundedRectangle(cornerRadius: AmgiRadius.inset))
    }
}

// MARK: - Chapters section

private struct ChaptersSection<Destination: View>: View {
    let book: ReaderBook
    let pageRanges: [Int64: ClosedRange<Int>]
    let cardsByChapter: [Int64: Int]
    let currentIndex: Int?
    let isChapterComplete: (Int) -> Bool
    @ViewBuilder var destination: (Int) -> Destination
    let onSelect: ((Int) -> Void)?

    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CHAPTERS")
                .amgiFont(.captionBold)
                .foregroundStyle(palette.textSecondary)
                .padding(.top, 8)
            VStack(spacing: 0) {
                ForEach(Array(book.chapters.enumerated()), id: \.element.id) { index, chapter in
                    Group {
                        if let onSelect {
                            Button { onSelect(index) } label: {
                                row(index: index, chapter: chapter)
                            }
                        } else {
                            NavigationLink { destination(index) } label: {
                                row(index: index, chapter: chapter)
                            }
                        }
                    }
                    .buttonStyle(.pressScale)
                    if index < book.chapters.count - 1 {
                        Divider().padding(.leading, 48)
                    }
                }
            }
            .background(palette.surface, in: RoundedRectangle(cornerRadius: AmgiRadius.inset))
        }
    }

    private func row(index: Int, chapter: ReaderChapter) -> some View {
        ChapterRow(
            index: index,
            chapter: chapter,
            pageRange: pageRanges[chapter.id],
            cardsAdded: cardsByChapter[chapter.id] ?? 0,
            isComplete: isChapterComplete(index),
            isCurrent: currentIndex == index
        )
    }
}

private struct ChapterRow: View {
    let index: Int
    let chapter: ReaderChapter
    let pageRange: ClosedRange<Int>?
    let cardsAdded: Int
    let isComplete: Bool
    let isCurrent: Bool

    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 12) {
            leading
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(chapter.title)
                    .amgiFont(.body)
                    .foregroundStyle(isCurrent ? palette.accent : palette.textPrimary)
                    .lineLimit(2)
                if let subline {
                    Text(subline)
                        .amgiFont(.caption)
                        .foregroundStyle(palette.textSecondary)
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .amgiFont(.captionBold)
                .foregroundStyle(palette.textTertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var leading: some View {
        if isComplete {
            Image(systemName: "checkmark.circle.fill")
                .amgiFont(.sectionHeading)
                .foregroundStyle(palette.positive)
        } else {
            Text(String(format: "%02d", index + 1))
                .amgiFont(.captionBold)
                .foregroundStyle(isCurrent ? palette.accent : palette.textSecondary)
        }
    }

    private var subline: String? {
        var parts: [String] = []
        if let range = pageRange {
            parts.append(range.lowerBound == range.upperBound
                ? "\(range.lowerBound)"
                : "\(range.lowerBound)–\(range.upperBound)")
        }
        if cardsAdded > 0 {
            parts.append("\(cardsAdded) card\(cardsAdded == 1 ? "" : "s") added")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

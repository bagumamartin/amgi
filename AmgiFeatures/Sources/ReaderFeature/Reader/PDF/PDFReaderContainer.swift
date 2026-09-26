import AmgiReader
import SwiftUI

/// The PDF reader, with a layout that adapts to the space available.
///
/// One view rather than a regular and a compact variant, because the parts that
/// differ are the sidebar and the toolbar's density, and branching on size class
/// at the top would mean two whole subtrees to keep in step for what is one
/// decision. `PDFReaderLayout` does the arranging; this decides when the
/// sidebar is worth the width.
struct PDFReaderView: View {
    let book: ReaderBook
    let progressCoordinator: ReaderProgressCoordinator
    /// The page to open at, from the chapter the user tapped.
    let startPageIndex: Int

    @State private var model: PDFReaderModel
    @State private var navigation = PDFReaderNavigation()
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    init(
        book: ReaderBook,
        progressCoordinator: ReaderProgressCoordinator,
        startPageIndex: Int = 0
    ) {
        self.book = book
        self.progressCoordinator = progressCoordinator
        self.startPageIndex = startPageIndex
        _model = State(
            initialValue: PDFReaderModel(book: book, progress: progressCoordinator)
        )
    }

    var body: some View {
        Group {
            switch model.state {
            case .loading:
                ProgressView("Opening \(book.title)…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                PDFReaderUnavailableView(message: message) {
                    Task { await model.load() }
                }
            case .ready:
                layout
            }
        }
        .task { await open() }
        .onDisappear { model.persistPosition(navigation.pageIndex) }
    }

    /// Opens the document and puts the reader where the user asked to be.
    ///
    /// An explicitly chosen page — which tapping a chapter always is — wins over
    /// a saved position. Resuming is the point of a reading position, but only
    /// when the user has not just said where they want to be, and honouring the
    /// saved one here would make the chapter list feel broken.
    private func open() async {
        await model.load()
        guard case .ready = model.state else { return }
        let page = startPageIndex > 0 ? startPageIndex : await model.restoredPageIndex()
        navigation.move(
            toPage: page,
            label: model.label(forPage: page),
            count: model.pageCount,
            // Not user-initiated: opening at a position is not turning a page,
            // and recording it would make the resume point follow the act of
            // opening the book.
            userInitiated: false
        )
    }

    @ViewBuilder
    private var layout: some View {
        // The sidebar is the first thing to give up room. It is a navigation
        // aid rather than the content, and a reader with a 240pt sidebar on a
        // phone is reading in a letterbox.
        GeometryReader { proxy in
            let isNarrow = proxy.size.width < 700
            PDFReaderLayout(model: model, navigation: $navigation)
                .onAppear {
                    navigation.isSidebarVisible = !isNarrow
                }
                .onChange(of: isNarrow) { _, narrow in
                    navigation.isSidebarVisible = !narrow
                }
        }
    }
}

/// Shown when a PDF cannot be opened.
///
/// Says what went wrong and offers the one action that can help. A bare spinner
/// or a blank page leaves the user with no idea whether the file is missing,
/// encrypted, or simply large.
struct PDFReaderUnavailableView: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.richtext")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("This PDF could not be opened")
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Try again", action: onRetry)
                .buttonStyle(.bordered)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

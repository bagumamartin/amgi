import PDFKit
import SwiftUI

/// The left sidebar: page thumbnails, the document outline, and the list of
/// annotations.
///
/// Three lists rather than one, as in Preview. They answer different questions
/// — "where am I", "what is in this book", "what have I marked" — and merging
/// them produces a list that is none of those things.
struct PDFSidebar: View {
    let model: PDFReaderModel
    /// The page in front of the reader, so the thumbnail strip can highlight it.
    ///
    /// A value rather than the navigation object: the sidebar only reads it, and
    /// taking the whole object would let it move the reader by accident, which
    /// is the mistake that makes a sidebar feel like it is fighting the content.
    let pageIndex: Int
    @Binding var tab: PDFSidebarTab
    let onGoToPage: (Int) -> Void
    let onSelectAnnotation: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Picker("Sidebar", selection: $tab) {
                ForEach(PDFSidebarTab.allCases) { item in
                    Label(item.label, systemImage: item.symbolName).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)

            Divider()

            switch tab {
            case .thumbnails:
                PDFThumbnailList(
                    model: model,
                    currentPage: pageIndex,
                    onSelect: onGoToPage
                )
            case .outline:
                PDFOutlineList(
                    bookmarks: model.bookmarks,
                    currentPage: pageIndex,
                    onSelect: onGoToPage
                )
            case .annotations:
                PDFAnnotationList(
                    annotations: model.allAnnotations,
                    labelForPage: { model.label(forPage: $0) },
                    currentPage: pageIndex,
                    onSelect: { annotation in
                        onSelectAnnotation(annotation.id)
                        onGoToPage(annotation.pageIndex)
                    }
                )
            }
        }
        .background(.background)
    }
}

/// A scrolling strip of page thumbnails.
///
/// Rendered with PDFKit's own thumbnail generator rather than snapshots of the
/// canvas: a snapshot of a page the user has not scrolled to is not available,
/// and generating them all up front for a 900-page document would cost seconds
/// and hundreds of megabytes for a list the user may never scroll.
private struct PDFThumbnailList: View {
    let model: PDFReaderModel
    let currentPage: Int
    let onSelect: (Int) -> Void

    private let columns = [GridItem(.adaptive(minimum: 96, maximum: 120), spacing: 12)]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(0..<max(0, model.pageCount), id: \.self) { index in
                        PDFThumbnailCell(
                            page: index,
                            document: model.document,
                            isCurrent: index == currentPage,
                            label: model.label(forPage: index)
                        )
                        .id(index)
                        .onTapGesture { onSelect(index) }
                    }
                }
                .padding(12)
            }
            .onChange(of: currentPage) { _, page in
                // Following the reader is what makes the strip navigable rather
                // than decorative, and it must not animate — a scroll animation
                // on every page turn fights the page turn itself.
                proxy.scrollTo(page, anchor: .center)
            }
        }
    }
}

private struct PDFThumbnailCell: View {
    let page: Int
    let document: PDFDocument?
    let isCurrent: Bool
    let label: String

    @State private var image: PlatformImage?

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 2)
                    .fill(.background)
                if let image {
                    Image(platformImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(isCurrent ? Color.accentColor : .clear, lineWidth: 2)
            }
            Text(label)
                .font(.caption2)
                .foregroundStyle(isCurrent ? .primary : .secondary)
                // The document's own numbering, so a book with roman front
                // matter reads "iv" here and not "4".
                .monospacedDigit()
        }
        .task(id: page) {
            image = await Self.thumbnail(for: page, in: document)
        }
    }

    /// Rendered off the main actor and downsampled to the cell's size.
    ///
    /// At full page resolution a thumbnail for a 900-page book is hundreds of
    /// megabytes; at twice the cell's width it is indistinguishable on screen.
    private static func thumbnail(for page: Int, in document: PDFDocument?) async -> PlatformImage? {
        guard let document, let pdfPage = document.page(at: page) else { return nil }
        return PDFThumbnailRenderer.render(page: pdfPage)
    }
}

/// The document outline, indented by depth.
///
/// Entries whose destination does not resolve are listed but not tappable, and
/// say so. Dropping them would hide chapters the user can see in Preview;
/// making them tappable would give a row that does nothing.
private struct PDFOutlineList: View {
    let bookmarks: [PDFBookmark]
    let currentPage: Int
    let onSelect: (Int) -> Void

    var body: some View {
        if bookmarks.isEmpty {
            PDFSidebarEmptyState(
                symbol: "list.bullet.indent",
                title: "No table of contents",
                message: "This PDF does not declare an outline."
            )
        } else {
            List {
                ForEach(bookmarks) { bookmark in
                    Button {
                        onSelect(bookmark.pageIndex)
                    } label: {
                        HStack(spacing: 6) {
                            Text(bookmark.title)
                                .lineLimit(2)
                                .font(.callout)
                            Spacer(minLength: 4)
                            if bookmark.hasDestination {
                                Text(pageLabel(bookmark.pageIndex))
                                    .font(.caption)
                                    .foregroundStyle(
                                        bookmark.pageIndex == currentPage ? .primary : .secondary
                                    )
                            } else {
                                // Visible, and visibly inert.
                                Image(systemName: "questionmark.circle")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .help("This entry has no destination in the file")
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!bookmark.hasDestination)
                    .padding(.leading, CGFloat(bookmark.depth) * 12)
                }
            }
            .listStyle(.sidebar)
        }
    }

    private func pageLabel(_ index: Int) -> String {
        // 1-based for display, matching what the page field shows.
        String(index + 1)
    }
}

/// Every annotation in the document, grouped by page.
private struct PDFAnnotationList: View {
    let annotations: [PDFPageAnnotation]
    let labelForPage: (Int) -> String
    let currentPage: Int
    let onSelect: (PDFPageAnnotation) -> Void

    var body: some View {
        if annotations.isEmpty {
            PDFSidebarEmptyState(
                symbol: "highlighter",
                title: "No markup yet",
                message: "Choose a tool and drag on the page to mark it up."
            )
        } else {
            List(annotations) { annotation in
                Button {
                    onSelect(annotation)
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Circle()
                            .fill(Color(annotation.colour.swiftUIColor))
                            .frame(width: 10, height: 10)
                            .padding(.top, 4)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(annotation.kind.label)
                                .font(.callout.weight(.medium))
                            Text(annotation.contents?.isEmpty == false
                                 ? annotation.contents!
                                 : "Page \(labelForPage(annotation.pageIndex))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.sidebar)
        }
    }
}

private struct PDFSidebarEmptyState: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.callout.weight(.medium))
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The search field with match navigation.
struct PDFSearchBar: View {
    @Binding var text: String
    let resultCount: Int
    let onNext: () -> Void
    let onPrevious: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Find in document", text: $text)
                .textFieldStyle(.plain)
                .onSubmit(onNext)
            if !text.isEmpty {
                // Saying "0 results" is what stops the user concluding the
                // feature is broken when their search genuinely has no hits.
                Text(resultCount == 0 ? "No results" : "\(resultCount) found")
                    .font(.caption)
                    .foregroundStyle(resultCount == 0 ? .secondary : .primary)
            }
            Button(action: onPrevious) {
                Image(systemName: "chevron.up")
            }
            .disabled(text.isEmpty || resultCount == 0)
            Button(action: onNext) {
                Image(systemName: "chevron.down")
            }
            .disabled(text.isEmpty || resultCount == 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

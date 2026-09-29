import AmgiReader
import AmgiReaderPDF
import AmgiTheme
import AmgiUI
import PDFKit
import Sharing
import SwiftUI

/// Apple Books-style PDF Reader.
///
/// Features:
/// - Full-screen immersive reading with tap-to-toggle chrome.
/// - Unlocked pinch-to-zoom (0.25x to 5.0x) and double-tap zoom.
/// - Fluid page navigation: Continuous Vertical Scroll or Paginated (Slide/Curl).
/// - Apple Books bottom page scrubber with interactive dragging, page preview bubble, and haptics.
/// - Top chrome with Close, Book Title running head, Bookmark toggle, Search, and Contents sheet.
/// - Native text selection contextual callout: Highlight in 4 colors, Look Up in dictionary, Make Anki Card, Copy.
/// - Unified Contents sheet (PDF Outline TOC, Bookmarks, Highlights & Notes).
/// - Unified Reading Style & Themes sheet (Default, Sepia, Dark).
struct PDFReaderView: View {
    let book: ReaderBook
    let progressCoordinator: ReaderProgressCoordinator
    let startPageIndex: Int
    var onClose: (() -> Void)? = nil

    @State private var model: PDFReaderModel
    @State private var navigation = PDFReaderNavigation()
    @State private var chromeVisible: Bool = true
    @State private var isMarkupActive: Bool = false
    @State private var isContentsSheetPresented = false
    @State private var isStyleSheetPresented = false
    @State private var isSearchVisible = false
    @State private var searchText = ""
    @State private var searchResultCount = 0
    @State private var selection: PDFSelectionContext?
    @State private var lookupRequest: LookupRequest?

    // Bookmarks & sidecar annotations
    @State private var annotations = ReaderAnnotationModel()

    @Shared(.appStorage(ReaderTypographyPreferences.Keys.theme))
    private var themeRaw: String = ReaderTypographyPreferences.Theme.default.rawValue
    @Shared(.appStorage(ReaderPreferenceKeys.pageTransition))
    private var pageTransitionRaw: String = ReaderPageTransition.scroll.rawValue

    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette

    private var theme: ReaderTypographyPreferences.Theme {
        ReaderTypographyPreferences.Theme(rawValue: themeRaw) ?? .default
    }

    private var pageTransition: ReaderPageTransition {
        ReaderPageTransition(rawValue: pageTransitionRaw) ?? .scroll
    }

    init(
        book: ReaderBook,
        progressCoordinator: ReaderProgressCoordinator,
        startPageIndex: Int = 0,
        onClose: (() -> Void)? = nil
    ) {
        self.book = book
        self.progressCoordinator = progressCoordinator
        self.startPageIndex = startPageIndex
        self.onClose = onClose
        _model = State(
            initialValue: PDFReaderModel(book: book, progress: progressCoordinator)
        )
    }

    private var isCurrentPageBookmarked: Bool {
        annotations.bookmarks.contains { $0.anchor.cfi == navigation.pageIndex }
    }

    var body: some View {
        Group {
            switch model.state {
            case .loading:
                ProgressView("Opening \(book.title)…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Unable to Open Document", systemImage: "doc.text.magnifyingglass")
                } description: {
                    Text(message)
                } actions: {
                    Button("Retry") {
                        Task { await model.load() }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .ready:
                readerBody
            }
        }
        .task { await open() }
        .onDisappear {
            model.persistPosition(navigation.pageIndex)
        }
        .sheet(isPresented: $isContentsSheetPresented) {
            contentsSheet
        }
        .sheet(isPresented: $isStyleSheetPresented) {
            ReaderStyleSheet(isPDF: true)
        }
        .sheet(isPresented: lookupSheetPresented) {
            lookupPopupContent
        }
    }

    // MARK: - Reader Body

    private var readerBody: some View {
        ZStack(alignment: .bottom) {
            // Theme background
            theme.backgroundColor
                .ignoresSafeArea()

            // PDF Canvas
            PDFPageCanvas(
                model: model,
                navigation: navigation,
                searchTerm: isSearchVisible && !searchText.isEmpty ? searchText : nil,
                theme: theme,
                onPageChanged: { index in
                    navigation.move(
                        toPage: index,
                        label: model.label(forPage: index),
                        count: model.pageCount,
                        userInitiated: true
                    )
                },
                onSearchResultsChanged: { count in
                    searchResultCount = count
                },
                onStepSearchResult: { delta in
                    PDFViewCoordinatorRegistry.shared.coordinator?.stepSearchResult(by: delta)
                },
                onSelectionChanged: { ctx in
                    selection = ctx
                },
                onTapCenter: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        chromeVisible.toggle()
                    }
                },
                onTapPrevPage: {
                    let prev = max(0, navigation.pageIndex - 1)
                    navigation.move(
                        toPage: prev,
                        label: model.label(forPage: prev),
                        count: model.pageCount,
                        userInitiated: true
                    )
                },
                onTapNextPage: {
                    let next = min(model.pageCount - 1, navigation.pageIndex + 1)
                    navigation.move(
                        toPage: next,
                        label: model.label(forPage: next),
                        count: model.pageCount,
                        userInitiated: true
                    )
                }
            )
            .ignoresSafeArea()

            // In-document search dropdown
            if isSearchVisible {
                VStack {
                    searchBar
                        .padding(.top, 60)
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            // Inline Selection Callout
            if let selection, !selection.text.isEmpty {
                selectionCallout(for: selection)
                    .padding(.bottom, chromeVisible ? 100 : 30)
                    .transition(.scale(scale: 0.95).combined(with: .opacity))
            }

            // Floating Top Chrome
            if chromeVisible {
                VStack(spacing: 0) {
                    topChromeRow
                    Spacer()
                }
                .transition(.opacity)
            }

            // Floating Bottom Thumbnail Filmstrip Scrubber
            if chromeVisible {
                PDFThumbnailScrubber(
                    document: model.document,
                    pageCount: model.pageCount,
                    currentPage: navigation.pageIndex,
                    onSeek: { targetPage in
                        navigation.move(
                            toPage: targetPage,
                            label: model.label(forPage: targetPage),
                            count: model.pageCount,
                            userInitiated: true
                        )
                    }
                )
                .padding(.bottom, 12)
                .transition(.opacity)
            }
        }
        .navigationBarBackButtonHidden(true)
        #if os(iOS)
        .toolbarVisibility(.hidden, for: .navigationBar)
        .toolbarVisibility(.hidden, for: .tabBar)
        #endif
        .onChange(of: pageTransitionRaw) { _, _ in
            navigation.transition = (pageTransition == .scroll) ? .continuous : .scroll
            PDFViewCoordinatorRegistry.shared.coordinator?.apply(navigation)
        }
    }

    // MARK: - Floating Chrome Components

    private var topChromeRow: some View {
        HStack(alignment: .top) {
            topLeftCapsule

            Spacer()

            VStack(alignment: .trailing, spacing: 8) {
                topRightCapsule
                pageBadge
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var topLeftCapsule: some View {
        HStack(spacing: 12) {
            Button {
                closeReader()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                    .frame(width: 24, height: 24)
            }
            .accessibilityLabel("Back to Library")

            Button {
                isContentsSheetPresented = true
            } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                    .frame(width: 24, height: 24)
            }
            .accessibilityLabel("Contents")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .amgiMaterial(.regular, in: Capsule(), interactive: true)
        .amgiMaterialElevation(Capsule())
    }

    private var topRightCapsule: some View {
        HStack(spacing: 16) {
            Button {
                isMarkupActive.toggle()
            } label: {
                Image(systemName: "pencil.tip.crop.circle")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(isMarkupActive ? palette.accent : palette.textPrimary)
                    .frame(width: 24, height: 24)
            }
            .accessibilityLabel("Markup")

            Button {
                isStyleSheetPresented = true
            } label: {
                Text("AA")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(palette.textPrimary)
                    .frame(width: 24, height: 24)
            }
            .accessibilityLabel("Themes & Settings")

            Button {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                    isSearchVisible.toggle()
                    if !isSearchVisible {
                        searchText = ""
                        PDFViewCoordinatorRegistry.shared.coordinator?.search(nil)
                    }
                }
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isSearchVisible ? palette.accent : palette.textPrimary)
                    .frame(width: 24, height: 24)
            }
            .accessibilityLabel("Search")

            Button {
                toggleBookmark()
            } label: {
                Image(systemName: isCurrentPageBookmarked ? "bookmark.fill" : "bookmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isCurrentPageBookmarked ? palette.accent : palette.textPrimary)
                    .frame(width: 24, height: 24)
            }
            .accessibilityLabel(isCurrentPageBookmarked ? "Remove Bookmark" : "Bookmark")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .amgiMaterial(.regular, in: Capsule(), interactive: true)
        .amgiMaterialElevation(Capsule())
    }

    private var pageBadge: some View {
        Text("\(navigation.pageIndex + 1) of \(max(1, model.pageCount))")
            .amgiFont(.caption, .monospacedDigits)
            .foregroundStyle(palette.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .amgiMaterial(.regular, in: RoundedRectangle(cornerRadius: 6))
            .amgiMaterialElevation(RoundedRectangle(cornerRadius: 6))
    }

    private func closeReader() {
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }

    private var currentSectionTitle: String? {
        let currentIdx = navigation.pageIndex
        let matching = model.bookmarks.filter { $0.pageIndex <= currentIdx }
        return matching.last?.title
    }

    // MARK: - Selection Callout Menu

    private func selectionCallout(for context: PDFSelectionContext) -> some View {
        HStack(spacing: 8) {
            // Highlight color swatches
            ForEach([
                PDFAnnotationColour.yellow,
                PDFAnnotationColour.green,
                PDFAnnotationColour.blue,
                PDFAnnotationColour.pink
            ], id: \.self) { colour in
                Button {
                    let pageIndex = context.pageIndex
                    let bounds: CGRect
                    if let pageBounds = context.pageBounds {
                        bounds = pageBounds
                    } else if let page = model.document?.page(at: context.pageIndex) {
                        let pBox = page.bounds(for: .cropBox)
                        let pRect = context.regionRect.pdfRect(pageWidth: pBox.width, pageHeight: pBox.height)
                        bounds = CGRect(x: pRect.x, y: pRect.y, width: pRect.width, height: pRect.height)
                    } else {
                        bounds = .zero
                    }
                    selection = nil
                    Task { @MainActor in
                        _ = await model.addAnnotation(
                            kind: .highlight,
                            pageIndex: pageIndex,
                            bounds: bounds,
                            colour: colour
                        )
                    }
                } label: {
                    Circle()
                        .fill(colour.swiftUIColor)
                        .frame(width: 22, height: 22)
                        .overlay(Circle().stroke(Color.white.opacity(0.8), lineWidth: 1.5))
                }
                .accessibilityLabel("Highlight \(colour.rawValue)")
            }

            Divider().frame(height: 20)

            // Look Up
            Button {
                lookupRequest = LookupRequest(
                    token: context.text,
                    sentence: context.text,
                    anchor: ReaderSourceAnchor(
                        bookID: book.id,
                        quote: context.text,
                        contextBefore: context.anchor.contextBefore,
                        contextAfter: context.anchor.contextAfter
                    )
                )
                selection = nil
            } label: {
                Label("Look Up", systemImage: "character.book.closed")
                    .amgiFont(.captionBold)
                    .foregroundStyle(palette.textPrimary)
            }

            Divider().frame(height: 20)

            // Make Anki Card
            Button {
                lookupRequest = LookupRequest(
                    token: context.text,
                    sentence: context.text,
                    anchor: ReaderSourceAnchor(
                        bookID: book.id,
                        quote: context.text,
                        contextBefore: context.anchor.contextBefore,
                        contextAfter: context.anchor.contextAfter
                    )
                )
                selection = nil
            } label: {
                Label("Make Card", systemImage: "text.badge.plus")
                    .amgiFont(.captionBold)
                    .foregroundStyle(palette.accent)
            }

            Divider().frame(height: 20)

            // Copy
            Button {
                #if os(iOS)
                UIPasteboard.general.string = context.text
                #elseif os(macOS)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(context.text, forType: .string)
                #endif
                selection = nil
            } label: {
                Image(systemName: "doc.on.doc")
                    .amgiFont(.caption)
                    .foregroundStyle(palette.textPrimary)
            }
            .accessibilityLabel("Copy")

            // Close
            Button {
                selection = nil
            } label: {
                Image(systemName: "xmark")
                    .amgiFont(.micro)
                    .foregroundStyle(palette.textSecondary)
            }
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .amgiMaterial(.regular, in: Capsule(), interactive: true)
        .amgiMaterialElevation(Capsule())
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(palette.textSecondary)

            TextField("Search in document…", text: $searchText)
                .textFieldStyle(.plain)
                .onSubmit {
                    PDFViewCoordinatorRegistry.shared.coordinator?.search(searchText)
                }

            if searchResultCount > 0 {
                Text("\(searchResultCount) found")
                    .amgiFont(.caption, .monospacedDigits)
                    .foregroundStyle(palette.textSecondary)

                Button {
                    PDFViewCoordinatorRegistry.shared.coordinator?.stepSearchResult(by: -1)
                } label: {
                    Image(systemName: "chevron.up")
                }

                Button {
                    PDFViewCoordinatorRegistry.shared.coordinator?.stepSearchResult(by: 1)
                } label: {
                    Image(systemName: "chevron.down")
                }
            }

            Button {
                withAnimation {
                    isSearchVisible = false
                    searchText = ""
                    PDFViewCoordinatorRegistry.shared.coordinator?.search(nil)
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(palette.textSecondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .amgiMaterial(.regular, in: RoundedRectangle(cornerRadius: AmgiRadius.control), interactive: true)
        .amgiMaterialElevation(RoundedRectangle(cornerRadius: AmgiRadius.control))
        .padding(.horizontal, 20)
    }

    // MARK: - Contents Sheet

    private var contentsSheet: some View {
        let outlineItems: [ReaderContentsSheet.OutlineItem] = model.bookmarks.map { bm in
            ReaderContentsSheet.OutlineItem(
                id: bm.id,
                title: bm.title,
                pageIndex: bm.pageIndex,
                pageLabel: model.label(forPage: bm.pageIndex),
                depth: bm.depth,
                isCurrent: bm.pageIndex == navigation.pageIndex
            )
        }

        let bookmarkItems: [ReaderContentsSheet.BookmarkItem] = annotations.bookmarks.map { bm in
            let pageIdx = bm.anchor.cfi ?? 0
            return ReaderContentsSheet.BookmarkItem(
                id: bm.id.uuidString,
                pageIndex: pageIdx,
                pageLabel: model.label(forPage: pageIdx),
                title: bm.excerpt,
                date: bm.createdAt
            )
        }

        let noteItems: [ReaderContentsSheet.NoteItem] = model.allAnnotations.map { annot in
            ReaderContentsSheet.NoteItem(
                id: annot.id,
                pageIndex: annot.pageIndex,
                pageLabel: model.label(forPage: annot.pageIndex),
                quote: annot.contents ?? "Highlight",
                colorHex: annot.colour.swiftUIColor.description
            )
        }

        return ReaderContentsSheet(
            bookTitle: book.title,
            outlineItems: outlineItems,
            bookmarks: bookmarkItems,
            notes: noteItems,
            onSelectOutline: { item in
                navigation.move(
                    toPage: item.pageIndex,
                    label: model.label(forPage: item.pageIndex),
                    count: model.pageCount,
                    userInitiated: true
                )
            },
            onSelectBookmark: { item in
                navigation.move(
                    toPage: item.pageIndex,
                    label: model.label(forPage: item.pageIndex),
                    count: model.pageCount,
                    userInitiated: true
                )
            },
            onDeleteBookmark: { item in
                if let uuid = UUID(uuidString: item.id),
                   let existing = annotations.bookmarks.first(where: { $0.id == uuid }) {
                    Task { await annotations.delete(existing) }
                }
            },
            onSelectNote: { item in
                navigation.move(
                    toPage: item.pageIndex,
                    label: model.label(forPage: item.pageIndex),
                    count: model.pageCount,
                    userInitiated: true
                )
            }
        )
    }

    // MARK: - Bookmarks

    private func toggleBookmark() {
        let currentPage = navigation.pageIndex
        if let existing = annotations.bookmarks.first(where: { $0.anchor.cfi == currentPage }) {
            Task { await annotations.delete(existing) }
        } else {
            let label = model.label(forPage: currentPage)
            let anchor = ReaderSourceAnchor(
                bookID: book.id,
                cfi: currentPage,
                quote: "Page \(label)",
                contextBefore: currentSectionTitle
            )
            Task {
                await annotations.addBookmark(
                    in: book.id,
                    anchor: anchor,
                    excerpt: currentSectionTitle ?? "Page \(label)"
                )
            }
        }
    }

    // MARK: - Open & Resume

    private func open() async {
        await model.load()
        await annotations.load(bookID: book.id)
        guard case .ready = model.state else { return }

        navigation.transition = (pageTransition == .scroll) ? .continuous : .scroll
        let page = startPageIndex > 0 ? startPageIndex : await model.restoredPageIndex()
        navigation.move(
            toPage: page,
            label: model.label(forPage: page),
            count: model.pageCount,
            userInitiated: false
        )
    }

    // MARK: - Dictionary Lookup

    private var lookupSheetPresented: Binding<Bool> {
        Binding(
            get: { lookupRequest != nil },
            set: { if !$0 { lookupRequest = nil } }
        )
    }

    @ViewBuilder
    private var lookupPopupContent: some View {
        if let req = lookupRequest {
            LookupPopupView(
                initialQuery: req.token,
                languageHint: nil,
                contextSentence: req.sentence,
                sourceAnchor: req.anchor,
                extraTags: ["amgi::book::\(book.id)"],
                onDismiss: { lookupRequest = nil }
            )
        }
    }
}

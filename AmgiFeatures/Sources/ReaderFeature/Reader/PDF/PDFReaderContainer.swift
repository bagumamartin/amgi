import AmgiReader
import AmgiReaderPDF
import AmgiTheme
import AmgiUI
import PDFKit
import Sharing
import SwiftUI

#if os(macOS)
import AppKit
#endif

#if canImport(UIKit) && !os(macOS)
import UIKit
#endif

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
    let startPageIndex: Int?
    var onClose: (() -> Void)? = nil

    @State private var model: PDFReaderModel
    @State private var navigation: PDFReaderNavigation
    @State private var canvasCoordinator: PDFViewCoordinator
    @State private var hasRestoredInitialPage = false
    @State private var chromeVisible: Bool = true
    @State private var isMarkupActive: Bool = false
    @State private var isContentsSheetPresented = false
    @State private var isStyleSheetPresented = false
    @State private var isSearchVisible = false
    @State private var searchText = ""
    @State private var searchResultCount = 0
    @State private var macSidebarVisible = true
    @State private var macThumbnailWidth: CGFloat = 174
    @State private var selection: PDFSelectionContext?
    @State private var lookupRequest: LookupRequest?

    // Bookmarks & sidecar annotations
    @State private var annotations = ReaderAnnotationModel()

    @Shared(.appStorage(ReaderTypographyPreferences.Keys.theme))
    private var themeRaw: String = ReaderTypographyPreferences.Theme.default.rawValue
    @Shared(.appStorage(PDFReaderPreferences.Keys.pageNavigation))
    private var pdfPageNavigationRaw: String = PDFReaderPreferences.PageNavigation.paged.rawValue

    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.pdfReaderWindowState) private var pdfReaderWindowState

    private var theme: ReaderTypographyPreferences.Theme {
        ReaderTypographyPreferences.Theme(rawValue: themeRaw) ?? .default
    }

    private var pageNavigation: PDFReaderPreferences.PageNavigation {
        PDFReaderPreferences.PageNavigation(rawValue: pdfPageNavigationRaw) ?? .paged
    }

    init(
        book: ReaderBook,
        progressCoordinator: ReaderProgressCoordinator,
        startPageIndex: Int? = nil,
        onClose: (() -> Void)? = nil
    ) {
        self.book = book
        self.progressCoordinator = progressCoordinator
        self.startPageIndex = startPageIndex
        self.onClose = onClose
        let navigation = PDFReaderNavigation()
        _navigation = State(initialValue: navigation)
        _canvasCoordinator = State(initialValue: PDFViewCoordinator(navigation: navigation))
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
                        Task { await open() }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .ready where hasRestoredInitialPage:
                readerBody
            case .ready:
                ProgressView("Opening \(book.title)…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await open() }
        .onAppear {
            #if os(macOS)
            pdfReaderWindowState?.isActive = true
            #endif
        }
        .onDisappear {
            model.persistPosition(navigation.pageIndex)
            #if os(macOS)
            pdfReaderWindowState?.isActive = false
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .inactive || phase == .background {
                model.persistPosition(navigation.pageIndex)
            }
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

    private var pageNavigationTransition: PDFReaderNavigation.Transition {
        #if os(macOS)
        .continuous
        #else
        pageNavigation == .continuous ? .continuous : .scroll
        #endif
    }

    @ViewBuilder
    private var readerBody: some View {
        #if os(macOS)
        macReaderBody
        #else
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                theme.backgroundColor
                    .ignoresSafeArea()

                PDFPageCanvas(
                    model: model,
                    navigation: navigation,
                    coordinator: canvasCoordinator,
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
                        canvasCoordinator.stepSearchResult(by: delta)
                    },
                    onSelectionChanged: { ctx in
                        selection = ctx
                    },
                    onTapCenter: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            chromeVisible.toggle()
                        }
                    },
                    onTapPrevPage: { navigate(to: navigation.turn(by: -1), userInitiated: true) },
                    onTapNextPage: { navigate(to: navigation.turn(by: 1), userInitiated: true) }
                )
                .ignoresSafeArea()

                if isSearchVisible {
                    VStack {
                        searchBar
                            .padding(.top, 60)
                        Spacer()
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                if let selection, !selection.text.isEmpty {
                    selectionCallout(for: selection)
                        .padding(.bottom, chromeVisible ? 100 : 30)
                        .transition(.scale(scale: 0.95).combined(with: .opacity))
                }

                if chromeVisible {
                    VStack(spacing: 0) {
                        topChromeRow(isWide: geometry.size.width >= 600)
                        Spacer()
                    }
                    .transition(.opacity)

                    PDFThumbnailScrubber(
                        model: model,
                        pageCount: model.pageCount,
                        currentPage: navigation.pageIndex,
                        onSeek: { targetPage in navigate(to: targetPage, userInitiated: true) },
                        onInteractionChanged: { canvasCoordinator.setScrubberActive($0) }
                    )
                    .transition(.opacity)
                }
            }
            .navigationBarBackButtonHidden(true)
            #if os(iOS)
            .toolbarVisibility(.hidden, for: .navigationBar)
            .toolbarVisibility(.hidden, for: .tabBar)
            #endif
            .onChange(of: pdfPageNavigationRaw) { _, _ in
                navigation.transition = pageNavigationTransition
                canvasCoordinator.apply(navigation)
            }
            .onChange(of: geometry.size) { _, _ in
                canvasCoordinator.layoutChanged()
            }
        }
        #endif
    }

    #if os(macOS)
    private var macReaderBody: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    if macSidebarVisible {
                        PDFMacThumbnailSidebar(
                            model: model,
                            currentPage: navigation.pageIndex,
                            onSelectPage: { navigate(to: $0, userInitiated: true) },
                            thumbnailWidth: $macThumbnailWidth
                        )
                        Divider()
                    }

                    ZStack(alignment: .bottom) {
                        PDFPageCanvas(
                            model: model,
                            navigation: navigation,
                            coordinator: canvasCoordinator,
                            searchTerm: !searchText.isEmpty ? searchText : nil,
                            theme: theme,
                            onPageChanged: { index in
                                navigation.move(
                                    toPage: index,
                                    label: model.label(forPage: index),
                                    count: model.pageCount,
                                    userInitiated: true
                                )
                            },
                            onSearchResultsChanged: { searchResultCount = $0 },
                            onStepSearchResult: { canvasCoordinator.stepSearchResult(by: $0) },
                            onSelectionChanged: { selection = $0 }
                        )

                        if let selection, !selection.text.isEmpty {
                            selectionCallout(for: selection)
                                .padding(.bottom, 20)
                                .transition(.scale(scale: 0.95).combined(with: .opacity))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .onAppear {
                canvasCoordinator.layoutChanged()
            }
            .onChange(of: geometry.size) { _, _ in
                canvasCoordinator.layoutChanged()
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationBarBackButtonHidden(true)
        .toolbar { macToolbar }
        .onChange(of: pdfPageNavigationRaw) { _, _ in
            navigation.transition = pageNavigationTransition
            canvasCoordinator.apply(navigation)
        }
        .onChange(of: macSidebarVisible) { _, _ in
            canvasCoordinator.layoutChanged()
        }
    }

    @ToolbarContentBuilder
    private var macToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button(action: closeReader) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
            }
            .help("Back to Library")
            .accessibilityLabel("Back to Library")

            Button {
                macSidebarVisible.toggle()
            } label: {
                Image(systemName: macSidebarVisible ? "sidebar.left" : "sidebar.right")
            }
            .help(macSidebarVisible ? "Hide Page Thumbnails" : "Show Page Thumbnails")
            .accessibilityLabel(macSidebarVisible ? "Hide Page Thumbnails" : "Show Page Thumbnails")

            VStack(alignment: .leading, spacing: 2) {
                Text(model.managedURL?.lastPathComponent ?? book.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("Page \(navigation.pageIndex + 1) of \(max(1, model.pageCount))")
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .frame(minWidth: 190, maxWidth: 280, alignment: .leading)
        }

        ToolbarItem(placement: .principal) {
            HStack(spacing: 0) {
                macToolbarButton("minus.magnifyingglass", label: "Zoom Out") {
                    canvasCoordinator.zoom(by: 1 / 1.2)
                }
                Divider().frame(height: 20)
                macToolbarButton("1.magnifyingglass", label: "Actual Size") {
                    canvasCoordinator.useActualSize()
                }
                Divider().frame(height: 20)
                macToolbarButton("plus.magnifyingglass", label: "Zoom In") {
                    canvasCoordinator.zoom(by: 1.2)
                }
            }
            .padding(.horizontal, 3)
            .background(Color.primary.opacity(0.055), in: Capsule())
        }

        ToolbarItemGroup(placement: .automatic) {
            HStack(spacing: 6) {
                macToolbarButton("pencil.tip.crop.circle", label: "Markup") {
                    isMarkupActive.toggle()
                }
                .foregroundStyle(isMarkupActive ? Color.accentColor : Color.primary)

                macToolbarButton("a.circle", label: "Themes and Settings") {
                    isStyleSheetPresented = true
                }

                macToolbarButton("info.circle", label: "Contents and Annotations") {
                    isContentsSheetPresented = true
                }

                if let managedURL = model.managedURL {
                    ShareLink(item: managedURL) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .help("Share PDF")
                    .accessibilityLabel("Share PDF")
                }
            }

        }

        ToolbarItem(placement: .primaryAction) {
            macSearchField
        }
    }

    private func macToolbarButton(
        _ symbol: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 30, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    private var macSearchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("Search", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .onSubmit { canvasCoordinator.search(searchText) }

            if searchResultCount > 0 {
                Text("\(searchResultCount)")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                Button { canvasCoordinator.stepSearchResult(by: -1) } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.plain)
                .help("Previous Match")

                Button { canvasCoordinator.stepSearchResult(by: 1) } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.plain)
                .help("Next Match")
            }

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    searchResultCount = canvasCoordinator.search(nil)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear Search")
            }
        }
        .padding(.horizontal, 10)
        .frame(width: 250, height: 30)
        .background(Color.primary.opacity(0.055), in: Capsule())
    }
    #endif

    // MARK: - Floating Chrome Components

    private func topChromeRow(isWide: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            topLeftCapsule(isWide: isWide)

            if isWide {
                Spacer(minLength: 12)
                Text(book.title)
                    .amgiFont(.bodyEmphasis)
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 10)
                Spacer(minLength: 12)
            } else {
                Spacer(minLength: 6)
            }

            VStack(alignment: .trailing, spacing: 8) {
                topRightCapsule
                pageBadge
            }
        }
        .padding(.horizontal, isWide ? 20 : 16)
        .padding(.top, 8)
    }

    private func topLeftCapsule(isWide: Bool) -> some View {
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

            if isWide, let managedURL = model.managedURL {
                ShareLink(item: managedURL) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(palette.textPrimary)
                        .frame(width: 24, height: 24)
                }
                .accessibilityLabel("Share PDF")
            }
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
                        canvasCoordinator.search(nil)
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
                    canvasCoordinator.search(searchText)
                }

            if searchResultCount > 0 {
                Text("\(searchResultCount) found")
                    .amgiFont(.caption, .monospacedDigits)
                    .foregroundStyle(palette.textSecondary)

                Button {
                    canvasCoordinator.stepSearchResult(by: -1)
                } label: {
                    Image(systemName: "chevron.up")
                }

                Button {
                    canvasCoordinator.stepSearchResult(by: 1)
                } label: {
                    Image(systemName: "chevron.down")
                }
            }

            Button {
                withAnimation {
                    isSearchVisible = false
                    searchText = ""
                    canvasCoordinator.search(nil)
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
                navigate(to: item.pageIndex, userInitiated: true)
            },
            onSelectBookmark: { item in
                navigate(to: item.pageIndex, userInitiated: true)
            },
            onDeleteBookmark: { item in
                if let uuid = UUID(uuidString: item.id),
                   let existing = annotations.bookmarks.first(where: { $0.id == uuid }) {
                    Task { await annotations.delete(existing) }
                }
            },
            onSelectNote: { item in
                navigate(to: item.pageIndex, userInitiated: true)
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

        navigation.transition = pageNavigationTransition
        let page: Int
        if let startPageIndex {
            page = startPageIndex
        } else {
            page = await model.restoredPageIndex()
        }
        navigation.move(
            toPage: page,
            label: model.label(forPage: page),
            count: model.pageCount,
            userInitiated: false
        )
        canvasCoordinator.apply(navigation)
        hasRestoredInitialPage = true
    }

    /// Move the document view and all reader chrome from one navigation state.
    /// The coordinator suppresses PDFKit's programmatic page notification; the
    /// state is updated here so the badge and scrubber move in the same frame.
    private func navigate(to pageIndex: Int, userInitiated: Bool) {
        navigation.move(
            toPage: pageIndex,
            label: model.label(forPage: pageIndex),
            count: model.pageCount,
            userInitiated: userInitiated
        )
        canvasCoordinator.apply(navigation)
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

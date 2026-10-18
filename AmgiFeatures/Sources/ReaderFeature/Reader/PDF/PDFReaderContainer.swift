import AmgiReader
import AmgiReaderPDF
import AmgiTheme
import AmgiUI
import BrowseFeature
import PDFKit
import Sharing
import AssistantFeature
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
/// - Text selection: PDFKit's own menu, carrying Highlight in 4 colours, Look Up in the dictionary, and the card actions.
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
    @State private var scrubState = PDFScrubState()
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
    @State private var cards = ReaderCardSession()
    /// Text or area selection; area draws boxes over the page for cards.
    @State private var captureMode: ReaderCaptureMode = .text
    /// What has been captured, drawn on the pages in its colours.
    @State private var captureMarks = PDFCaptureMarks()

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
        .preference(key: AssistantScreenContextKey.self, value: assistantContext)
        // A tapped capture's menu, over everything, at the capture.
        .overlay { ReaderMarkMenuLayer(session: cards) }
        .animation(AmgiMotion.standard, value: cards.markMenu?.id)
        .task { await open() }
        .onAppear {
            #if os(macOS)
            pdfReaderWindowState?.isActive = true
            #endif
        }
        .onDisappear {
            model.persistPosition(navigation.pageIndex)
            // Leaving the book saves the cards that are ready.
            Task { [cards] in await cards.saveReadyDrafts() }
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
                .presentationDetents([.large])
        }
        .sheet(isPresented: $isStyleSheetPresented) {
            ReaderStyleSheet(isPDF: true)
        }
        .sheet(isPresented: lookupSheetPresented) {
            lookupPopupContent
        }
        .overlay(alignment: .bottom) {
            if case .ready = model.state, hasRestoredInitialPage {
                cardLayer
            }
        }
        .sheet(item: editingDraftSheet) { item in
            ReaderCardDraftSheet(draftID: item.id, session: cards, onGoTo: goTo)
        }
        .sheet(item: $cards.openedNote) { opened in
            NoteEditingDestinationView(
                note: opened.note,
                embedInNavigationStack: true,
                onSave: { cards.openedNote = nil }
            )
        }
        .sensoryFeedback(.success, trigger: cards.savedCount)
        .sensoryFeedback(.impact(weight: .light), trigger: cards.clippedCount)
    }

    private var assistantContext: AssistantContext {
        AssistantContext(title: book.title, reference: "Source book:\(book.id), page:\(navigation.pageIndex + 1). Page text: \(String((model.document?.page(at: navigation.pageIndex)?.string ?? "").prefix(5000))). Selected text: \(selection?.text ?? "")", kind: "reader")
    }

    private static let assistantButtonSize: CGFloat = 44

    // MARK: - Card Capture

    /// The draft dock and the capture toast, floating over the page — the same
    /// layer the EPUB reader shows, so an unfinished card stays in reach.
    private var cardLayer: some View {
        VStack(spacing: 10) {
            if let toast = cards.toast {
                ReaderCardToastView(toast: toast) {
                    Task { await cards.undo(toast) }
                }
                .transition(AmgiMotion.slide(from: .bottom))
            }
            ReaderCardDock(
                drafts: cards.drafts.drafts,
                onOpen: { cards.editingDraftID = $0 },
                onSave: { id in Task { await cards.save(id) } },
                onCycle: { forward in Task { await cards.drafts.cycle(forward: forward) } },
                onDiscard: { id in Task { await cards.discard(id) } },
                onGoTo: goTo,
                onBringToFront: { id in Task { await cards.drafts.bringToFront(id) } },
                onDrop: { text, id in
                    let selection = canvasCoordinator.contextProvider?(.textSelection, nil)
                        .map(selectionPayload(for:))
                    canvasCoordinator.clearSelection()
                    Task { await cards.drop(text, on: id, selection: selection) }
                },
                onRecolour: { id, colour in Task { await cards.setColour(colour, forDraft: id) } },
                imageURL: { cards.drafts.imageURL($0) }
            )
        }
        .frame(maxWidth: .infinity)
        .padding(.leading, 16)
        #if os(macOS)
        .padding(.trailing, 16)
        .padding(.bottom, 14)
        #else
        // Leaves Ask AI its column whenever the chrome is showing.
        .padding(.trailing, chromeVisible ? 16 + Self.assistantButtonSize + 12 : 16)
        // Clears the page scrubber while the chrome is up.
        .padding(.bottom, chromeVisible ? 100 : 14)
        #endif
        .animation(AmgiMotion.momentum, value: cards.drafts.drafts.map(\.id))
        .animation(AmgiMotion.standard, value: cards.toast)
    }

    private var editingDraftSheet: Binding<DraftSheetItem?> {
        Binding(
            get: { cards.editingDraftID.map(DraftSheetItem.init) },
            set: { cards.editingDraftID = $0?.id }
        )
    }

    /// PDF clips carry their page in `cfi`, the same slot bookmarks use.
    private func goTo(_ anchor: ReaderSourceAnchor) {
        guard let page = anchor.cfi else { return }
        navigate(to: page, userInitiated: true)
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
                .overlay {
                    if captureMode == .area {
                        areaCaptureOverlay()
                            .ignoresSafeArea()
                            .transition(.opacity)
                    }
                }

                if isSearchVisible {
                    VStack {
                        searchBar
                            .padding(.top, 60)
                        Spacer()
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
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
                        scrubState: scrubState,
                        onSeek: { targetPage in navigate(to: targetPage, userInitiated: true) },
                        // Live scrub seeks bypass `navigation`: publishing it
                        // re-evaluates this whole body (including the page-text
                        // assistant preference) every frame. The release commits.
                        onScrubSeek: { targetPage in canvasCoordinator.go(toPageIndex: targetPage) },
                        onInteractionChanged: { canvasCoordinator.setScrubberActive($0) }
                    )
                    .transition(.opacity)

                    // Over the scrubber's trailing end: the strip is 56pt
                    // tall with 12pt beneath it, plus a 12pt gap.
                    ReaderAssistantButton(context: { assistantContext }, size: Self.assistantButtonSize)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.trailing, 16)
                        .padding(.bottom, 12 + 56 + 12)
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

                ReaderAssistantButton(context: { assistantContext }, size: 28, floating: false)

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
            ReaderCaptureModeButton(
                mode: $captureMode,
                colour: cards.captureColour,
                onColour: { cards.setCaptureColour($0) },
                inline: true
            )

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
        PDFPageBadgeText(
            scrubState: scrubState,
            navigationPage: navigation.pageIndex,
            pageCount: model.pageCount
        )
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

    // MARK: - Selection Menu

    /// The reader's items for PDFKit's own selection menu — the same items,
    /// through the same card session, as the EPUB reader's. With a card
    /// waiting, the menu leads with Add to Back; filling the missing side
    /// saves it.
    private func selectionMenu() -> (entries: [ReaderSelectionMenuEntry], actions: ReaderSelectionMenuActions)? {
        guard let context = canvasCoordinator.contextProvider?(.textSelection, nil), context.hasText else {
            return nil
        }
        let payload = selectionPayload(for: context)
        // A PDF bookmark marks a page, from the top bar, not a selection.
        let entries = ReaderSystemSelectionMenu.entries(for: payload, context: cards.drafts.menuContext)
            .filter { $0 != .action(.bookmark) }
        let actions = ReaderSelectionMenuActions(
            perform: { action in
                switch action {
                case .lookUp:
                    lookupRequest = LookupRequest(
                        token: payload.token,
                        sentence: payload.sentence,
                        anchor: payload.anchor
                    )
                case .highlight:
                    addHighlight(for: context, colour: .yellow)
                case .copy:
                    copyToPasteboard(context.text)
                case .bookmark:
                    break
                }
                canvasCoordinator.clearSelection()
            },
            card: { command in
                canvasCoordinator.clearSelection()
                Task { await cards.handle(command, payload: payload, chapterID: nil) }
            },
            highlightColours: [PDFAnnotationColour.yellow, .green, .blue, .pink].map { colour in
                .init(title: colour.label, color: colour.platformColor) {
                    addHighlight(for: context, colour: colour)
                    canvasCoordinator.clearSelection()
                }
            }
        )
        return (entries, actions)
    }

    /// A PDF selection as the card session takes it. PDF clips carry their
    /// page in `cfi`, the slot bookmarks use.
    private func selectionPayload(for context: PDFSelectionContext) -> ReaderSelectionPayload {
        ReaderSelectionPayload(
            text: context.text,
            token: context.text,
            sentence: context.text,
            anchor: ReaderSourceAnchor(
                bookID: book.id,
                cfi: context.pageIndex,
                quote: ReaderSourceAnchor.normalize(context.text),
                contextBefore: context.anchor.contextBefore,
                contextAfter: context.anchor.contextAfter
            )
        )
    }

    private func addHighlight(for context: PDFSelectionContext, colour: PDFAnnotationColour) {
        let bounds: CGRect
        if let pageBounds = context.pageBounds {
            bounds = pageBounds
        } else if let page = model.document?.page(at: context.pageIndex) {
            let pBox = page.bounds(for: .cropBox)
            let pRect = context.regionRect.pdfRect(pageWidth: pBox.width, pageHeight: pBox.height)
            bounds = CGRect(x: pRect.x, y: pRect.y, width: pRect.width, height: pRect.height)
        } else {
            return
        }
        Task { @MainActor in
            _ = await model.addAnnotation(
                kind: .highlight,
                pageIndex: context.pageIndex,
                bounds: bounds,
                colour: colour
            )
        }
    }

    private func copyToPasteboard(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
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
        let currentOutlineID = PDFContentsPosition.currentEntryID(
            in: model.bookmarks,
            page: navigation.pageIndex
        )
        let outlineItems: [ReaderContentsSheet.OutlineItem] = model.bookmarks.map { bm in
            ReaderContentsSheet.OutlineItem(
                id: bm.id,
                title: bm.title,
                pageIndex: bm.pageIndex,
                pageLabel: model.label(forPage: bm.pageIndex),
                depth: bm.depth,
                isCurrent: bm.id == currentOutlineID
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

        // Highlights and captures together, by page.
        let captures = cards.captureListings()
        let highlightItems = model.allAnnotations.map { annot in
            ReaderContentsSheet.NoteItem(
                id: annot.id,
                pageIndex: annot.pageIndex,
                pageLabel: model.label(forPage: annot.pageIndex),
                quote: annot.contents ?? "Highlight",
                colorHex: annot.colour.hex
            )
        }
        let captureItems = captures.map { capture in
            let page = capture.anchor?.cfi ?? 0
            return ReaderContentsSheet.NoteItem(
                id: capture.id,
                pageIndex: page,
                pageLabel: model.label(forPage: page),
                quote: capture.quote,
                colorHex: capture.colorHex,
                kind: capture.kind == .card ? .card : .draft,
                secondary: capture.secondary,
                images: capture.images
            )
        }
        let noteItems = (highlightItems + captureItems).sorted { $0.pageIndex < $1.pageIndex }

        return ReaderContentsSheet(
            bookTitle: book.title,
            outlineItems: outlineItems,
            bookmarks: bookmarkItems,
            notes: noteItems,
            headerSubtitle: "Page \(model.label(forPage: navigation.pageIndex)) of \(max(1, model.pageCount))",
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
            },
            noteActions: listActions
        )
    }

    /// What the highlights list can do to a mark. A PDF highlight lives in
    /// the file, so its note and its removal are written there; captures go
    /// through the card session, as from the page.
    private var listActions: ReaderContentsSheet.NoteActions {
        func isCapture(_ item: ReaderContentsSheet.NoteItem) -> Bool { item.kind != .highlight }
        return ReaderContentsSheet.NoteActions(
            edit: { item in
                guard let menu = cards.menu(forListing: item.id) else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                    Task { await cards.openMarkTarget(menu) }
                }
            },
            setNote: { item, text in
                guard !isCapture(item) else { return }
                Task { _ = await model.updateAnnotation(identifier: item.id, contents: text) }
            },
            remove: { item in
                if isCapture(item) {
                    guard let menu = cards.menu(forListing: item.id) else { return }
                    Task { await cards.removeMark(menu) }
                } else {
                    Task { _ = await model.removeAnnotation(identifier: item.id) }
                }
            },
            deleteCard: { item in
                guard let menu = cards.menu(forListing: item.id) else { return }
                Task { await cards.deleteCard(menu) }
            },
            recolour: { item, colour in
                if isCapture(item) {
                    guard let menu = cards.menu(forListing: item.id) else { return }
                    Task { await cards.recolourMark(menu, to: colour) }
                } else {
                    Task { _ = await model.recolourAnnotation(identifier: item.id, colour: colour) }
                }
            },
            canRecolour: { _ in true }
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

    #if os(iOS)
    /// Boxes drawn over the page become pictures on cards, rendered from the
    /// page itself.
    private func areaCaptureOverlay() -> some View {
        ReaderAreaCaptureOverlay(
            colour: cards.captureColour,
            targetTitle: cards.drafts.frontmost?.shortTitle,
            onAction: { action, rect in
                guard let capture = canvasCoordinator.regionCapture(viewRect: rect, bookID: book.id) else {
                    cards.showToast(.init(message: "Couldn’t capture that area", systemImage: "exclamationmark.triangle"))
                    return
                }
                Task { await cards.handleRegion(cards.command(for: action), capture: capture) }
            },
            onTap: { withAnimation(AmgiMotion.standard) { chromeVisible.toggle() } }
        )
    }
    #endif

    /// Redraws every capture — saved cards and drafts — on the pages.
    private func repaintCaptureMarks() {
        guard let document = model.document else { return }
        captureMarks.paint(
            PDFCaptureMarks.marks(cards: annotations.cards, drafts: cards.drafts.drafts),
            in: document
        )
    }

    // MARK: - Open & Resume

    private func open() async {
        await model.load()
        await annotations.load(bookID: book.id)
        await cards.attach(book: book, annotations: annotations)
        canvasCoordinator.selectionMenu = { selectionMenu() }
        cards.onMarksChanged = { repaintCaptureMarks() }
        canvasCoordinator.onCaptureMarkTap = { id, kind, point in
            Task { await cards.markTapped(id: id, kind: kind, at: point) }
        }
        cards.onGoTo = { goTo($0) }
        repaintCaptureMarks()
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

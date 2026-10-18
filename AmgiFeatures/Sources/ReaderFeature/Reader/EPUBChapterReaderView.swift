import AmgiReader
import AmgiTheme
import AmgiUI
import AmgiAppCore
import AssistantFeature
import BrowseFeature
import SwiftUI

/// Top-level EPUB reading screen. The iOS host uses native UIKit page-curl
/// controllers for interactive turns; each controller displays one logical
/// EPUB page from its chapter. Compact controls and the compact reader menu
/// are available on both iPhone and iPad.
struct EPUBChapterReaderView: View {
    let book: ReaderBook
    /// Index into `book.chapters` of the chapter currently displayed.
    @State var chapterIndex: Int
    let progressCoordinator: ReaderProgressCoordinator
    /// Regular-width book detail supplies this to return from a chapter to
    /// the book summary while keeping its chapter sidebar mounted. Standalone
    /// chapter presentations leave it nil and dismiss normally.
    var onClose: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var model = EPUBChapterReaderModel()
    /// Highlights, bookmarks, and full-book search.
    @State private var annotations = ReaderAnnotationModel()
    /// Card creation while reading: one-tap captures, the draft stack, and
    /// the marks and undo they leave behind.
    @State private var cards = ReaderCardSession()
    /// Bridge to the live page controller for anchor capture and mark
    /// application. Injected into the paging host rather than reached through
    /// the representable, which owns its own coordinator.
    @State private var pageCommands = ReaderPageCommands()
    @State private var annotationsSheetVisible = false
    @State private var contentsSheetVisible = false
    @State private var searchSheetVisible = false
    @State private var pageJumpVisible = false
    @State private var pageJumpInput = ""
    @State private var compactMenuVisible = false
    /// Text or area selection; area draws boxes over the page for cards.
    @State private var captureMode: ReaderCaptureMode = .text
    @State private var readingHistory: [ReaderReadingPosition] = []
    @State private var previousPosition: ReaderReadingPosition?
    @State private var skipNextHistoryRecord = false
    @State private var currentViewportAnchor: ReaderSourceAnchor?
    @State private var anchorCapturePosition: ReaderReadingPosition?
    @State private var searchModel = EPUBBookSearchModel()

    /// Page-turn effect. Curl by default, like Apple Books.
    @AppStorage(EPUBReaderPreferences.Keys.pageTransition)
    private var pageTransitionRaw: String = ReaderPageTransition.curl.rawValue

    private var pageTransition: ReaderPageTransition {
        ReaderPageTransition(rawValue: pageTransitionRaw) ?? .curl
    }

    /// Running total of rendered pages per chapter, so the reader can be given
    /// a real page number instead of a chapter-relative one.
    @State private var pagination = ReaderPaginationIndex(chapterCount: 0)

    /// The position shown in the tap-revealed header: the page number within
    /// the current chapter, which is what Apple Books shows there.
    private var chapterPageNumber: Int { pageIndex + 1 }

    /// Book-wide page number, printed on the page itself.
    private var bookPageNumber: Int {
        let beforeCurrentChapter = book.chapters.indices
            .filter { $0 < chapterIndex }
            .reduce(0) { total, index in
                total + (pagination.pageCounts[index] ?? book.chapters[index].pageCount ?? 1)
            }
        return beforeCurrentChapter + pageIndex + 1
    }

    /// Total pages known so far. A lower bound until every chapter has been
    /// measured, which is why it is not printed on the page.
    @State private var pageIndex: Int = 0
    @State private var pageCount: Int = 1
    /// Last index spoken to VoiceOver, so a restore or an edge bounce does not
    /// re-announce the page the user is already on.
    @State private var lastAnnouncedPageIndex: Int?
    @State private var progressFraction: Double = 0
    @State private var pendingRestoreFraction: Double?
    @State private var lookupRequest: LookupRequest?
    @State private var selectionRequestID = 0
    @State private var pageTurnRequest: ReaderPageTurnRequest?
    @State private var navigationRequestID = 0
    @State private var didRequestInitialRestore = false
    @State private var chromeVisible: Bool = true
    @State private var pageTurnAnimationActive = false
    @State private var endOfBookToastVisible: Bool = false
    @State private var didShowEndOfBookToast: Bool = false
    @State private var endOfBookToastDismiss: Task<Void, Never>?
    /// Coalesces progress writes. Every page turn used to encode into
    /// UserDefaults and fire a detached write into the Anki collection;
    /// swiping through a chapter issued one of each per page.
    @State private var progressSaveDebounce: Task<Void, Never>?
    #if os(iOS)
    @FocusState private var keyboardFocused: Bool
    #endif

    @AppStorage(EPUBReaderPreferences.Keys.verticalWriting)
    private var verticalLayout: Bool = false
    // Typography sheet preferences. These supersede the legacy per-book
    // colour pickers — once the user picks a theme it drives fg/bg
    // directly. Font family / size / line-height / page-margin / justify
    // come from the Apple Books-style sheet.
    @AppStorage(EPUBReaderPreferences.Keys.fontFamily)
    private var typoFontFamilyRaw: String = ReaderTypographyPreferences.FontFamily.book.rawValue
    @AppStorage(EPUBReaderPreferences.Keys.fontSize)
    private var typoFontSize: Int = 17
    @AppStorage(EPUBReaderPreferences.Keys.lineHeight)
    private var typoLineHeight: Double = 1.55
    @AppStorage(EPUBReaderPreferences.Keys.pageMargin)
    private var typoPageMarginRaw: String = ReaderTypographyPreferences.PageMargin.defaultMargin.rawValue
    @AppStorage(EPUBReaderPreferences.Keys.theme)
    private var typoThemeRaw: String = EPUBReaderPreferences.Theme.original.rawValue
    @AppStorage(EPUBReaderPreferences.Keys.justify)
    private var typoJustify: Bool = true
    @AppStorage(EPUBReaderPreferences.Keys.twoPageLayout)
    private var twoPageLayout: Bool = true
    @AppStorage(EPUBReaderPreferences.Keys.orientationLocked)
    private var orientationLocked: Bool = false

    @State private var typographySheetVisible: Bool = false

    private var currentChapter: ReaderChapter? {
        guard chapterIndex >= 0, chapterIndex < book.chapters.count else { return nil }
        return book.chapters[chapterIndex]
    }

    private var typoTheme: EPUBReaderPreferences.Theme {
#if os(macOS)
        switch typoThemeRaw {
        case ReaderTypographyPreferences.Theme.sepia.rawValue: .calm
        case ReaderTypographyPreferences.Theme.dark.rawValue: .quiet
        default: .paper
        }
#else
        EPUBReaderPreferences.Theme(rawValue: typoThemeRaw) ?? .original
#endif
    }

    private var typoFontFamily: ReaderTypographyPreferences.FontFamily {
        ReaderTypographyPreferences.FontFamily(rawValue: typoFontFamilyRaw) ?? .system
    }

    private var typoPageMargin: ReaderTypographyPreferences.PageMargin {
        ReaderTypographyPreferences.PageMargin(rawValue: typoPageMarginRaw) ?? .defaultMargin
    }

    private var paginationLayoutSignature: String {
        [
            typoFontFamilyRaw,
            "\(typoFontSize)",
            "\(typoLineHeight)",
            typoPageMarginRaw,
            "\(typoJustify)",
            "\(twoPageLayout)",
            "\(verticalLayout)"
        ].joined(separator: "|")
    }

    private func styleTokens(pageColumns: Int, safeArea: EdgeInsets) -> EPUBReaderStyleTokens {
        let theme = typoTheme
        let bands = Self.pageBands(safeArea: safeArea)
        return EPUBReaderStyleTokens(
            foreground: theme.foregroundHex,
            background: theme.backgroundHex,
            theme: theme.rawValue,
            fontSizePx: typoFontSize,
            lineHeight: typoLineHeight,
            paddingPx: typoPageMargin.pixels,
            verticalMode: verticalLayout,
            // Empty stack means "use the book's own font", which is the default:
            // a book that embeds a serif face should keep it, exactly as Apple
            // Books does. Choosing a family in Reading Style overrides it.
            fontFamilyCSS: typoFontFamily.cssStack,
            pageMarginPx: typoPageMargin.pixels + 12,
            textAlign: typoJustify ? "justify" : "left",
            pressTintCSS: theme.pressTintCSS,
            // Text lives between the title row and the folio row, both of
            // which start at the safe area — never under the Dynamic Island or
            // the chrome that replaces those rows.
            insetTopPx: bands.insetTop,
            insetBottomPx: bands.insetBottom,
            headCenterPx: bands.headCenter,
            footCenterPx: bands.footCenter,
            pageColumns: pageColumns
        )
    }

    /// The page's three zones, the way Apple Books lays them out: a title row
    /// under the safe area, the text, and a folio row above the home
    /// indicator. The chrome's top bar and bottom bar sit on the same two
    /// centre lines, so showing it swaps what those rows say instead of
    /// covering the first and last lines of text.
    ///
    /// These used to be fixed 96 / 92 point insets from the *screen* edge,
    /// while the chrome was placed from the *safe area* edge — on a phone with
    /// a Dynamic Island the first line of every page sat under the top bar.
    static let titleRowCenter: CGFloat = 42
    static let titleBand: CGFloat = 88
    static let footRowCenter: CGFloat = 22
    static let footBand: CGFloat = 64
    /// The chrome's controls: one size for every round button in the reader.
    static let chromeControlSize: CGFloat = 44

    static func pageBands(safeArea: EdgeInsets) -> (insetTop: Int, insetBottom: Int, headCenter: Int, footCenter: Int) {
        #if os(iOS)
        let top = safeArea.top, bottom = safeArea.bottom
        #else
        // A Mac window has no safe area to clear.
        let top: CGFloat = 8, bottom: CGFloat = 8
        #endif
        return (
            Int((top + titleBand).rounded()),
            Int((bottom + footBand).rounded()),
            Int((top + titleRowCenter).rounded()),
            Int((bottom + footRowCenter).rounded())
        )
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            backgroundColor.ignoresSafeArea()
            pagerLayer
            endOfBookToast
        }
        #if os(macOS)
        // On iOS the running head and page number are drawn on each page
        // card, so they curl with the page; the Mac reader draws them here.
        .overlay(alignment: .top) { pageTitleRow }
        .overlay(alignment: .bottom) { pageFolioRow }
        #endif
        .overlay(alignment: .top) { topChrome }
        .overlay(alignment: .bottom) { bottomChromeBar }
        .overlay(alignment: .bottom) { cardLayer }
        .overlay(alignment: .bottomTrailing) { assistantButton }
        .overlay(alignment: .bottomTrailing) { compactMenu }
        .navigationBarBackButtonHidden(true)
        #if os(iOS)
        .toolbarVisibility(.hidden, for: .navigationBar)
        .toolbarVisibility(.hidden, for: .tabBar)
        #endif
        .preference(key: AssistantScreenContextKey.self, value: assistantContext)
        .task {
            prepareAnnotations()
            prepareCardCapture()
            await cards.attach(book: book, annotations: annotations)
            await model.preloadChapterContents(for: book)
        }
        // A tapped capture's menu, over everything, at the capture.
        .overlay { ReaderMarkMenuLayer(session: cards) }
        .animation(AmgiMotion.standard, value: cards.markMenu?.id)
        .task(id: chapterIndex) {
            await annotations.load(bookID: book.id)
            await prepareRestoreIfNeeded()
            await loadCurrentChapterMarks()
        }
        .sheet(isPresented: $typographySheetVisible) {
#if os(iOS)
            EPUBReadingStylePanel()
#else
            ReaderStyleSheet(isPDF: false)
#endif
        }
        .sheet(isPresented: $contentsSheetVisible) {
            epubContentsSheet
                // Full height from the start, so rows do not move under the
                // finger as the sheet grows from half height.
                .presentationDetents([.large])
        }
        .sheet(isPresented: $annotationsSheetVisible) {
            ReaderAnnotationsSheet(
                book: book,
                model: annotations,
                drafts: cards.drafts.drafts,
                onJump: { annotation in
                    annotationsSheetVisible = false
                    jump(to: annotation)
                },
                onResumeDraft: { draft in
                    annotationsSheetVisible = false
                    Task { await cards.drafts.bringToFront(draft.id) }
                    if let anchor = draft.frontClips.first?.anchor ?? draft.backClips.first?.anchor {
                        navigate(to: anchor)
                    }
                },
                onDiscardDraft: { draft in
                    Task { await cards.discard(draft.id) }
                }
            )
        }
        .sheet(item: editingDraftSheet) { item in
            ReaderCardDraftSheet(draftID: item.id, session: cards, onGoTo: { anchor in
                navigate(to: anchor)
            })
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
        .sheet(isPresented: $searchSheetVisible) {
            EPUBBookSearchPanel(
                bookTitle: book.title,
                model: searchModel,
                onSearch: { query in
                    await searchModel.search(query, in: book, contents: model.chapterContents)
                },
                onSelect: { hit in
                    searchSheetVisible = false
                    navigate(to: hit.anchor)
                }
            )
        }
        .alert("Go to Page", isPresented: $pageJumpVisible) {
            TextField("Page number", text: $pageJumpInput)
#if os(iOS)
                .keyboardType(.numberPad)
#endif
            Button("Go") {
                if let target = Int(pageJumpInput) { seekToBookPage(target) }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Enter a page from 1 to \(estimatedBookPageCount).")
        }
        .sheet(isPresented: lookupSheetPresented) {
            lookupPopupContent
        }
        .popover(isPresented: lookupPopoverPresented, arrowEdge: .top) {
            lookupPopupContent
                .frame(minWidth: 380, idealWidth: 420, maxWidth: 460, minHeight: 420, idealHeight: 560)
        }
        #if os(iOS)
        .focusable()
        .focused($keyboardFocused)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow, phases: .down) { press in
            handlePageKey(.backward, press: press)
        }
        .onKeyPress(.upArrow, phases: .down) { press in
            handlePageKey(.backward, press: press)
        }
        .onKeyPress(.pageUp, phases: .down) { press in
            handlePageKey(.backward, press: press)
        }
        .onKeyPress(.rightArrow, phases: .down) { press in
            handlePageKey(.forward, press: press)
        }
        .onKeyPress(.downArrow, phases: .down) { press in
            handlePageKey(.forward, press: press)
        }
        .onKeyPress(.pageDown, phases: .down) { press in
            handlePageKey(.forward, press: press)
        }
        .onKeyPress(.space, phases: .down) { press in
            handlePageKey(.forward, press: press)
        }
        #endif
        .sensoryFeedback(trigger: endOfBookToastVisible) { _, visible in
            visible ? .success : nil
        }
        .onAppear {
            #if os(iOS)
            keyboardFocused = true
            EPUBOrientationLock.setLocked(orientationLocked)
            #endif
            // Start the running total from scratch: page counts are a
            // property of this rendering, so entering the reader with
            // different typography starts a new count.
            if pagination.chapterCount != book.chapters.count {
                pagination = ReaderPaginationIndex(chapterCount: book.chapters.count)
            }
            ReaderTelemetry.beginSession([
                "book": book.title, "chapters": book.chapters.count, "chapter": chapterIndex,
                "transition": pageTransition.rawValue,
            ])
        }
        .onDisappear {
            // Leaving the book saves the cards that are ready.
            Task { [cards] in await cards.saveReadyDrafts() }
            endOfBookToastDismiss?.cancel()
            progressSaveDebounce?.cancel()
            flushProgress()
            #if os(iOS)
            orientationLocked = false
            EPUBOrientationLock.restoreAppOrientation()
            #endif
        }
        .onChange(of: paginationLayoutSignature) { _, _ in
            pagination = ReaderPaginationIndex(chapterCount: book.chapters.count)
            restoreCachedPagination(size: pagerSize)
        }
    }

    // MARK: - Subviews

    private var backgroundColor: Color {
        typoTheme.backgroundColor
    }

    @ViewBuilder
    private var pagerLayer: some View {
        if !model.chapterContents.isEmpty {
            GeometryReader { proxy in
                let layout = ReaderPageLayout.resolve(
                    availableSize: proxy.size,
                    allowsTwoPageLayout: twoPageLayout && !verticalLayout && proxy.size.width >= 700
                )
                EPUBPageViewControllerHost(
                    book: book,
                    chapterContents: model.chapterContents,
                    chapterIndex: $chapterIndex,
                    styleTokens: styleTokens(pageColumns: layout.columnCount, safeArea: proxy.safeAreaInsets),
                    pendingRestoreFraction: pendingRestoreFraction,
                    pageTurnRequest: pageTurnRequest,
                    navigationRequestID: navigationRequestID,
                    selectionRequestID: selectionRequestID,
                    pagingEnabled: lookupRequest == nil,
                    onPageInfo: { idx, count in
                        recordReadingPosition(chapter: chapterIndex, page: idx)
                        // Only a first count goes into the book's pagination:
                        // the background measurement owns it after that. A
                        // live page re-lays out as fonts and images arrive,
                        // and letting those reports through moved the book's
                        // total (1052 → 1053) while reading.
                        if !pagination.isMeasured(chapterIndex) {
                            var updated = pagination
                            updated.record(chapter: chapterIndex, pageCount: count)
                            pagination = updated
                        }
                        pageIndex = idx
                        pageCount = max(count, 1)
                        pendingRestoreFraction = nil
                        captureViewportAnchor(chapter: chapterIndex, page: idx)
                        announcePageChangeIfNeeded()
                    },
                    onProgress: { fraction, idx in
                        recordReadingPosition(chapter: chapterIndex, page: idx)
                        pageIndex = idx
                        progressFraction = fraction
                        saveProgress()
                    },
                    onWordTap: { token, sentence, anchor in
                        lookupRequest = LookupRequest(
                            token: token,
                            sentence: sentence,
                            anchor: anchor
                        )
                    },
                    onSelectionForNote: { text in
                        lookupRequest = LookupRequest(
                            token: text,
                            sentence: text,
                            // A native selection has no DOM anchor behind
                            // it: the range is collapsed before we are called.
                            // The quote alone is still a usable fallback.
                            anchor: nil
                        )
                    },
                    onTapEmpty: { _ in toggleChrome() },
                    onReachedEnd: { showEndOfBookToast() },
                    onPageTurnAnimation: { active in
                        withAnimation(.easeOut(duration: 0.16)) {
                            pageTurnAnimationActive = active
                        }
                    },
                    onSelectionMark: handleSelectionMark,
                    pageTransition: pageTransition,
                    paginationIndex: pagination,
                    runningHead: book.title,
                    chromeVisible: chromeVisible && !pageTurnAnimationActive,
                    onChapterMeasured: { chapter, count in
                        var updated = pagination
                        updated.record(chapter: chapter, pageCount: count)
                        pagination = updated
                        savePaginationIfComplete(size: proxy.size)
                    },
                    commands: pageCommands
                )
                // The transition style is fixed when the page controller is
                // built, so changing it has to rebuild rather than mutate.
                .id(pageTransition)
                .onChange(of: proxy.size, initial: true) { _, size in
                    pagerSize = size
                    pagination = ReaderPaginationIndex(chapterCount: book.chapters.count)
                    restoreCachedPagination(size: size)
                }
                .ignoresSafeArea()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // VoiceOver has no gesture for "turn the page" in a paginated
                // reader — the web view's scroll view is the only thing it
                // knows how to swipe. Expose the same turn the keyboard and
                // the edge taps already perform as an explicit action, so the
                // reader is operable without sighted input.
                .accessibilityElement(children: .contain)
                .accessibilityLabel(book.title)
                .accessibilityValue(
                    ReaderPageAccessibility.pageLabel(
                        pageIndex: pageIndex,
                        pageCount: pageCount
                    )
                )
                .accessibilityAction(named: "Next page") {
                    requestPageTurn(.forward)
                }
                .accessibilityAction(named: "Previous page") {
                    requestPageTurn(.backward)
                }
                #if os(iOS)
                .overlay {
                    if captureMode == .area {
                        areaCaptureOverlay()
                            .ignoresSafeArea()
                            .transition(.opacity)
                    }
                }
                #endif
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Pages left in the chapter as the book's table of contents defines it.
    /// A spine document the contents does not name (a title page, a copyright
    /// page) belongs to the entry before it, so the cover and the front
    /// matter are not one 78-page "chapter", and a chapter split across files
    /// counts all of them.
    private var pagesLeftInChapter: Int {
        let inThisFile = max(0, pageCount - 1 - pageIndex)
        var later = 0
        var index = chapterIndex + 1
        while book.chapters.indices.contains(index), !book.chapters[index].isTableOfContentsEntry {
            later += max(1, pagination.pageCounts[index] ?? book.chapters[index].pageCount ?? 1)
            index += 1
        }
        return inThisFile + later
    }

    /// Every chapter has been measured at this layout, so book-wide page
    /// numbers are exact and will not move.
    private var isPaginationComplete: Bool {
        pagination.chapterCount == book.chapters.count && pagination.unmeasured.isEmpty
    }

    /// What the bottom bar says. A book-wide "X of Y" only once it is exact —
    /// a total that grows while you read (664, 684, 697…) reads as a bug —
    /// and the page within the chapter until then.
    private var pagePositionText: String {
        isPaginationComplete
            ? "\(bookPageNumber) of \(estimatedBookPageCount)"
            : "\(pageIndex + 1) of \(max(pageCount, 1)) in chapter"
    }

    // MARK: - Pagination cache
    //
    // Measuring a whole book takes a while, so the counts are kept per book
    // and per layout: reopening the book with the same typography on the same
    // screen has its page numbers at once.

    private var paginationCacheKey: String {
        "epub.pagination.v1.\(book.id)"
    }

    private func paginationLayoutKey(size: CGSize) -> String {
        "\(paginationLayoutSignature)|\(Int(size.width))x\(Int(size.height))"
    }

    private func restoreCachedPagination(size: CGSize) {
        guard let stored = UserDefaults.standard.dictionary(forKey: paginationCacheKey),
              stored["layout"] as? String == paginationLayoutKey(size: size),
              let counts = stored["counts"] as? [Int], counts.count == book.chapters.count else { return }
        var restored = ReaderPaginationIndex(chapterCount: book.chapters.count)
        for (index, count) in counts.enumerated() { restored.record(chapter: index, pageCount: count) }
        pagination = restored
    }

    private func savePaginationIfComplete(size: CGSize) {
        guard isPaginationComplete else { return }
        let counts = book.chapters.indices.map { pagination.pageCounts[$0] ?? 1 }
        UserDefaults.standard.set(
            ["layout": paginationLayoutKey(size: size), "counts": counts],
            forKey: paginationCacheKey
        )
    }

    @State private var pagerSize: CGSize = .zero

    /// Speak the new page after a turn.
    ///
    /// Both platform hosts converge on `onPageInfo`, so one announcement path
    /// covers iOS VoiceOver and macOS VoiceOver without touching either host.
    /// The guard drops the first report and repeat indices, which is what an
    /// edge-of-chapter bounce or a restore produces.
    private func announcePageChangeIfNeeded() {
        guard ReaderPageAccessibility.shouldAnnounce(
            previous: lastAnnouncedPageIndex,
            current: pageIndex,
            pageCount: pageCount
        ) else { return }
        lastAnnouncedPageIndex = pageIndex
        #if os(iOS)
        UIAccessibility.post(
            notification: .pageScrolled,
            argument: ReaderPageAccessibility.pageTurnAnnouncement(
                pageIndex: pageIndex,
                pageCount: pageCount
            )
        )
        #endif
    }

    private var pagesLeftText: String {
        let remaining = pagesLeftInChapter
        if remaining == 0 { return "Last page of chapter" }
        if remaining == 1 { return "1 page left in chapter" }
        return "\(remaining) pages left in chapter"
    }

    private func recordReadingPosition(chapter: Int, page: Int) {
        let next = ReaderReadingPosition(chapterIndex: chapter, pageIndex: page)
        if skipNextHistoryRecord {
            skipNextHistoryRecord = false
            previousPosition = next
            return
        }
        // History is for jumps — contents, search, a link, a page jump — so
        // "back" returns to where the reader leapt from. A page turn is not a
        // jump; recording every one grew the counter on every turn.
        if let lastPosition = previousPosition, lastPosition != next,
           !next.isTurn(from: lastPosition, pageCountOf: { pagination.pageCounts[$0] }) {
            if readingHistory.last != lastPosition {
                readingHistory.append(lastPosition)
                if readingHistory.count > 20 { readingHistory.removeFirst(readingHistory.count - 20) }
            }
        }
        previousPosition = next
    }

    private func captureViewportAnchor(chapter: Int, page: Int) {
        let position = ReaderReadingPosition(chapterIndex: chapter, pageIndex: page)
        guard anchorCapturePosition != position else { return }
        anchorCapturePosition = position
        pageCommands.requestAnchor { anchor in
            guard previousPosition == position else { return }
            currentViewportAnchor = anchor
        }
    }

    private func returnToPreviousPosition() {
        guard let position = readingHistory.popLast() else { return }
        skipNextHistoryRecord = true
        navigate(to: position)
    }

    private func navigate(to position: ReaderReadingPosition) {
        guard book.chapters.indices.contains(position.chapterIndex) else { return }
        ReaderTelemetry.log("view.navigate.position", ["chapter": position.chapterIndex, "page": position.pageIndex, "from": chapterIndex])
        if position.chapterIndex == chapterIndex {
            pageCommands.pageIndexRequest = position.pageIndex
            navigationRequestID &+= 1
        } else {
            skipNextHistoryRecord = true
            let estimatedCount = max(1, pagination.pageCounts[position.chapterIndex]
                ?? book.chapters[position.chapterIndex].pageCount ?? 1)
            pendingRestoreFraction = estimatedCount <= 1
                ? 0
                : Double(position.pageIndex) / Double(estimatedCount - 1)
            // The bar describes the chapter being opened from the start, not
            // the one being left ("90 pages left" over chapter 1's first page).
            pageIndex = position.pageIndex
            pageCount = estimatedCount
            chapterIndex = position.chapterIndex
        }
    }

    private func navigate(to anchor: ReaderSourceAnchor) {
        guard let chapterID = anchor.chapterID,
              let index = book.chapters.firstIndex(where: { $0.id == chapterID }) else { return }
        pageCommands.navigationAnchor = anchor
        ReaderTelemetry.log("view.navigate.anchor", ["chapter": index, "from": chapterIndex])
        if index != chapterIndex {
            chapterIndex = index
        } else {
            navigationRequestID &+= 1
        }
    }

    /// The EPUB title and printed page number are injected into the document,
    /// so UIKit curls them with the text. This fixed top row matches the
    /// compact iPhone and iPad controls in the reference.
    @ViewBuilder
    private var topChrome: some View {
        if chromeVisible && !pageTurnAnimationActive {
            HStack(spacing: 12) {
                Button(action: returnToPreviousPosition) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.uturn.backward.circle.fill")
                            .font(.system(size: 17, weight: .semibold))
                        Text(readingHistory.count, format: .number)
                            .font(.system(size: 15, weight: .medium, design: .rounded).monospacedDigit())
                    }
                    .foregroundStyle(palette.textPrimary)
                    .padding(.horizontal, 12)
                    .frame(height: Self.chromeControlSize)
                    .amgiMaterial(.regular, in: Capsule(), interactive: true)
                    .amgiMaterialElevation(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(readingHistory.isEmpty)
                .accessibilityLabel("Back through reading history, \(readingHistory.count) saved positions")

                Spacer(minLength: 4)
                Text(pagesLeftText)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(palette.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .accessibilityAddTraits(.updatesFrequently)
                Spacer(minLength: 4)

                Button(action: closeReader) {
                    Image(systemName: "xmark")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(palette.textSecondary)
                        .frame(width: Self.chromeControlSize, height: Self.chromeControlSize)
                        .amgiMaterial(.regular, in: Circle(), interactive: true)
                        .amgiMaterialElevation(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close book")
            }
            .padding(.horizontal, 16)
            // Centred on the page's title row, which it replaces while shown.
            .padding(.top, Self.titleRowCenter - Self.chromeControlSize / 2)
            .transition(ReaderChromeSwap.transition)
        }
    }

    /// The page's running head: the book title, quiet and centred on the
    /// title row, as Apple Books prints it. Drawn here rather than in the
    /// page so the top bar can replace it on the same line without the two
    /// ever overlapping.
    @ViewBuilder
    private var pageTitleRow: some View {
        if !chromeVisible || pageTurnAnimationActive {
            Text(book.title)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(palette.textSecondary.opacity(0.85))
                .lineLimit(1)
                .padding(.horizontal, 64)
                .frame(height: Self.chromeControlSize)
                .padding(.top, Self.titleRowCenter - Self.chromeControlSize / 2)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .transition(ReaderChromeSwap.transition)
        }
    }

    /// The page number alone, on the folio row, while the bar that says
    /// "X of Y" is away.
    @ViewBuilder
    private var pageFolioRow: some View {
        if (!chromeVisible || pageTurnAnimationActive) && cards.drafts.drafts.isEmpty {
            Text(isPaginationComplete ? "\(bookPageNumber)" : "\(pageIndex + 1)")
                .font(.system(size: 13, weight: .regular).monospacedDigit())
                .foregroundStyle(palette.textSecondary.opacity(0.85))
                .frame(height: Self.chromeControlSize)
                .padding(.bottom, Self.footRowCenter - Self.chromeControlSize / 2)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .transition(ReaderChromeSwap.transition)
        }
    }

    #if os(iOS)
    /// Boxes drawn over the page become pictures on cards. The page host
    /// captures the box from the page as it is on screen.
    private func areaCaptureOverlay() -> some View {
        ReaderAreaCaptureOverlay(
            colour: cards.captureColour,
            targetTitle: cards.drafts.frontmost?.shortTitle,
            onAction: { action, rect in
                Task {
                    guard let capture = await pageCommands.regionCapture?(rect) else {
                        cards.showToast(.init(message: "Couldn’t capture that area", systemImage: "exclamationmark.triangle"))
                        return
                    }
                    await cards.handleRegion(cards.command(for: action), capture: capture)
                }
            },
            onTap: { toggleChrome() }
        )
    }
    #endif

    @ViewBuilder
    private var bottomChromeBar: some View {
        if chromeVisible && !pageTurnAnimationActive {
            HStack(alignment: .center) {
                #if os(iOS)
                ReaderCaptureModeButton(
                    mode: $captureMode,
                    colour: cards.captureColour,
                    onColour: { cards.setCaptureColour($0) },
                    size: Self.chromeControlSize
                )
                #endif
                Spacer(minLength: 0)
                // A docked draft takes this spot; the page also prints its
                // own number, so nothing is lost while a card is waiting.
                if cards.drafts.drafts.isEmpty {
                    Text(pagePositionText)
                        .font(.system(size: 14, weight: .medium).monospacedDigit())
                        .foregroundStyle(palette.textSecondary)
                        .contentTransition(.numericText())
                        .accessibilityLabel(isPaginationComplete
                            ? "Page \(bookPageNumber) of \(estimatedBookPageCount)"
                            : "Page \(pageIndex + 1) of \(max(pageCount, 1)) in this chapter")
                }
                Spacer(minLength: 0)
                menuButton
            }
            .padding(.horizontal, 16)
            // Centred on the folio row, which it replaces while shown.
            .padding(.bottom, Self.footRowCenter - Self.chromeControlSize / 2)
            .transition(ReaderChromeSwap.transition)
        }
    }

    private var menuButton: some View {
        Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                compactMenuVisible.toggle()
            }
        } label: {
            Image(systemName: compactMenuVisible ? "xmark" : "list.bullet")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(palette.textPrimary)
                .frame(width: Self.chromeControlSize, height: Self.chromeControlSize)
                .amgiMaterial(.regular, in: Circle(), interactive: true)
                .amgiMaterialElevation(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(compactMenuVisible ? "Close reader menu" : "Open reader menu")
    }

    /// The chapter on screen, and the passage selected in it if any.
    private var assistantContext: [AssistantContext] {
        var contexts: [AssistantContext] = []
        if let passage = AssistantContext.passage(pageCommands.lastSelection?.text, bookID: book.id, bookTitle: book.title) {
            contexts.append(passage)
        }
        if let chapter = currentChapter {
            contexts.append(.chapter(bookID: book.id, bookTitle: book.title, chapterID: chapter.id, title: chapter.title, text: chapter.content))
        } else {
            contexts.append(.book(id: book.id, title: book.title))
        }
        return contexts
    }

    /// Ask AI, stacked directly over the menu button in the trailing column
    /// the card dock and toast already leave free while the chrome is up.
    /// Goes with the chrome, and steps aside for the open menu, which rises
    /// from the same spot.
    @ViewBuilder
    private var assistantButton: some View {
        if chromeVisible && !pageTurnAnimationActive && !compactMenuVisible {
            ReaderAssistantButton(context: { assistantContext }, size: Self.chromeControlSize)
                .padding(.trailing, 16)
                .padding(.bottom, Self.footRowCenter + Self.chromeControlSize / 2 + 12)
                .transition(ReaderChromeSwap.transition)
        }
    }

    @ViewBuilder
    private var compactMenu: some View {
        if chromeVisible && !pageTurnAnimationActive && compactMenuVisible {
            VStack(spacing: 7) {
                compactMenuRow("Contents · \(readingProgressPercent)%", systemImage: "list.bullet") {
                    compactMenuVisible = false
                    // After the menu has gone, so the tap that chose Contents
                    // is over before the list arrives.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { contentsSheetVisible = true }
                }
                if !cards.drafts.drafts.isEmpty {
                    compactMenuRow(
                        cards.drafts.drafts.count == 1 ? "1 Unfinished Card" : "\(cards.drafts.drafts.count) Unfinished Cards",
                        systemImage: "rectangle.stack"
                    ) {
                        compactMenuVisible = false
                        annotationsSheetVisible = true
                    }
                }
                compactMenuRow("Search Book", systemImage: "magnifyingglass") {
                    compactMenuVisible = false
                    searchSheetVisible = true
                }
                compactMenuRow("Themes & Settings", systemImage: "textformat.size") {
                    compactMenuVisible = false
                    typographySheetVisible = true
                }
                HStack(spacing: 8) {
                    if let epubURL {
                        ShareLink(item: epubURL) {
                            compactMenuIcon("square.and.arrow.up", title: "Share Book")
                        }
                        .buttonStyle(.plain)
                    }
                    Button {
                        orientationLocked.toggle()
                        #if os(iOS)
                        EPUBOrientationLock.setLocked(orientationLocked)
                        #endif
                    } label: {
                        compactMenuIcon(orientationLocked ? "lock.rotation" : "lock.rotation.open", title: "Lock Rotation")
                    }
                    .buttonStyle(.plain)
                    Button {
                        compactMenuVisible = false
                        annotationsSheetVisible = true
                    } label: {
                        compactMenuIcon("text.alignleft", title: "Highlights and Notes")
                    }
                    .buttonStyle(.plain)
                    Button {
                        compactMenuVisible = false
                        toggleBookmark()
                    } label: {
                        compactMenuIcon(isCurrentPageBookmarked ? "bookmark.fill" : "bookmark", title: "Bookmark Page")
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 2)
            }
            .frame(maxWidth: 340)
            .padding(8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).strokeBorder(.white.opacity(0.24)))
            .shadow(color: .black.opacity(0.15), radius: 24, y: 10)
            .padding(.trailing, 16)
            .padding(.bottom, Self.footRowCenter + Self.chromeControlSize / 2 + 10)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// The draft dock and the capture toast, floating over the page. The dock
    /// stays through page turns and chrome toggles: the card it holds is
    /// waiting for something further on in the book.
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
                onGoTo: { navigate(to: $0) },
                onBringToFront: { id in Task { await cards.drafts.bringToFront(id) } },
                onDrop: { text, id in
                    Task { await cards.drop(text, on: id, selection: pageCommands.lastSelection) }
                },
                onRecolour: { id, colour in Task { await cards.setColour(colour, forDraft: id) } },
                imageURL: { cards.drafts.imageURL($0) }
            )
        }
        .frame(maxWidth: .infinity)
        .padding(.leading, 16)
        // Leaves the reader menu button its corner whenever it is showing.
        .padding(.trailing, chromeVisible ? 16 + Self.chromeControlSize + 12 : 16)
        // In the folio row, clear of the text above it.
        .padding(.bottom, 2)
        .animation(AmgiMotion.momentum, value: cards.drafts.drafts.map(\.id))
        .animation(AmgiMotion.standard, value: cards.toast)
    }

    private var editingDraftSheet: Binding<DraftSheetItem?> {
        Binding(
            get: { cards.editingDraftID.map(DraftSheetItem.init) },
            set: { cards.editingDraftID = $0?.id }
        )
    }

    private func compactMenuRow(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Text(title)
                    .font(.system(size: 17, weight: .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                Image(systemName: systemImage)
                    .font(.system(size: 20, weight: .medium))
                    .frame(width: 30)
            }
            .foregroundStyle(palette.textPrimary)
            .padding(.horizontal, 16)
            .frame(height: 53)
            .background(.regularMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func compactMenuIcon(_ systemImage: String, title: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 21, weight: .medium))
            .foregroundStyle(palette.textPrimary)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(.regularMaterial, in: Capsule())
            .accessibilityLabel(title)
    }

    private var epubURL: URL? {
        guard case let .epub(localURL) = book.source else { return nil }
        return localURL
    }

    private var readingProgressPercent: Int {
        guard estimatedBookPageCount > 0 else { return 0 }
        return min(100, max(0, Int((Double(bookPageNumber) / Double(estimatedBookPageCount) * 100).rounded())))
    }

    private var estimatedBookPageCount: Int {
        book.chapters.enumerated().reduce(0) { total, entry in
            let (index, chapter) = entry
            return total + (pagination.pageCounts[index] ?? chapter.pageCount ?? 1)
        }
    }

    private var isCurrentPageBookmarked: Bool {
        guard let anchor = currentViewportAnchor else { return false }
        return annotations.bookmarks.contains { bookmark in
            bookmark.anchor.chapterID == anchor.chapterID
                && bookmark.anchor.cfi == anchor.cfi
                && bookmark.anchor.path == anchor.path
                && ReaderSourceAnchor.normalize(bookmark.anchor.quote) == ReaderSourceAnchor.normalize(anchor.quote)
        }
    }

    private func toggleBookmark() {
        guard let currentChapter else { return }
        pageCommands.requestAnchor { captured in
            let anchor = captured ?? currentViewportAnchor ?? ReaderSourceAnchor(
                bookID: book.id,
                chapterID: currentChapter.id,
                quote: currentChapter.title
            )
            if let existing = annotations.bookmarks.first(where: { bookmark in
                bookmark.anchor.chapterID == anchor.chapterID
                    && bookmark.anchor.cfi == anchor.cfi
                    && bookmark.anchor.path == anchor.path
                    && ReaderSourceAnchor.normalize(bookmark.anchor.quote) == ReaderSourceAnchor.normalize(anchor.quote)
            }) {
                Task {
                    await annotations.delete(existing)
                    refreshPaintedMarks()
                }
            } else {
            Task {
                await annotations.addBookmark(
                    in: book.id,
                    anchor: anchor,
                    excerpt: anchor.quote.isEmpty ? currentChapter.title : anchor.quote
                )
                refreshPaintedMarks()
            }
            }
        }
    }

    private func seekToBookPage(_ targetPage: Int) {
        var remaining = min(max(targetPage, 1), estimatedBookPageCount) - 1
        for index in book.chapters.indices {
            let count = max(1, pagination.pageCounts[index] ?? book.chapters[index].pageCount ?? 1)
            if remaining < count {
                navigate(to: ReaderReadingPosition(chapterIndex: index, pageIndex: remaining))
                return
            }
            remaining -= count
        }
    }

    private var epubContentsSheet: some View {
        let outlineItems: [ReaderContentsSheet.OutlineItem] = book.chapters.enumerated().map { idx, chapter in
            let startPage = book.chapters.prefix(idx).enumerated().reduce(0) { total, entry in
                total + (pagination.pageCounts[entry.offset] ?? entry.element.pageCount ?? 1)
            } + 1
            return ReaderContentsSheet.OutlineItem(
                id: "\(chapter.id)",
                title: chapter.title,
                pageIndex: idx,
                pageLabel: "\(startPage)",
                depth: 0,
                isCurrent: idx == chapterIndex
            )
        }

        let bookmarkItems: [ReaderContentsSheet.BookmarkItem] = annotations.bookmarks.map { bm in
            let chap = book.chapters.first(where: { $0.id == bm.anchor.chapterID })
            let chapterNumber = chap.flatMap { chapter in
                book.chapters.firstIndex(where: { $0.id == chapter.id }).map { $0 + 1 }
            } ?? 0
            return ReaderContentsSheet.BookmarkItem(
                id: bm.id.uuidString,
                pageIndex: max(0, chapterNumber - 1),
                pageLabel: chapterNumber == 0 ? "" : "Ch. \(chapterNumber)",
                title: bm.excerpt,
                subtitle: chap?.title,
                date: bm.createdAt
            )
        }

        // Highlights and captures together, in reading order: chapter, then
        // place in the chapter.
        func chapterNumber(_ anchor: ReaderSourceAnchor?) -> Int? {
            anchor?.chapterID.flatMap { id in book.chapters.firstIndex(where: { $0.id == id }) }
        }
        func order(_ anchor: ReaderSourceAnchor?) -> (Int, Int) {
            (chapterNumber(anchor) ?? Int.max, anchor?.cfi ?? 0)
        }
        let captures = cards.captureListings()
        var placed: [(key: (Int, Int), item: ReaderContentsSheet.NoteItem)] = annotations.highlights.map { hl in
            (order(hl.anchor), ReaderContentsSheet.NoteItem(
                id: hl.id.uuidString,
                pageIndex: 0,
                pageLabel: chapterNumber(hl.anchor).map { "Ch. \($0 + 1)" } ?? "",
                quote: hl.excerpt,
                note: hl.note,
                colorHex: hl.colorHex ?? PDFAnnotationColour.yellow.hex
            ))
        }
        placed += captures.map { capture in
            (order(capture.anchor), ReaderContentsSheet.NoteItem(
                id: capture.id,
                pageIndex: 0,
                pageLabel: chapterNumber(capture.anchor).map { "Ch. \($0 + 1)" } ?? "",
                quote: capture.quote,
                colorHex: capture.colorHex,
                kind: capture.kind == .card ? .card : .draft,
                secondary: capture.secondary,
                images: capture.images
            ))
        }
        let noteItems = placed.sorted { $0.key < $1.key }.map(\.item)

        return ReaderContentsSheet(
            bookTitle: book.title,
            outlineItems: outlineItems,
            bookmarks: bookmarkItems,
            notes: noteItems,
            contentsTabTitle: "Chapters",
            notesTabTitle: "Highlights",
            headerSubtitle: "Page \(bookPageNumber) of \(estimatedBookPageCount)",
            onHeaderSubtitleTap: {
                pageJumpInput = "\(bookPageNumber)"
                pageJumpVisible = true
            },
            doneUsesCheckmark: true,
            onSelectOutline: { item in
                navigate(to: ReaderReadingPosition(chapterIndex: item.pageIndex, pageIndex: 0))
            },
            onSelectBookmark: { item in
                if let bm = annotations.bookmarks.first(where: { $0.id.uuidString == item.id }) {
                    jump(to: bm)
                }
            },
            onDeleteBookmark: { item in
                if let uuid = UUID(uuidString: item.id),
                   let existing = annotations.bookmarks.first(where: { $0.id == uuid }) {
                    Task { await annotations.delete(existing) }
                }
            },
            onSelectNote: { item in
                if let hl = annotations.highlights.first(where: { $0.id.uuidString == item.id }) {
                    jump(to: hl)
                } else if let anchor = captures.first(where: { $0.id == item.id })?.anchor {
                    navigate(to: anchor)
                }
            },
            noteActions: listActions
        )
    }

    /// What the highlights list can do to a mark: highlights through the
    /// annotation model, captures through the card session — the same calls
    /// the page's mark menu makes.
    private var listActions: ReaderContentsSheet.NoteActions {
        func highlight(_ item: ReaderContentsSheet.NoteItem) -> ReaderAnnotation? {
            annotations.highlights.first { $0.id.uuidString == item.id }
        }
        return ReaderContentsSheet.NoteActions(
            edit: { item in
                guard let menu = cards.menu(forListing: item.id) else { return }
                // After the list has gone, so the editor has the screen.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                    Task { await cards.openMarkTarget(menu) }
                }
            },
            setNote: { item, text in
                guard let hl = highlight(item) else { return }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                Task { await annotations.updateNote(hl, note: trimmed.isEmpty ? nil : trimmed) }
            },
            remove: { item in
                if let hl = highlight(item) {
                    Task {
                        await annotations.delete(hl)
                        refreshPaintedMarks()
                    }
                } else if let menu = cards.menu(forListing: item.id) {
                    Task { await cards.removeMark(menu) }
                }
            },
            deleteCard: { item in
                guard let menu = cards.menu(forListing: item.id) else { return }
                Task { await cards.deleteCard(menu) }
            },
            recolour: { item, colour in
                if let hl = highlight(item) {
                    Task {
                        await annotations.setColour(colour.hex, ids: [hl.id], inBook: book.id)
                        refreshPaintedMarks()
                    }
                } else if let menu = cards.menu(forListing: item.id) {
                    Task { await cards.recolourMark(menu, to: colour) }
                }
            },
            canRecolour: { _ in true }
        )
    }

    /// Bookmark / highlight / list, in one menu.
    ///
    /// Grouped rather than three separate pills: the bottom bar already has a
    /// leading action and a trailing menu, and a third standalone pill would
    /// break the page counter's centring. The menu label states the current
    /// mark count so the list is discoverable without opening it.
    @ViewBuilder
    private var annotationsCapsule: some View {
        Menu {
            Button {
                addMark(kind: .bookmark)
            } label: {
                Label("Bookmark This Page", systemImage: "bookmark")
            }
            Button {
                addMark(kind: .highlight)
            } label: {
                Label("Highlight This Page", systemImage: "highlighter")
            }
            Divider()
            Button {
                annotationsSheetVisible = true
            } label: {
                Label(
                    "Highlights & Bookmarks",
                    systemImage: "list.bullet.rectangle"
                )
            }
        } label: {
            Image(systemName: annotationCount > 0 ? "highlighter" : "list.bullet.rectangle")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(palette.textPrimary)
                .frame(width: 44, height: 44)
                .amgiMaterial(.regular, in: Circle(), interactive: true)
                .amgiMaterialElevation(Circle())
                .overlay(alignment: .topTrailing) {
                    if annotationCount > 0 {
                        Text(annotationCount, format: .number)
                            .amgiFont(.micro)
                            .foregroundStyle(palette.textPrimary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(palette.accent))
                            .offset(x: 12, y: -10)
                            .accessibilityHidden(true)
                    }
                }
        }
        .accessibilityLabel("Annotations")
        .accessibilityValue(
            annotationCount > 0
                ? "\(annotationCount) saved"
                : "None saved"
        )
        .opacity(chromeVisible ? 1 : 0)
        .allowsHitTesting(chromeVisible)
    }

    private var annotationCount: Int {
        annotations.highlights.count + annotations.bookmarks.count
    }

    @ViewBuilder
    private var endOfBookToast: some View {
        if endOfBookToastVisible {
            Button(action: dismissEndOfBookToast) {
                Text("End of book")
                    .amgiFont(.captionBold)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .amgiMaterial(.light, in: Capsule())
            }
            .buttonStyle(.pressScale)
            .accessibilityHint("Dismisses this message")
            .padding(.bottom, 80)
            .transition(AmgiMotion.slide(from: .bottom))
        }
    }

}

private extension EPUBChapterReaderView {
    // MARK: - Presentation and input

    private var usesLookupInspector: Bool {
        horizontalSizeClass != .compact
    }

    private var lookupSheetPresented: Binding<Bool> {
        Binding(
            get: { !usesLookupInspector && lookupRequest != nil },
            set: { if !$0 { lookupRequest = nil } }
        )
    }

    private var lookupPopoverPresented: Binding<Bool> {
        Binding(
            get: { usesLookupInspector && lookupRequest != nil },
            set: { if !$0 { lookupRequest = nil } }
        )
    }

    @ViewBuilder
    private var lookupPopupContent: some View {
        if let request = lookupRequest {
            LookupPopupView(
                initialQuery: request.token,
                languageHint: book.language,
                contextSentence: request.sentence,
                sourceAnchor: request.anchor,
                extraTags: sourceTags(),
                bookID: book.id,
                onAddedNote: handleCardAdded,
                onCardCaptured: { noteID, anchor, term in
                    Task { await cards.recordLookupCard(noteID: noteID, anchor: anchor, term: term) }
                },
                onCardRemoved: { noteID in
                    Task { await cards.removeLookupCard(noteID: noteID) }
                },
                onDismiss: { lookupRequest = nil }
            )
        }
    }

    private func closeReader() {
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }

    #if os(iOS)
    private func handlePageKey(
        _ direction: ReaderPageDirection,
        press: KeyPress
    ) -> KeyPress.Result {
        guard lookupRequest == nil, press.modifiers.isEmpty else { return .ignored }
        requestPageTurn(direction)
        return .handled
    }
    #endif

    /// Single path for a page turn, so the keyboard, the accessibility
    /// action, and the edge taps all stamp the same monotonically-increasing
    /// sequence the host uses to decide a request is new.
    private func requestPageTurn(_ direction: ReaderPageDirection) {
        guard lookupRequest == nil else { return }
        let nextSequence = (pageTurnRequest?.sequence ?? 0) + 1
        pageTurnRequest = ReaderPageTurnRequest(sequence: nextSequence, direction: direction)
    }

    // MARK: - Actions

    func toggleChrome() {
        // `AmgiMotion` already collapses to a cross-fade under Reduce Motion,
        // so this no longer branches on `reduceMotion` itself.
        withAnimation(AmgiMotion.standard) {
            if chromeVisible { compactMenuVisible = false }
            chromeVisible.toggle()
        }
    }

    func showEndOfBookToast() {
        guard !didShowEndOfBookToast else { return }
        didShowEndOfBookToast = true
        withAnimation(AmgiMotion.momentum) {
            endOfBookToastVisible = true
        }
        endOfBookToastDismiss = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            dismissEndOfBookToast()
        }
    }

    /// Also called by a tap on the toast — a timed message the user has
    /// already read shouldn't make them wait out its timer.
    func dismissEndOfBookToast() {
        endOfBookToastDismiss?.cancel()
        endOfBookToastDismiss = nil
        withAnimation(AmgiMotion.standard) {
            endOfBookToastVisible = false
        }
    }

    // MARK: - Annotations

    /// Loads the book's marks and hands the page a way to ask for them.
    ///
    /// The provider is installed before the first chapter loads so a mark is
    /// painted as part of that load rather than requiring a second pass.
    private func prepareAnnotations() {
        pageCommands.markProvider = { [annotations, drafts = cards.drafts, bookID = book.id] chapterID in
            // Drafts last, so a hollow mark wins over an older mark on the
            // same words — it is the one the reader is acting on.
            await annotations.markDescriptors(for: bookID, chapterID: chapterID)
                + drafts.markDescriptors(chapterID: chapterID)
        }
    }

    /// Hooks the selection menu and mark taps up to the card session.
    private func prepareCardCapture() {
        pageCommands.cardMenuContextProvider = { [drafts = cards.drafts] in
            drafts.menuContext
        }
        pageCommands.cardCommandHandler = { [cards] command, payload in
            let chapterID = payload.anchor?.chapterID
            Task { await cards.handle(command, payload: payload, chapterID: chapterID) }
        }
        cards.onGoTo = { navigate(to: $0) }
        pageCommands.markTapHandler = { [cards] id, kind, point in
            Task { await cards.markTapped(id: id, kind: kind, at: point) }
        }
        cards.onMarksChanged = { refreshPaintedMarks() }
        cards.onCardAdded = { chapterID in
            postCardAdded(chapterID: chapterID ?? currentChapter?.id)
        }
    }

    private func loadCurrentChapterMarks() async {
        guard let currentChapter else { return }
        pageCommands.lastAppliedMarks = await chapterMarks(currentChapter.id)
        pageCommands.marksRefresh = {}
    }

    private func chapterMarks(_ chapterID: Int64) async -> [[String: Any]] {
        await annotations.markDescriptors(for: book.id, chapterID: chapterID)
            + cards.drafts.markDescriptors(chapterID: chapterID)
    }

    /// Captures an anchor for the current viewport and stores a mark on it.
    ///
    /// The page is asked where it is rather than the caller describing it: a
    /// scroll fraction is a rendering that changes with typography and device,
    /// whereas the anchor the page returns points at real text.
    private func addMark(kind: ReaderAnnotation.Kind) {
        pageCommands.requestAnchor { anchor in
            guard let anchor else { return }
            Task {
                switch kind {
                case .highlight:
                    await annotations.addHighlight(
                        in: book.id,
                        anchor: anchor,
                        excerpt: anchor.quote
                    )
                case .bookmark:
                    await annotations.addBookmark(
                        in: book.id,
                        anchor: anchor,
                        excerpt: anchor.quote
                    )
                case .card:
                    // Card marks are written by the card session alone.
                    return
                }
                refreshPaintedMarks()
            }
        }
    }

    /// Stores a highlight or bookmark made from the selection menu.
    ///
    /// The selection's anchor is preferred; a selection made by dragging
    /// handles has one, but if the page could not produce it the mark is
    /// still stored with a quote-only anchor, which re-resolves by text search
    /// on the next open. Dropping the mark instead would lose the user's
    /// highlight over a recoverable anchoring problem.
    private func handleSelectionMark(
        _ kind: ReaderAnnotation.Kind,
        _ anchor: ReaderSourceAnchor?,
        _ excerpt: String
    ) {
        // No anchor at all: build a minimal one from the quote so the mark is
        // still findable by search rather than being dropped.
        let resolved = anchor ?? ReaderSourceAnchor(
            bookID: book.id,
            chapterID: book.chapters.indices.contains(chapterIndex)
                ? book.chapters[chapterIndex].id
                : nil,
            quote: ReaderSourceAnchor.normalize(excerpt)
        )
        Task {
            switch kind {
            case .highlight:
                await annotations.addHighlight(
                    in: book.id,
                    anchor: resolved,
                    excerpt: excerpt
                )
            case .bookmark:
                await annotations.addBookmark(
                    in: book.id,
                    anchor: resolved,
                    excerpt: excerpt
                )
            case .card:
                return
            }
            refreshPaintedMarks()
        }
    }

    /// Republishes the chapter's marks to the page after a mutation.
    private func refreshPaintedMarks() {
        let chapterID = book.chapters.indices.contains(chapterIndex)
            ? book.chapters[chapterIndex].id
            : 0
        Task {
            pageCommands.lastAppliedMarks = await chapterMarks(chapterID)
            pageCommands.marksRefresh = {}
        }
    }

    /// Navigate to an annotation's chapter. The page's own resolver does the
    /// in-chapter positioning once the chapter finishes loading, so only the
    /// chapter is switched here.
    private func jump(to annotation: ReaderAnnotation) {
        navigate(to: annotation.anchor)
    }

    func prepareRestoreIfNeeded() async {
        guard let chapter = currentChapter else { return }
        if !didRequestInitialRestore,
            let saved = await progressCoordinator.resolved(bookID: book.id),
            saved.chapterID == chapter.id,
            saved.anchor != nil || saved.progress > 0.01 {
            ReaderTelemetry.log("view.restore", ["chapter": chapterIndex, "anchor": saved.anchor != nil, "progress": saved.progress])
            if let anchor = saved.anchor {
                pageCommands.navigationAnchor = anchor
                navigationRequestID &+= 1
            } else {
                pendingRestoreFraction = saved.progress
            }
        }
        didRequestInitialRestore = true
    }

    /// Debounced: `flushProgress` reads `progressFraction` when it fires, so a
    /// run of page turns collapses into one write of the position the reader
    /// actually settled on. `onDisappear` cancels this and flushes directly,
    /// so leaving mid-debounce still persists.
    func saveProgress() {
        progressSaveDebounce?.cancel()
        progressSaveDebounce = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            flushProgress()
        }
    }

    func flushProgress() {
        guard let chapter = currentChapter else { return }
        progressCoordinator.save(
            bookID: book.id,
            chapterID: chapter.id,
            progress: progressFraction,
            anchor: currentViewportAnchor
        )
    }

    func sourceTags() -> [String] {
        ["amgi::book::\(book.id)", "amgi::book::\(book.id)::ch::\(chapterIndex)"]
    }

    func handleCardAdded() {
        postCardAdded(chapterID: currentChapter?.id)
    }

    func postCardAdded(chapterID: Int64?) {
        guard let chapterID else { return }
        NotificationCenter.default.post(
            name: .amgiReaderCardAdded,
            object: nil,
            userInfo: [
                "bookID": book.id,
                "chapterID": chapterID
            ]
        )
    }
}

extension Notification.Name {
    /// Posted by the EPUB reader after `LookupPopupView` confirms a
    /// successful `addNote`. The detail screen listens and refreshes its
    /// per-chapter "N cards added" counts.
    static let amgiReaderCardAdded = Notification.Name("amgiReaderCardAdded")
}

/// One tap-to-lookup request. Identifiable so `.sheet(item:)` treats
/// every tap as a fresh presentation even when the same word is tapped
/// twice in a row.
struct LookupRequest: Identifiable {
    let id = UUID()
    let token: String
    let sentence: String
    /// Durable pointer back to the tapped words, when the page could produce
    /// one. Nil for a plain selection or an older injected script.
    let anchor: ReaderSourceAnchor?
}

/// The draft open in the refine sheet, wrapped for `.sheet(item:)`.
struct DraftSheetItem: Identifiable {
    let id: UUID
}

struct ReaderReadingPosition: Equatable {
    let chapterIndex: Int
    let pageIndex: Int

    /// Whether this position is one page turn from `previous`: the next or
    /// previous page in a chapter, or across a chapter boundary between a
    /// chapter's last page and the next one's first. An unmeasured chapter
    /// counts any page as possibly its last.
    func isTurn(from previous: ReaderReadingPosition, pageCountOf: (Int) -> Int?) -> Bool {
        if chapterIndex == previous.chapterIndex {
            return abs(pageIndex - previous.pageIndex) <= 1
        }
        func isLast(_ position: ReaderReadingPosition) -> Bool {
            pageCountOf(position.chapterIndex).map { position.pageIndex >= $0 - 1 } ?? true
        }
        if chapterIndex == previous.chapterIndex + 1 {
            return pageIndex == 0 && isLast(previous)
        }
        if chapterIndex == previous.chapterIndex - 1 {
            return previous.pageIndex == 0 && isLast(self)
        }
        return false
    }
}

/// The reader's chrome and the page's running head and folio share the same
/// two lines, so one gives way to the other. A plain crossfade left both
/// half-drawn over each other — "1 page left in chapter" through the book
/// title — at every page turn. The outgoing one leaves at once; the incoming
/// one starts only once it has gone.
enum ReaderChromeSwap {
    static let outDuration: Double = 0.1
    static let inDuration: Double = 0.16
    static let inDelay: Double = 0.1

    static var transition: AnyTransition {
        .asymmetric(
            insertion: .opacity.animation(.easeOut(duration: inDuration).delay(inDelay)),
            removal: .opacity.animation(.easeOut(duration: outDuration))
        )
    }
}

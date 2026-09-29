import AmgiReader
import AmgiTheme
import AmgiUI
import AmgiAppCore
import Sharing
import SwiftUI

/// Top-level screen for EPUB chapters. Hosts a `UIPageViewController`
/// (`.scroll`, `.horizontal`) via `EPUBPageViewControllerHost`; each
/// chapter is one `WKWebView` whose internal scroll view drives
/// intra-chapter paging. Cross-chapter transitions ride the outer
/// page controller's gesture — one continuous swipe.
///
/// Chrome (top bar + bottom progress strip) is hidden on a tap to an
/// empty area, mirroring Apple Books. Edge-tap zones (left/right 15%)
/// page forward/back without a swipe (`EPUBPageViewControllerHost`
/// routes those internally).
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
    /// Bridge to the live page controller for anchor capture and mark
    /// application. Injected into the paging host rather than reached through
    /// the representable, which owns its own coordinator.
    @State private var pageCommands = ReaderPageCommands()
    @State private var annotationsSheetVisible = false
    @State private var contentsSheetVisible = false

    /// Page-turn effect. Curl by default, like Apple Books.
    @AppStorage(ReaderPreferenceKeys.pageTransition)
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
        pagination.position(
            chapter: chapterIndex,
            pageIndex: pageIndex,
            pageCountInChapter: pageCount
        ).page
    }

    /// Total pages known so far. A lower bound until every chapter has been
    /// measured, which is why it is not printed on the page.
    private var knownPageTotal: Int {
        pagination.position(
            chapter: chapterIndex,
            pageIndex: pageIndex,
            pageCountInChapter: pageCount
        ).total
    }

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
    @State private var didRequestInitialRestore = false
    @State private var chromeVisible: Bool = true
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

    @Shared(.appStorage(ReaderPreferences.Keys.verticalLayout))
    private var verticalLayout: Bool = false
    @Shared(.appStorage(ReaderPreferences.Keys.horizontalPadding))
    private var horizontalPadding: Double = 22

    // Typography sheet preferences. These supersede the legacy per-book
    // colour pickers — once the user picks a theme it drives fg/bg
    // directly. Font family / size / line-height / page-margin / justify
    // come from the Apple Books-style sheet.
    @Shared(.appStorage(ReaderTypographyPreferences.Keys.fontFamily))
    private var typoFontFamilyRaw: String = ReaderTypographyPreferences.FontFamily.system.rawValue
    @Shared(.appStorage(ReaderTypographyPreferences.Keys.fontSize))
    private var typoFontSize: Int = 17
    @Shared(.appStorage(ReaderTypographyPreferences.Keys.lineHeight))
    private var typoLineHeight: Double = 1.55
    @Shared(.appStorage(ReaderTypographyPreferences.Keys.pageMargin))
    private var typoPageMarginRaw: String = ReaderTypographyPreferences.PageMargin.defaultMargin.rawValue
    @Shared(.appStorage(ReaderTypographyPreferences.Keys.theme))
    private var typoThemeRaw: String = ReaderTypographyPreferences.Theme.default.rawValue
    @Shared(.appStorage(ReaderTypographyPreferences.Keys.justify))
    private var typoJustify: Bool = true
    @Shared(.appStorage(ReaderTypographyPreferences.Keys.twoPageLayout))
    private var twoPageLayout: Bool = false

    @State private var typographySheetVisible: Bool = false

    private var currentChapter: ReaderChapter? {
        guard chapterIndex >= 0, chapterIndex < book.chapters.count else { return nil }
        return book.chapters[chapterIndex]
    }

    private var typoTheme: ReaderTypographyPreferences.Theme {
        ReaderTypographyPreferences.Theme(rawValue: typoThemeRaw) ?? .default
    }

    private var typoFontFamily: ReaderTypographyPreferences.FontFamily {
        ReaderTypographyPreferences.FontFamily(rawValue: typoFontFamilyRaw) ?? .system
    }

    private var typoPageMargin: ReaderTypographyPreferences.PageMargin {
        ReaderTypographyPreferences.PageMargin(rawValue: typoPageMarginRaw) ?? .defaultMargin
    }

    private func styleTokens(pageColumns: Int) -> EPUBReaderStyleTokens {
        let theme = typoTheme
        return EPUBReaderStyleTokens(
            foreground: theme.foregroundHex,
            background: theme.backgroundHex,
            fontSizePx: typoFontSize,
            lineHeight: typoLineHeight,
            paddingPx: Int(horizontalPadding),
            verticalMode: verticalLayout,
            // Empty stack means "use the book's own font", which is the default:
            // a book that embeds a serif face should keep it, exactly as Apple
            // Books does. Choosing a family in Reading Style overrides it.
            fontFamilyCSS: typoFontFamily.cssStack,
            pageMarginPx: typoPageMargin.pixels,
            textAlign: typoJustify ? "justify" : "left",
            pressTintCSS: theme.pressTintCSS,
            // The chrome floats over the page, so the text needs room to clear
            // it. Without this the last line of every page sat behind the page
            // counter, and the top line sat under the header pills.
            insetTopPx: Self.chromeInsetTop,
            insetBottomPx: Self.chromeInsetBottom,
            pageColumns: pageColumns
        )
    }

    /// Vertical space the floating chrome occupies. The page count pill and
    /// the bottom bar overlay the text, so the column box is inset by this
    /// much on every page.
    private static let chromeInsetTop: Int = 58
    private static let chromeInsetBottom: Int = 72

    var body: some View {
        ZStack(alignment: .bottom) {
            backgroundColor.ignoresSafeArea()
            pagerLayer
            endOfBookToast
        }
        .overlay(alignment: .topTrailing) { closeCapsule }
        .overlay(alignment: .topLeading) { pagesLeftCapsule }
        .overlay(alignment: .top) { runningHead }
        .overlay(alignment: .bottom) { bottomChromeBar }
        .navigationBarBackButtonHidden(true)
        #if os(iOS)
        .toolbarVisibility(.hidden, for: .navigationBar)
        .toolbarVisibility(.hidden, for: .tabBar)
        #endif
        .task { await model.preloadChapterContents(for: book) }
        .task(id: chapterIndex) { await prepareRestoreIfNeeded() }
        .sheet(isPresented: $typographySheetVisible) {
            ReaderStyleSheet(isPDF: false)
        }
        .sheet(isPresented: $contentsSheetVisible) {
            epubContentsSheet
        }
        .sheet(isPresented: $annotationsSheetVisible) {
            ReaderAnnotationsSheet(
                book: book,
                model: annotations,
                onJump: { annotation in
                    annotationsSheetVisible = false
                    jump(to: annotation)
                }
            )
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
            #endif
            // Start the running total from scratch: page counts are a
            // property of this rendering, so entering the reader with
            // different typography starts a new count.
            if pagination.chapterCount != book.chapters.count {
                pagination = ReaderPaginationIndex(chapterCount: book.chapters.count)
            }
            prepareAnnotations()
        }
        .onDisappear {
            endOfBookToastDismiss?.cancel()
            progressSaveDebounce?.cancel()
            flushProgress()
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
                    allowsTwoPageLayout: twoPageLayout && !verticalLayout
                )
                EPUBPageViewControllerHost(
                    book: book,
                    chapterContents: model.chapterContents,
                    chapterIndex: $chapterIndex,
                    styleTokens: styleTokens(pageColumns: layout.columnCount),
                    pendingRestoreFraction: pendingRestoreFraction,
                    pageTurnRequest: pageTurnRequest,
                    selectionRequestID: selectionRequestID,
                    pagingEnabled: lookupRequest == nil,
                    onPageInfo: { idx, count in
                        pageIndex = idx
                        pageCount = max(count, 1)
                        pendingRestoreFraction = nil
                        announcePageChangeIfNeeded()
                    },
                    onProgress: { fraction, idx in
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
                    onSelectionMark: handleSelectionMark,
                    pageTransition: pageTransition,
                    paginationIndex: pagination,
                    runningHead: book.title,
                    commands: pageCommands
                )
                // The transition style is fixed when the page controller is
                // built, so changing it has to rebuild rather than mutate.
                .id(pageTransition)
                .frame(width: layout.contentWidth)
                .frame(maxWidth: .infinity)
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
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var pagesLeftInChapter: Int {
        max(0, pageCount - 1 - pageIndex)
    }

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

    /// Both top capsules are removed from the tree when the chrome is hidden
    /// rather than faded to `opacity(0)`. They are translucent material — and
    /// on iOS 26, Liquid Glass — floating over a live WKWebView, so a
    /// zero-opacity layer that stays in the render tree is a backdrop sample
    /// per frame for something the reader can't see. They live in their own
    /// `.overlay`s and share layout with nothing, so removal costs no
    /// alignment; `.transition(.opacity)` keeps the fade `toggleChrome`
    /// animates.
    @ViewBuilder
    private var closeCapsule: some View {
        if chromeVisible {
            Button {
                closeReader()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(palette.textSecondary)
                    .frame(width: 44, height: 44)
                    .amgiMaterial(.regular, in: Circle(), interactive: true)
                    .amgiMaterialElevation(Circle())
            }
            .accessibilityLabel("Close")
            .padding(.top, 8)
            .padding(.trailing, 16)
            .transition(.opacity)
        }
    }

    /// The header row, matching Apple Books' arrangement.
    ///
    /// At rest the centre slot shows the *book title* — that is a running
    /// head, and it is what belongs in that position permanently. Tapping to
    /// reveal the tools swaps it for the chapter's own position: the page
    /// number within the chapter on the leading side, "N pages left in
    /// chapter" in the middle, close on the trailing side.
    ///
    /// The previous layout showed "N pages left in chapter" permanently and
    /// put the page number in a floating pill at the bottom, which is why the
    /// two were easy to confuse: neither matched a printed book.
    @ViewBuilder
    private var pagesLeftCapsule: some View {
        if chromeVisible {
            Text(pagesLeftText)
                .amgiFont(.captionBold)
                .foregroundStyle(palette.textSecondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .amgiMaterial(.regular, in: Capsule())
                .amgiMaterialElevation(Capsule())
                .padding(.top, 8)
                .padding(.leading, 16)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    @ViewBuilder
    private var runningHead: some View {
        if !chromeVisible {
            Text(book.title)
                .amgiFont(.caption)
                .foregroundStyle(palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.top, 8)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    @ViewBuilder
    private var bottomChromeBar: some View {
        if chromeVisible {
            HStack(alignment: .center) {
                // Leading: Bookmark toggle
                Button {
                    toggleBookmark()
                } label: {
                    Image(systemName: isCurrentPageBookmarked ? "bookmark.fill" : "bookmark")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(isCurrentPageBookmarked ? palette.accent : palette.textPrimary)
                        .frame(width: 44, height: 44)
                        .amgiMaterial(.regular, in: Circle(), interactive: true)
                        .amgiMaterialElevation(Circle())
                }
                .accessibilityLabel(isCurrentPageBookmarked ? "Remove Bookmark" : "Bookmark")

                Spacer(minLength: 0)

                // Centred: Page X of Y
                pageNumberCapsule

                Spacer(minLength: 0)

                // Trailing: Menu / Reading Style / Contents
                menuCapsule
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private var pageNumberCapsule: some View {
        Text("\(chapterPageNumber) of \(pageCount)")
            .amgiFont(.caption, .monospacedDigits)
            .foregroundStyle(palette.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .amgiMaterial(.regular, in: Capsule())
            .amgiMaterialElevation(Capsule())
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private var menuCapsule: some View {
        Menu {
            Button {
                typographySheetVisible = true
            } label: {
                Label("Themes & Settings", systemImage: "textformat.size")
            }
            Button {
                contentsSheetVisible = true
            } label: {
                Label("Contents & Bookmarks", systemImage: "list.bullet")
            }
            Button {
                annotationsSheetVisible = true
            } label: {
                Label("Highlights & Notes", systemImage: "highlighter")
            }
        } label: {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(palette.textPrimary)
                .frame(width: 44, height: 44)
                .amgiMaterial(.regular, in: Circle(), interactive: true)
                .amgiMaterialElevation(Circle())
        }
        .accessibilityLabel("Options")
    }

    private var isCurrentPageBookmarked: Bool {
        guard let currentChapter else { return false }
        return annotations.bookmarks.contains { bm in
            bm.anchor.chapterID == currentChapter.id && (bm.anchor.cfi == pageIndex || bm.anchor.cfi == nil)
        }
    }

    private func toggleBookmark() {
        guard let currentChapter else { return }
        if let existing = annotations.bookmarks.first(where: {
            $0.anchor.chapterID == currentChapter.id && ($0.anchor.cfi == pageIndex || $0.anchor.cfi == nil)
        }) {
            Task { await annotations.delete(existing) }
        } else {
            let anchor = ReaderSourceAnchor(
                bookID: book.id,
                chapterID: currentChapter.id,
                cfi: pageIndex,
                quote: "Page \(chapterPageNumber)",
                contextBefore: currentChapter.title
            )
            Task {
                await annotations.addBookmark(
                    in: book.id,
                    anchor: anchor,
                    excerpt: "\(currentChapter.title) — Page \(chapterPageNumber)"
                )
            }
        }
    }

    private func seekToBookPage(_ targetPage: Int) {
        let delta = targetPage - bookPageNumber
        if delta != 0 {
            let targetIdx = max(0, min(pageCount - 1, pageIndex + delta))
            if targetIdx != pageIndex {
                pageIndex = targetIdx
                requestPageTurn(delta > 0 ? .forward : .backward)
            }
        }
    }

    private var epubContentsSheet: some View {
        let outlineItems: [ReaderContentsSheet.OutlineItem] = book.chapters.enumerated().map { idx, chapter in
            ReaderContentsSheet.OutlineItem(
                id: "\(chapter.id)",
                title: chapter.title,
                pageIndex: idx,
                pageLabel: nil,
                depth: 0,
                isCurrent: idx == chapterIndex
            )
        }

        let bookmarkItems: [ReaderContentsSheet.BookmarkItem] = annotations.bookmarks.map { bm in
            let chap = book.chapters.first(where: { $0.id == bm.anchor.chapterID })
            let pNum = (bm.anchor.cfi ?? 0) + 1
            return ReaderContentsSheet.BookmarkItem(
                id: bm.id.uuidString,
                pageIndex: bm.anchor.cfi ?? 0,
                pageLabel: "\(pNum)",
                title: bm.excerpt,
                subtitle: chap?.title,
                date: bm.createdAt
            )
        }

        let noteItems: [ReaderContentsSheet.NoteItem] = annotations.highlights.map { hl in
            ReaderContentsSheet.NoteItem(
                id: hl.id.uuidString,
                pageIndex: hl.anchor.cfi ?? 0,
                pageLabel: "\( (hl.anchor.cfi ?? 0) + 1 )",
                quote: hl.excerpt,
                colorHex: hl.colorHex
            )
        }

        return ReaderContentsSheet(
            bookTitle: book.title,
            outlineItems: outlineItems,
            bookmarks: bookmarkItems,
            notes: noteItems,
            onSelectOutline: { item in
                chapterIndex = item.pageIndex
                pageIndex = 0
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
                }
            }
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
                onAddedNote: handleCardAdded,
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
        pageCommands.markProvider = { [annotations] in
            await annotations.markDescriptors(
                for: book.id,
                chapterID: book.chapters.indices.contains(chapterIndex)
                    ? book.chapters[chapterIndex].id
                    : 0
            )
        }
        Task { await annotations.load(bookID: book.id) }
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
            pageCommands.lastAppliedMarks = await annotations.markDescriptors(
                for: book.id,
                chapterID: chapterID
            )
            pageCommands.marksRefresh = {}
        }
    }

    /// Navigate to an annotation's chapter. The page's own resolver does the
    /// in-chapter positioning once the chapter finishes loading, so only the
    /// chapter is switched here.
    private func jump(to annotation: ReaderAnnotation) {
        guard let chapterID = annotation.anchor.chapterID,
              let index = book.chapters.firstIndex(where: { $0.id == chapterID })
        else { return }
        guard index != chapterIndex else { return }
        chapterIndex = index
    }

    func prepareRestoreIfNeeded() async {
        guard let chapter = currentChapter else { return }
        if !didRequestInitialRestore,
           let saved = await progressCoordinator.resolved(bookID: book.id),
           saved.chapterID == chapter.id,
           saved.progress > 0.01 {
            pendingRestoreFraction = saved.progress
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
            progress: progressFraction
        )
    }

    func sourceTags() -> [String] {
        ["amgi::book::\(book.id)", "amgi::book::\(book.id)::ch::\(chapterIndex)"]
    }

    func handleCardAdded() {
        guard let chapter = currentChapter else { return }
        NotificationCenter.default.post(
            name: .amgiReaderCardAdded,
            object: nil,
            userInfo: [
                "bookID": book.id,
                "chapterID": chapter.id
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

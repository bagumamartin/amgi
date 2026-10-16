// `public import` so `ReaderSourceAnchor` in the `onWordTap` signature is
// visible to the macOS twin of this file, which shares the call site.
import AmgiReader
import AmgiTheme
import SwiftUI
#if os(iOS)
import UIKit
import WebKit

/// `UIViewControllerRepresentable` wrapping the EPUB's full-screen page
/// controller. In curl mode each adjacent logical page has a live chapter
/// WebView positioned at its own column, so UIKit owns the finger-following
/// page turn from the start of the gesture.
struct EPUBPageViewControllerHost: UIViewControllerRepresentable {
    let book: ReaderBook
    /// Resolved content URLs keyed by chapter index. Pre-fetched on the
    /// SwiftUI side (one async call per chapter) so the page controller
    /// data source can vend adjacent VCs synchronously.
    let chapterContents: [Int: EPUBChapterContent]
    @Binding var chapterIndex: Int
    let styleTokens: EPUBReaderStyleTokens
    /// 0..1 fraction to scroll to on the first chapter load only.
    /// Consumed by the inner VC; cleared by the host once handed off.
    let pendingRestoreFraction: Double?
    let pageTurnRequest: ReaderPageTurnRequest?
    let navigationRequestID: Int
    let selectionRequestID: Int
    /// Suppresses the page controller's dataSource so dictionary sheets
    /// can absorb horizontal gestures (UX spec edge case).
    let pagingEnabled: Bool

    let onPageInfo: (Int, Int) -> Void
    let onProgress: (Double, Int) -> Void
    /// `anchor` is nil when the page could not produce one (an older injected
    /// script, or a tap that did not land on a tokenised span).
    let onWordTap: (String, String, ReaderSourceAnchor?) -> Void
    let onSelectionForNote: (String) -> Void
    let onTapEmpty: (CGFloat) -> Void
    let onReachedEnd: () -> Void
    /// Native controls fade away during a curl so the page's running head and
    /// folio participate in the full-screen sheet turn.
    let onPageTurnAnimation: (Bool) -> Void
    /// A highlight or bookmark created from the selection menu. Separate from
    /// `onSelectionForNote` because these are local marks, not lookups.
    var onSelectionMark: ((ReaderAnnotation.Kind, ReaderSourceAnchor?, String) -> Void)?
    /// How a chapter change is animated. Changing it rebuilds the page
    /// controller, because the effect is a `transitionStyle` fixed at init.
    let pageTransition: ReaderPageTransition
    /// Running total of rendered pages per chapter, so page numbers can be
    /// book-wide. Read and written by the coordinator as chapters are
    /// measured, so it is a plain var rather than part of the value.
    var paginationIndex: ReaderPaginationIndex?
    /// Book title, printed as the running head on every page.
    let runningHead: String
    /// The reader's chrome is up: the page hides its own running head and
    /// number, which the chrome replaces on the same lines.
    var chromeVisible: Bool = false
    /// A chapter's page count at the current layout, measured in the
    /// background so the book has one fixed total, the way Apple Books
    /// paginates before showing "X of Y".
    var onChapterMeasured: ((_ chapter: Int, _ pageCount: Int) -> Void)?
    /// Bridge to the live chapter controller, for anchor capture and marks.
    /// Declared last so both hosts share one parameter order and the SwiftUI
    /// call site stays platform-agnostic.
    let commands: ReaderPageCommands

    func makeCoordinator() -> Coordinator {
        Coordinator(host: self)
    }

    /// Two layers: the renderers and measuring pages at the back, out of
    /// sight, and the page turner in front. They must be siblings: inside the
    /// page turner's own view, UIKit re-inserts every page it turns *beneath*
    /// anything else there, so the renderers ended up covering the page being
    /// read — a cover or some other page appearing over it.
    @MainActor
    final class ReaderContainerController: UIViewController {
        let stagingView = UIView()
        let pageViewController: UIPageViewController

        init(pageViewController: UIPageViewController) {
            self.pageViewController = pageViewController
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

        override func loadView() {
            let root = UIView()
            root.backgroundColor = .clear
            stagingView.frame = root.bounds
            stagingView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            stagingView.isUserInteractionEnabled = false
            stagingView.accessibilityElementsHidden = true
            root.addSubview(stagingView)
            addChild(pageViewController)
            pageViewController.view.frame = root.bounds
            pageViewController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            root.addSubview(pageViewController.view)
            pageViewController.didMove(toParent: self)
            view = root
        }
    }

    @MainActor
    func makeUIViewController(context: Context) -> ReaderContainerController {
        let pageVC = UIPageViewController(
            transitionStyle: pageTransition.pageViewControllerStyle,
            navigationOrientation: .horizontal,
            options: nil
        )
        pageVC.view.backgroundColor = .clear
        let container = ReaderContainerController(pageViewController: pageVC)
        container.loadViewIfNeeded()
        context.coordinator.install(in: pageVC, staging: container.stagingView)
        context.coordinator.start(chapter: chapterIndex, restoreFraction: pendingRestoreFraction)
        return container
    }

    @MainActor
    func updateUIViewController(_ uiViewController: ReaderContainerController, context: Context) {
        context.coordinator.host = self
        context.coordinator.update()
    }

    // MARK: - Coordinator

    /// Turns the book's pages.
    ///
    /// Three kinds of page controller take part, each with one job:
    /// - **Page cards** (`EPUBPageSlotController`) are what `UIPageViewController`
    ///   turns. A card shows a picture of its page, so it can be made the
    ///   instant a turn needs it.
    /// - **Renderers** — one hidden, loaded chapter controller per nearby
    ///   chapter — draw those pictures, a page or two ahead of the reader.
    /// - **The live page** — one chapter controller for the chapter being read
    ///   — lies under the current card at rest, so selection, links, marks
    ///   and the dictionary work on real text.
    ///
    /// No turn ever waits for a chapter to load. The design this replaced
    /// gave every page its own web view; each had to load its whole chapter
    /// before it could show its page, and fast turning landed on chapter
    /// openings that only later jumped to the right page.
    @MainActor
    final class Coordinator: NSObject, UIPageViewControllerDataSource,
                             UIPageViewControllerDelegate, EPUBChapterPageControllerDelegate,
                             UIGestureRecognizerDelegate {
        var host: EPUBPageViewControllerHost

        private weak var pageViewController: UIPageViewController?
        /// Inside the window, behind the pages: renderers and measuring pages
        /// live here so WebKit keeps laying them out and painting them.
        private weak var stagingView: UIView?

        /// The card on screen.
        private var current: EPUBPageSlotController?
        /// The chapter being read, as live text.
        private var live: EPUBChapterPageController?
        /// The page the live chapter is moving to. Until it reports being
        /// there, the card's picture stays up over it.
        private var liveTarget: Int?

        init(host: EPUBPageViewControllerHost) {
            self.host = host
        }

        // MARK: Setup

        func install(in pageVC: UIPageViewController, staging: UIView) {
            pageViewController = pageVC
            pageVC.delegate = self
            pageVC.dataSource = usesNativePaging ? self : nil

            stagingView = staging

            // UIKit's own pan and tap wait on this guard, which claims touches
            // that land on the live selection, so holding a selection to drag
            // it onto a docked card does not start a page turn.
            let selectionGuard = ReaderSelectionTouchGuard { [weak self] touch in
                self?.touchIsOnSelection(touch) ?? false
            }
            pageVC.view.addGestureRecognizer(selectionGuard)
            for recognizer in pageVC.gestureRecognizers {
                recognizer.require(toFail: selectionGuard)
            }

            // The current card swaps to its picture as soon as a sideways drag
            // starts — before UIKit's curl captures the page it turns.
            let observer = ReaderTouchObserver()
            observer.onHorizontalDragBegan = { [weak self] touch in self?.horizontalDragBegan(touch) }
            observer.onTouchesEnded = { [weak self] in self?.touchesEnded() }
            pageVC.view.addGestureRecognizer(observer)

            // Slide and Fast Fade are our own animations, driven by our pan.
            if !usesNativePaging {
                let pan = UIPanGestureRecognizer(target: self, action: #selector(handleSwipe(_:)))
                pan.delegate = self
                pan.maximumNumberOfTouches = 1
                pageVC.view.addGestureRecognizer(pan)
                swipeRecogniser = pan
            }
        }

        /// Curl and Scroll are UIKit's interactive turns, fed by the data
        /// source. Slide and Fast Fade are animated by the coordinator.
        private var usesNativePaging: Bool {
            host.pageTransition == .curl || host.pageTransition == .scroll
        }

        func start(chapter: Int, restoreFraction: Double?) {
            jump(toChapter: chapter, restoreFraction: restoreFraction, reason: "start")
        }

        // MARK: Update

        func update() {
            guard let pageVC = pageViewController else { return }
            pageVC.dataSource = usesNativePaging && host.pagingEnabled ? self : nil
            applyStyleTokensIfChanged()
            invalidatePicturesIfResized()
            live?.chromeVisible = host.chromeVisible
            // Only the page being read gives way to the bar; a page mid-curl
            // keeps its own head and number.
            current?.furnitureHidden = host.chromeVisible
            consumeSelectionRequestIfNeeded()
            fulfilSelectionMarkRequest()
            if consumePageTurnRequestIfNeeded() { return }
            // A binding that disagrees with the page on screen is either a
            // jump the view asked for, or stale. Never mid-turn.
            if !isTransitioning, let current, host.chapterIndex != current.address.chapter {
                if host.chapterIndex != lastSeenBindingChapter {
                    jump(toChapter: host.chapterIndex, restoreFraction: host.pendingRestoreFraction, reason: "binding")
                } else {
                    let shown = current.address.chapter
                    ReaderTelemetry.log("binding.corrected", ["stale": host.chapterIndex, "shown": shown])
                    DispatchQueue.main.async { [weak self] in self?.host.chapterIndex = shown }
                }
            }
            lastSeenBindingChapter = host.chapterIndex
            continuePagination()
            // Pictures drawn before the book was measured carry the page
            // number within the chapter; redraw them with book-wide ones.
            let complete = host.paginationIndex?.unmeasured.isEmpty ?? false
            if complete, !paginationWasComplete {
                discardPictures(reason: "paginated")
                redressAllCards()
            }
            paginationWasComplete = complete
            fulfilPendingAnchorRequest()
            consumePageIndexRequest()
            fulfilPendingNavigationAnchor()
            if consumeMarksRefresh() { applyPendingMarks() }
        }

        private var lastSeenBindingChapter: Int?
        /// A jump loaded a new chapter whose live page has not reported yet.
        private var awaitingFirstReport = false
        private var paginationWasComplete = false
        private var appliedTokens: EPUBReaderStyleTokens?
        private var picturedSize: CGSize = .zero

        private func applyStyleTokensIfChanged() {
            guard appliedTokens != host.styleTokens else { return }
            let first = appliedTokens == nil
            appliedTokens = host.styleTokens
            guard !first else { return }
            ReaderTelemetry.log("layout.tokens")
            live?.update(styleTokens: host.styleTokens)
            for renderer in renderers.values { renderer.update(styleTokens: host.styleTokens) }
            discardPictures(reason: "tokens")
            pageCounts.removeAll()
            picturedLayout.removeAll()
        }

        private func invalidatePicturesIfResized() {
            guard let size = stagingView?.bounds.size, size.width > 1 else { return }
            if picturedSize != .zero, picturedSize != size {
                discardPictures(reason: "resize")
                pageCounts.removeAll()
            }
            picturedSize = size
        }

        // MARK: Cards

        private struct WeakSlot { weak var slot: EPUBPageSlotController? }
        /// Every card alive, so a picture that finishes drawing reaches the
        /// cards waiting for it — including one mid-curl.
        private var cards: [WeakSlot] = []

        private var pageColor: UIColor {
            UIColor(amgiHex: host.styleTokens.background) ?? .systemBackground
        }

        private func card(for address: EPUBPageAddress) -> EPUBPageSlotController {
            let resolved = resolve(address)
            let card = EPUBPageSlotController(address: resolved, pageColor: pageColor)
            card.loadViewIfNeeded()
            dressFurniture(card)
            card.picture = pictures[resolved]?.image
            card.showsPicture = true
            cards.removeAll { $0.slot == nil }
            cards.append(WeakSlot(slot: card))
            if card.picture == nil { requestPicture(resolved) }
            return card
        }

        /// Puts the book title and the page's number on a card, where they
        /// turn with it.
        private func dressFurniture(_ card: EPUBPageSlotController) {
            card.furnitureLines = (CGFloat(host.styleTokens.headCenterPx), CGFloat(host.styleTokens.footCenterPx))
            let color = (UIColor(amgiHex: host.styleTokens.foreground) ?? .label).withAlphaComponent(0.55)
            let page: Int
            if card.address.page >= 0, let count = pageCount(of: card.address.chapter) {
                page = bookPaginationPosition(chapter: card.address.chapter, page: card.address.page, pageCount: count).page
            } else {
                page = 0
            }
            card.setFurniture(title: host.runningHead, page: page, color: color)
        }

        /// Re-numbers every card, after the page count or the book's
        /// pagination changed.
        private func redressAllCards() {
            for entry in cards {
                if let card = entry.slot { dressFurniture(card) }
            }
        }

        private func resolve(_ address: EPUBPageAddress) -> EPUBPageAddress {
            EPUBReadingNavigator.resolve(address) { self.pageCount(of: $0) }
        }

        private func neighbour(of address: EPUBPageAddress, _ direction: EPUBChapterPageController.PageDirection) -> EPUBPageAddress? {
            EPUBReadingNavigator.neighbour(
                of: address,
                direction == .forward ? .forward : .backward,
                chapterCount: host.book.chapters.count
            ) { self.pageCount(of: $0) }
        }

        // MARK: Page counts

        private var pageCounts: [Int: Int] = [:]

        private func pageCount(of chapter: Int) -> Int? {
            pageCounts[chapter] ?? host.paginationIndex?.pageCounts[chapter]
        }

        // MARK: Renderers and pictures

        private var renderers: [Int: EPUBChapterPageController] = [:]
        private var readyRenderers: Set<Int> = []
        /// A page's picture, with what the renderer's page reported showing
        /// when it was taken — checked against the live page on settling.
        private struct Picture {
            let image: UIImage
            let state: EPUBPageState
        }

        private var pictures: [EPUBPageAddress: Picture] = [:]
        private var pictureRequests: [Int: [Int]] = [:]
        private var renderingChapters: Set<Int> = []
        private static let pictureBudget = 24

        private func requestPicture(_ address: EPUBPageAddress) {
            guard host.book.chapters.indices.contains(address.chapter), pictures[address] == nil else { return }
            ensureRenderer(for: address.chapter)
            var queue = pictureRequests[address.chapter] ?? []
            queue.removeAll { $0 == address.page }
            queue.append(address.page)
            pictureRequests[address.chapter] = queue
            pumpPictures(in: address.chapter)
        }

        private func ensureRenderer(for chapter: Int) {
            guard renderers[chapter] == nil, let stagingView,
                  let renderer = makeChapterVC(at: chapter, restoreFraction: 0, role: .renderer) else { return }
            renderer.view.frame = stagingView.bounds
            renderer.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            stagingView.addSubview(renderer.view)
            renderers[chapter] = renderer
            ReaderTelemetry.log("renderer.created", ["chapter": chapter])
        }

        /// The layout each chapter's pictures were drawn at, by page count.
        private var picturedLayout: [Int: Int] = [:]
        private var rendererSettle: [Int: Task<Void, Never>] = [:]

        /// A renderer reported its layout. The first reports after a load are
        /// provisional — fonts and images are still arriving, and a chapter
        /// that will lay out to 30 pages first says 22 — so drawing starts
        /// only once the count has held for a moment. A picture drawn from a
        /// provisional layout shows the wrong text for its page; that is what
        /// flashed up at the start of a curl.
        private func rendererReported(_ renderer: EPUBChapterPageController, pageCount: Int) {
            let chapter = renderer.chapterIndex
            if let drawnAt = picturedLayout[chapter], drawnAt != pageCount {
                ReaderTelemetry.log("renderer.relayout", ["chapter": chapter, "from": drawnAt, "to": pageCount])
                picturedLayout[chapter] = nil
                readyRenderers.remove(chapter)
                discardPictures(reason: "relayout", chapter: chapter)
            }
            rendererSettle[chapter]?.cancel()
            rendererSettle[chapter] = Task { @MainActor [weak self, weak renderer] in
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled, let self, let renderer, self.renderers[chapter] === renderer else { return }
                let count = renderer.pageCount
                self.pageCounts[chapter] = count
                self.picturedLayout[chapter] = count
                guard self.readyRenderers.insert(chapter).inserted else { return }
                ReaderTelemetry.log("renderer.ready", ["chapter": chapter, "count": count])
                // Cards entered backwards wait for this count.
                for entry in self.cards {
                    if let card = entry.slot, card.address.chapter == chapter, card.address.page < 0 {
                        card.address = self.resolve(card.address)
                    }
                }
                self.pumpPictures(in: chapter)
            }
        }

        /// Draws the newest request first: the reader has usually moved past
        /// the older ones.
        private func pumpPictures(in chapter: Int) {
            guard readyRenderers.contains(chapter), !renderingChapters.contains(chapter),
                  let renderer = renderers[chapter],
                  var queue = pictureRequests[chapter], let page = queue.popLast() else { return }
            pictureRequests[chapter] = queue
            renderingChapters.insert(chapter)
            let count = pageCount(of: chapter) ?? renderer.pageCount
            let resolvedPage = page < 0 ? max(0, count - 1) : page
            Task { @MainActor [weak self, weak renderer] in
                let drawn = await renderer?.renderPicture(ofPage: resolvedPage)
                guard let self else { return }
                self.renderingChapters.remove(chapter)
                let address = EPUBPageAddress(chapter: chapter, page: resolvedPage)
                // Kept only if the renderer's page says it showed this page,
                // at the layout still in force.
                if let drawn, let renderer, self.renderers[chapter] === renderer,
                   drawn.state.page == resolvedPage,
                   self.picturedLayout[chapter] == drawn.state.pageCount {
                    self.store(Picture(image: drawn.image, state: drawn.state), for: address)
                } else {
                    ReaderTelemetry.log("picture.rejected", [
                        "page": address, "reported": drawn?.state.page ?? -1,
                        "count": drawn?.state.pageCount ?? -1, "layout": self.picturedLayout[chapter] ?? -1,
                    ])
                }
                self.pumpPictures(in: chapter)
            }
        }

        private func store(_ picture: Picture, for address: EPUBPageAddress) {
            pictures[address] = picture
            let image = picture.image
            ReaderTelemetry.log("picture.drawn", [
                "page": address, "first": picture.state.firstOffset ?? -1, "last": picture.state.lastOffset ?? -1,
            ])
            for entry in cards {
                guard let card = entry.slot else { continue }
                let lastPage = card.address.page < 0 && card.address.chapter == address.chapter
                    && pageCount(of: address.chapter).map { $0 - 1 } == address.page
                if card.address == address || lastPage {
                    if lastPage { card.address = address }
                    card.picture = image
                }
            }
            trimPictures()
        }

        /// Keeps the pictures nearest the reader.
        private func trimPictures() {
            guard pictures.count > Self.pictureBudget, let here = current?.address else { return }
            let ranked = pictures.keys.sorted { distance($0, here) < distance($1, here) }
            for address in ranked.dropFirst(Self.pictureBudget) { pictures[address] = nil }
        }

        private func distance(_ a: EPUBPageAddress, _ b: EPUBPageAddress) -> Int {
            abs(a.chapter - b.chapter) * 10_000 + abs(a.page - b.page)
        }

        private func discardPictures(reason: String, chapter: Int? = nil) {
            ReaderTelemetry.log("picture.discard", ["reason": reason, "chapter": chapter ?? -1])
            if let chapter {
                pictures = pictures.filter { $0.key.chapter != chapter }
            } else {
                pictures.removeAll()
            }
            for entry in cards {
                guard let card = entry.slot, chapter == nil || card.address.chapter == chapter else { continue }
                card.picture = nil
            }
            if let current { prefetch(around: current.address) }
        }

        /// Pictures for the pages a turn can reach, and renderers only for
        /// the chapters those pages are in.
        private func prefetch(around address: EPUBPageAddress) {
            var wanted: [EPUBPageAddress] = [address]
            var forward = address, backward = address
            for _ in 0..<2 {
                if let next = neighbour(of: forward, .forward) { wanted.append(next); forward = next }
                if let previous = neighbour(of: backward, .backward) { wanted.append(previous); backward = previous }
            }
            // Nearest first: the queue draws the newest request first.
            for target in wanted.reversed() where pictures[resolve(target)] == nil {
                requestPicture(resolve(target))
            }
            let keep = Set(wanted.map(\.chapter)).union([address.chapter])
            for (chapter, renderer) in renderers where !keep.contains(chapter) {
                renderer.view.removeFromSuperview()
                renderers[chapter] = nil
                readyRenderers.remove(chapter)
                pictureRequests[chapter] = nil
                picturedLayout[chapter] = nil
                rendererSettle[chapter]?.cancel()
                ReaderTelemetry.log("renderer.released", ["chapter": chapter])
            }
        }

        // MARK: Live page

        private enum Role { case live, renderer, measure }

        private func makeChapterVC(
            at index: Int,
            restoreFraction: Double?,
            pageIndex: Int? = nil,
            role: Role
        ) -> EPUBChapterPageController? {
            guard host.book.chapters.indices.contains(index),
                  let content = host.chapterContents[index] else { return nil }
            let vc = EPUBChapterPageController(
                chapterIndex: index,
                content: content,
                styleTokens: host.styleTokens,
                pendingRestoreFraction: restoreFraction,
                pendingPageIndex: pageIndex,
                // Every turn is the coordinator's; no page scrolls itself.
                isPageCurlManaged: true
            )
            vc.pageDelegate = self
            vc.runningHead = host.runningHead
            vc.isMeasurementOnly = role == .measure
            // Pictures always carry the page's own running head and number.
            vc.chromeVisible = role == .live ? host.chromeVisible : false
            // Marks are drawn in pictures too, so renderers get them.
            vc.annotationProvider = { [commands = host.commands] chapterID in
                await commands.markProvider?(chapterID) ?? []
            }
            if role == .live {
                vc.selectionHighlightHandler = { [commands = host.commands] payload in
                    commands.selectionMarkRequest = .init(kind: .highlight, anchor: payload.anchor, excerpt: payload.text)
                }
                vc.selectionBookmarkHandler = { [commands = host.commands] payload in
                    commands.selectionMarkRequest = .init(kind: .bookmark, anchor: payload.anchor, excerpt: payload.text)
                }
                vc.selectionCardHandler = { [commands = host.commands] command, payload in
                    commands.cardCommandHandler?(command, payload)
                }
                vc.cardMenuContextProvider = { [commands = host.commands] in
                    commands.cardMenuContextProvider?() ?? ReaderCardMenuContext()
                }
                vc.markTapHandler = { [commands = host.commands] id, kind in
                    commands.markTapHandler?(id, kind)
                }
                vc.selectionReportHandler = { [commands = host.commands] payload in
                    commands.lastSelection = payload
                }
            }
            vc.loadViewIfNeeded()
            return vc
        }

        /// Makes `chapter` the live one, reusing it when it already is.
        @discardableResult
        private func makeLive(chapter: Int, restoreFraction: Double?, page: Int?) -> EPUBChapterPageController? {
            if let live, live.chapterIndex == chapter { return live }
            current?.detachSurface()
            live = makeChapterVC(at: chapter, restoreFraction: restoreFraction, pageIndex: page, role: .live)
            ReaderTelemetry.log("live.created", ["chapter": chapter, "page": page ?? -1, "fraction": restoreFraction ?? -1])
            return live
        }

        /// Shows a card's picture until the live page is on the card's page,
        /// then the live page itself.
        private func bringLive(to card: EPUBPageSlotController) {
            let address = card.address
            if let live, live.chapterIndex == address.chapter, live.isReadyForPaging {
                card.attach(live)
                card.showsPicture = card.hasPicture
                // Without a picture to cover it, the live page would show the
                // page it was on until it moves — the glitch on settling. It
                // stays invisible until it has been drawn at this page.
                live.view.alpha = card.hasPicture ? 1 : 0
                liveTarget = nil
                Task { @MainActor [weak self, weak card, weak live] in
                    guard let live, let shown = await live.showPage(address.page) else { return }
                    live.view.alpha = 1
                    guard let self, let card, card === self.current else { return }
                    self.verify(shown, on: card)
                    self.revealLive(on: card)
                }
            } else {
                guard let live = makeLive(chapter: address.chapter, restoreFraction: nil, page: max(0, address.page)) else { return }
                card.attach(live)
                liveTarget = max(0, address.page)
                card.showsPicture = card.hasPicture
                live.view.alpha = card.hasPicture ? 1 : 0
            }
            live?.chromeVisible = host.chromeVisible
        }

        /// Checks what the live page reports showing against the card it is
        /// under, and the card's picture against both. The page report is the
        /// truth: a card that disagrees takes the page the live text is on,
        /// and a picture that shows different words is thrown away.
        private func verify(_ shown: EPUBPageState, on card: EPUBPageSlotController) {
            let asked = card.address
            if shown.page != asked.page {
                ReaderTelemetry.log("verify.page", ["asked": asked, "shown": shown.page, "count": shown.pageCount])
                card.address.page = shown.page
                dressFurniture(card)
                emitPageInfo(chapter: asked.chapter, page: shown.page)
            }
            if let picture = pictures[asked], picture.state.firstOffset != shown.firstOffset {
                ReaderTelemetry.log("verify.picture", [
                    "page": asked, "pictureFirst": picture.state.firstOffset ?? -1, "liveFirst": shown.firstOffset ?? -1,
                ])
                pictures[asked] = nil
                card.picture = nil
                requestPicture(card.address)
            } else {
                ReaderTelemetry.log("verify.ok", ["page": card.address, "first": shown.firstOffset ?? -1, "last": shown.lastOffset ?? -1])
            }
        }

        /// Hides the picture once WebKit has painted the live page under it —
        /// two frames after the move.
        private func revealLive(on card: EPUBPageSlotController) {
            DispatchQueue.main.async { DispatchQueue.main.async { [weak self, weak card] in
                guard let self, let card, card === self.current, !self.isTransitioning, self.liveTarget == nil else { return }
                card.showsPicture = false
            } }
        }

        /// Starts reading at a chapter with no turn: the first page, a jump
        /// from the contents, a search hit, a restore.
        private func jump(toChapter chapter: Int, restoreFraction: Double?, reason: String) {
            guard let pageVC = pageViewController,
                  host.book.chapters.indices.contains(chapter) else { return }
            ReaderTelemetry.log("jump.chapter", ["chapter": chapter, "fraction": restoreFraction ?? -1, "reason": reason])
            let card = EPUBPageSlotController(address: EPUBPageAddress(chapter: chapter, page: 0), pageColor: pageColor)
            card.loadViewIfNeeded()
            dressFurniture(card)
            card.furnitureHidden = host.chromeVisible
            cards.append(WeakSlot(slot: card))
            if live?.chapterIndex == chapter {
                // Same chapter: the live page moves itself (anchor or page).
                card.attach(live!)
                card.address.page = live!.currentPageIndex
                card.showsPicture = false
                live?.view.alpha = 1
            } else {
                current?.detachSurface()
                live = makeChapterVC(at: chapter, restoreFraction: restoreFraction, pageIndex: nil, role: .live)
                if let live { card.attach(live) }
                // A new chapter takes a moment to load. Its first page shows
                // from a picture at once when the renderer has one — the
                // common case, since it is drawn ahead — and the live page,
                // still blank, stays hidden until it reports in.
                let restoresInside = (restoreFraction ?? 0) > 0 || host.commands.navigationAnchor != nil
                card.picture = restoresInside ? nil : pictures[EPUBPageAddress(chapter: chapter, page: 0)]?.image
                card.showsPicture = card.hasPicture
                live?.view.alpha = card.hasPicture ? 1 : 0
                awaitingFirstReport = true
                if !restoresInside { requestPicture(EPUBPageAddress(chapter: chapter, page: 0)) }
            }
            liveTarget = nil
            pageVC.setViewControllers([card], direction: .forward, animated: false)
            current = card
        }

        // MARK: Turning

        var isTransitioning = false
        private var queuedTurnRequest: ReaderPageTurnRequest?
        private var handledPageTurnSequence = 0
        private var handledSelectionRequestID = 0
        private var swipeRecogniser: UIPanGestureRecognizer?

        /// Turns one page, with the chosen effect.
        @discardableResult
        func navigate(_ direction: EPUBChapterPageController.PageDirection) -> Bool {
            guard host.pagingEnabled, !isTransitioning, let pageVC = pageViewController,
                  let from = current else { return false }
            guard let target = neighbour(of: from.address, direction) else {
                if direction == .forward { host.onReachedEnd() }
                return false
            }
            let next = card(for: target)
            ReaderTelemetry.log("turn.programmatic", ["from": from.address, "to": next.address, "mode": host.pageTransition.rawValue])
            from.showsPicture = from.hasPicture
            isTransitioning = true
            host.onPageTurnAnimation(true)
            let forward = direction == .forward
            let finish: (Bool) -> Void = { [weak self] completed in
                guard let self else { return }
                self.finishTurn(on: completed ? next : from, completed: completed)
            }
            if AmgiMotion.prefersReducedMotion {
                pageVC.setViewControllers([next], direction: forward ? .forward : .reverse, animated: false, completion: finish)
                return true
            }
            switch host.pageTransition {
            case .curl, .scroll:
                pageVC.setViewControllers([next], direction: forward ? .forward : .reverse, animated: true, completion: finish)
            case .fastFade:
                pageVC.setViewControllers([next], direction: forward ? .forward : .reverse, animated: false)
                let container = pageVC.view.superview ?? pageVC.view!
                UIView.transition(
                    with: container,
                    duration: ReaderPageTransition.fastFade.duration,
                    options: [.transitionCrossDissolve, .beginFromCurrentState],
                    animations: nil
                ) { _ in finish(true) }
            case .slide:
                slide(from: from, to: next, forward: forward, in: pageVC, completion: finish)
            }
            return true
        }

        /// Apple's "Slide": the outgoing page moves aside a little while the
        /// incoming one slides in from the edge.
        private func slide(
            from: EPUBPageSlotController,
            to next: EPUBPageSlotController,
            forward: Bool,
            in pageVC: UIPageViewController,
            completion: @escaping (Bool) -> Void
        ) {
            let width = pageVC.view.bounds.width
            let outgoing = from.view.snapshotView(afterScreenUpdates: false)
            pageVC.setViewControllers([next], direction: forward ? .forward : .reverse, animated: false)
            guard let container = next.view.superview else { completion(true); return }
            if let outgoing {
                outgoing.frame = container.bounds
                container.insertSubview(outgoing, belowSubview: next.view)
            }
            next.view.transform = CGAffineTransform(translationX: forward ? width : -width, y: 0)
            UIView.animate(
                withDuration: ReaderPageTransition.slide.duration,
                delay: 0,
                options: [.curveEaseOut, .beginFromCurrentState]
            ) {
                next.view.transform = .identity
                outgoing?.transform = CGAffineTransform(translationX: forward ? -width * 0.28 : width * 0.28, y: 0)
            } completion: { _ in
                outgoing?.removeFromSuperview()
                next.view.transform = .identity
                completion(true)
            }
        }

        /// Every turn ends here, however it was made.
        private func finishTurn(on card: EPUBPageSlotController, completed: Bool) {
            isTransitioning = false
            host.onPageTurnAnimation(false)
            ReaderTelemetry.log("turn.finished", ["completed": completed, "now": card.address])
            if completed {
                settle(on: card)
            } else if let current {
                // Let go of a curl: the reader is still on this page. The live
                // page may have re-flowed while it curled, so it is put back on
                // the card's page before the picture lifts.
                current.showsPicture = current.hasPicture
                if let live, live.parent === current, liveTarget == nil {
                    Task { @MainActor [weak self, weak current, weak live] in
                        guard let live, let current else { return }
                        guard let shown = await live.showPage(current.address.page) else { return }
                        self?.verify(shown, on: current)
                        self?.revealLive(on: current)
                    }
                }
            }
            serviceQueuedTurnIfNeeded()
        }

        private func settle(on card: EPUBPageSlotController) {
            let previous = current
            current = card
            if previous !== card {
                previous?.detachSurface()
                previous?.furnitureHidden = false
            }
            card.furnitureHidden = host.chromeVisible
            if host.chapterIndex != card.address.chapter {
                host.chapterIndex = card.address.chapter
            }
            bringLive(to: card)
            emitPageInfo(chapter: card.address.chapter, page: card.address.page)
            prefetch(around: card.address)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.logViewStack() }
        }

        /// What is actually stacked on screen, front to back, for telemetry.
        private func logViewStack() {
            guard let root = pageViewController?.view.superview else { return }
            var lines: [String] = []
            func walk(_ view: UIView, depth: Int) {
                guard depth < 6 else { return }
                let name = String(describing: type(of: view))
                let owner = (view.next as? UIViewController).map { String(describing: type(of: $0)) } ?? ""
                var tag = ""
                if let card = view.next as? EPUBPageSlotController { tag = " card=\(card.address) pic=\(card.hasPicture)/\(card.showsPicture)" }
                if let chapter = view.next as? EPUBChapterPageController { tag = " chapter=\(chapter.telemetryTag)" }
                lines.append("\(String(repeating: ".", count: depth))\(name)\(owner.isEmpty ? "" : "<\(owner)>") f=\(Int(view.frame.minX)),\(Int(view.frame.minY)),\(Int(view.frame.width))x\(Int(view.frame.height)) a=\(view.alpha) h=\(view.isHidden) bg=\(view.backgroundColor.map { $0 == .clear ? "clear" : "set" } ?? "nil")\(tag)")
                if view is WKWebView { return }
                for sub in view.subviews { walk(sub, depth: depth + 1) }
            }
            walk(root, depth: 0)
            ReaderTelemetry.log("viewstack", ["views": lines.joined(separator: " | ")])
        }

        private func serviceQueuedTurnIfNeeded() {
            guard !isTransitioning, let request = queuedTurnRequest else { return }
            queuedTurnRequest = nil
            navigate(request.direction == .forward ? .forward : .backward)
        }

        @discardableResult
        private func consumePageTurnRequestIfNeeded() -> Bool {
            guard let request = host.pageTurnRequest, request.sequence > handledPageTurnSequence else { return false }
            handledPageTurnSequence = request.sequence
            guard !isTransitioning else {
                queuedTurnRequest = request
                return true
            }
            return navigate(request.direction == .forward ? .forward : .backward)
        }

        // MARK: Gestures

        func touchIsOnSelection(_ touch: UITouch) -> Bool {
            guard let live, live.parent === current else { return false }
            return live.touchIsOnSelection(touch)
        }

        private func horizontalDragBegan(_ touch: UITouch) {
            guard !touchIsOnSelection(touch), let current else { return }
            ReaderTelemetry.log("touch.drag", ["page": current.address, "picture": current.hasPicture])
            if current.hasPicture { current.showsPicture = true }
        }

        private func touchesEnded() {
            guard !isTransitioning, let current else { return }
            current.showsPicture = liveTarget != nil && current.hasPicture
        }

        /// Distance that counts as a turn, as a fraction of the page width.
        private static let swipeThresholdFraction: CGFloat = 0.22

        @objc private func handleSwipe(_ recognizer: UIPanGestureRecognizer) {
            guard recognizer.state == .ended, let view = recognizer.view else { return }
            let translation = recognizer.translation(in: view)
            let velocity = recognizer.velocity(in: view)
            guard abs(translation.x) > abs(translation.y) * 1.5 else { return }
            let far = abs(translation.x) > view.bounds.width * Self.swipeThresholdFraction
            let flicked = abs(velocity.x) > 600 && abs(translation.x) > 24
            guard far || flicked else { return }
            navigate(translation.x < 0 ? .forward : .backward)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            !(gestureRecognizer === swipeRecogniser && touchIsOnSelection(touch))
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            true
        }

        // MARK: UIPageViewControllerDataSource

        func pageViewController(
            _ pageViewController: UIPageViewController,
            viewControllerBefore viewController: UIViewController
        ) -> UIViewController? {
            guard host.pagingEnabled, !isJumpPending,
                  let card = viewController as? EPUBPageSlotController,
                  let target = neighbour(of: card.address, .backward) else { return nil }
            let vended = self.card(for: target)
            ReaderTelemetry.log("datasource.before", ["from": card.address, "vended": vended.address, "picture": vended.hasPicture])
            return vended
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            viewControllerAfter viewController: UIViewController
        ) -> UIViewController? {
            guard host.pagingEnabled, !isJumpPending,
                  let card = viewController as? EPUBPageSlotController else { return nil }
            guard let target = neighbour(of: card.address, .forward) else {
                host.onReachedEnd()
                return nil
            }
            let vended = self.card(for: target)
            ReaderTelemetry.log("datasource.after", ["from": card.address, "vended": vended.address, "picture": vended.hasPicture])
            return vended
        }

        /// While a jump's live page has not reported where it landed, the
        /// card's page is a guess, and so would its neighbours be.
        private var isJumpPending: Bool {
            guard let current, let live, live.parent === current else { return false }
            return !live.isReadyForPaging
        }

        // MARK: UIPageViewControllerDelegate

        func pageViewController(
            _ pageViewController: UIPageViewController,
            willTransitionTo pendingViewControllers: [UIViewController]
        ) {
            isTransitioning = true
            host.onPageTurnAnimation(true)
            if let current, current.hasPicture { current.showsPicture = true }
            for case let card as EPUBPageSlotController in pendingViewControllers {
                card.showsPicture = true
            }
            ReaderTelemetry.log("turn.began", [
                "from": current?.address.description ?? "?",
                "to": pendingViewControllers.compactMap { ($0 as? EPUBPageSlotController)?.address.description }.joined(separator: ","),
            ])
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            didFinishAnimating finished: Bool,
            previousViewControllers: [UIViewController],
            transitionCompleted completed: Bool
        ) {
            let shown = pageViewController.viewControllers?.first as? EPUBPageSlotController
            guard let shown else {
                isTransitioning = false
                host.onPageTurnAnimation(false)
                return
            }
            finishTurn(on: shown, completed: completed && shown !== current)
        }

        // MARK: Page info

        private func emitPageInfo(chapter: Int, page: Int) {
            let count = pageCount(of: chapter) ?? max(1, page + 1)
            let fraction = count <= 1 ? 1 : Double(page) / Double(count - 1)
            host.onPageInfo(page, count)
            host.onProgress(fraction, page)
        }

        private func bookPaginationPosition(chapter: Int, page: Int, pageCount: Int) -> (page: Int, total: Int) {
            var measured = host.paginationIndex?.pageCounts ?? [:]
            if measured[chapter] == nil { measured[chapter] = pageCount }
            let position = EPUBReadingNavigator.bookPage(
                of: EPUBPageAddress(chapter: chapter, page: page),
                chapterCount: host.book.chapters.count,
                measuredCounts: measured
            )
            return (position.page, position.total)
        }

        // MARK: EPUBChapterPageControllerDelegate

        func epubChapter(
            _ controller: EPUBChapterPageController,
            didReportPageInfoIndex pageIndex: Int,
            pageCount: Int
        ) {
            if controller.isMeasurementOnly {
                measuringPageReported(pageCount: pageCount)
                return
            }
            pageCounts[controller.chapterIndex] = pageCount
            if let renderer = renderers[controller.chapterIndex], renderer === controller {
                rendererReported(renderer, pageCount: pageCount)
                return
            }
            guard controller === live, let current, controller.parent === current else { return }
            // A turn re-lays the page out at a passing size; counts and pages
            // reported meanwhile describe that, not the book.
            guard !isTransitioning else { return }
            if awaitingFirstReport, controller.isReadyForPaging {
                awaitingFirstReport = false
                controller.view.alpha = 1
                revealLive(on: current)
            }
            ReaderTelemetry.log("page.report", [
                "page": controller.telemetryTag, "reported": pageIndex, "count": pageCount,
                "target": liveTarget ?? -1,
            ])
            if let target = liveTarget {
                guard pageIndex == target || pageIndex == max(0, pageCount - 1) && target >= pageCount else {
                    // Still loading or restoring: keep the picture up.
                    if controller.isReadyForPaging, pageIndex != target {
                        controller.setPage(target, animated: false)
                    }
                    return
                }
                liveTarget = nil
                controller.view.alpha = 1
                revealLive(on: current)
            } else if pageIndex != current.address.page {
                // At rest the live page only moves when told to, or when the
                // layout changes and it keeps the reader on the same words —
                // either way its report is where the reader is.
                current.address.page = pageIndex
            }
            dressFurniture(current)
            emitPageInfo(chapter: controller.chapterIndex, page: pageIndex)
            prefetch(around: current.address)
        }

        func epubChapter(
            _ controller: EPUBChapterPageController,
            didReportProgressFraction fraction: Double,
            pageIndex: Int
        ) {
            guard controller === live, liveTarget == nil, !isTransitioning else { return }
            host.onProgress(fraction, pageIndex)
        }

        func epubChapter(
            _ controller: EPUBChapterPageController,
            didSelectText text: String,
            token: String,
            sentence: String,
            anchor: ReaderSourceAnchor?
        ) {
            // Reached only when Look Up is chosen from the selection menu.
            host.onWordTap(token, sentence, anchor)
        }

        func epubChapter(_ controller: EPUBChapterPageController, didSelectTextForNote text: String) {
            host.onSelectionForNote(text)
        }

        func epubChapterDidTapEmptySpace(_ controller: EPUBChapterPageController, atRelativeX relativeX: CGFloat) {
            guard controller === live else { return }
            ReaderTelemetry.log("tap.empty", ["x": (relativeX * 100).rounded() / 100])
            // Edge zones turn the page; the middle toggles the chrome.
            if relativeX <= 0.15 {
                navigate(.backward)
            } else if relativeX >= 0.85 {
                navigate(.forward)
            } else {
                host.onTapEmpty(relativeX)
            }
        }

        // MARK: Commands from the view

        private func consumeSelectionRequestIfNeeded() {
            guard host.selectionRequestID > handledSelectionRequestID else { return }
            handledSelectionRequestID = host.selectionRequestID
            live?.requestSelectionForNote()
        }

        private func fulfilSelectionMarkRequest() {
            guard let request = host.commands.selectionMarkRequest else { return }
            host.commands.selectionMarkRequest = nil
            host.onSelectionMark?(request.kind, request.anchor, request.excerpt)
        }

        private func fulfilPendingAnchorRequest() {
            guard let request = host.commands.anchorRequest else { return }
            host.commands.anchorRequest = nil
            guard let live else {
                request(nil)
                return
            }
            live.requestCurrentAnchor { anchor in request(anchor) }
        }

        private func consumePageIndexRequest() {
            guard let target = host.commands.pageIndexRequest, let live, let current,
                  live.chapterIndex == current.address.chapter, !isTransitioning else { return }
            host.commands.pageIndexRequest = nil
            ReaderTelemetry.log("jump.page", ["target": target, "from": current.address])
            let reached = live.setPage(target, animated: false)
            current.address.page = reached
            current.picture = pictures[current.address]?.image
            current.showsPicture = false
            emitPageInfo(chapter: current.address.chapter, page: reached)
            prefetch(around: current.address)
        }

        private func fulfilPendingNavigationAnchor() {
            guard let anchor = host.commands.navigationAnchor, let live, !isTransitioning else { return }
            guard anchor.chapterID == live.content.chapterID else {
                // A jump into a chapter that is neither shown nor being
                // switched to is stale. Left queued, it fired whenever the
                // reader next reached that chapter.
                if host.chapterIndex == live.chapterIndex {
                    ReaderTelemetry.log("anchor.dropped", ["anchorChapter": anchor.chapterID ?? -1])
                    host.commands.navigationAnchor = nil
                }
                return
            }
            host.commands.navigationAnchor = nil
            liveTarget = nil
            current?.showsPicture = false
            live.scroll(to: anchor)
        }

        private func consumeMarksRefresh() -> Bool {
            guard host.commands.marksRefresh != nil else { return false }
            host.commands.marksRefresh = nil
            return true
        }

        private func applyPendingMarks() {
            guard let live else { return }
            let marks = host.commands.lastAppliedMarks
            live.applyMarks(marks)
            renderers[live.chapterIndex]?.applyMarks(marks)
            discardPictures(reason: "marks", chapter: live.chapterIndex)
        }

        // MARK: Whole-book pagination
        //
        // Every chapter is laid out once, in a page that never shows, at the
        // reader's exact size and typography; its page count goes back to the
        // view. One chapter at a time, so it never competes with reading.

        private struct MeasureKey: Equatable {
            let tokens: EPUBReaderStyleTokens
            let size: CGSize
        }

        private var measurement: (chapter: Int, controller: EPUBChapterPageController, key: MeasureKey)?
        private var measuredChapters: (key: MeasureKey, chapters: Set<Int>)?
        private var measurementSettle: Task<Void, Never>?
        private var lastMeasuredCount = 0

        private func continuePagination() {
            guard let stagingView, stagingView.bounds.width > 1, stagingView.bounds.height > 1,
                  let unmeasured = host.paginationIndex?.unmeasured, !unmeasured.isEmpty else { return }
            let key = MeasureKey(tokens: host.styleTokens, size: stagingView.bounds.size)
            if measuredChapters?.key != key { measuredChapters = (key, []) }
            if let measurement, measurement.key != key { cancelMeasurement() }
            guard measurement == nil else { return }
            let skip = measuredChapters?.chapters ?? []
            guard let chapter = unmeasured.first(where: {
                !skip.contains($0) && host.chapterContents[$0] != nil
            }), let controller = makeChapterVC(at: chapter, restoreFraction: 0, role: .measure) else { return }
            controller.view.frame = stagingView.bounds
            stagingView.insertSubview(controller.view, at: 0)
            measurement = (chapter, controller, key)
            lastMeasuredCount = 0
        }

        private func cancelMeasurement() {
            measurementSettle?.cancel()
            measurement?.controller.view.removeFromSuperview()
            measurement = nil
        }

        /// Counts arrive more than once while images and fonts load; the last
        /// one before things go quiet is the answer.
        private func measuringPageReported(pageCount: Int) {
            guard let started = measurement else { return }
            lastMeasuredCount = pageCount
            measurementSettle?.cancel()
            measurementSettle = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled, let self, let measurement = self.measurement,
                      measurement.controller === started.controller else { return }
                let count = max(1, self.lastMeasuredCount)
                ReaderTelemetry.log("pagination.measured", ["chapter": measurement.chapter, "count": count])
                self.measuredChapters?.chapters.insert(measurement.chapter)
                self.cancelMeasurement()
                self.host.onChapterMeasured?(measurement.chapter, count)
                self.continuePagination()
            }
        }
    }
}

#endif

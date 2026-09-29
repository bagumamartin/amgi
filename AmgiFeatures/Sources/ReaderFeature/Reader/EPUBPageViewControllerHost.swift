// `public import` so `ReaderSourceAnchor` in the `onWordTap` signature is
// visible to the macOS twin of this file, which shares the call site.
import AmgiReader
import AmgiTheme
import SwiftUI
#if os(iOS)
import UIKit

/// `UIViewControllerRepresentable` wrapping a `UIPageViewController`
/// (`.scroll`, `.horizontal`). The outer controller animates chapter
/// transitions; each chapter VC owns one `WKWebView` whose internal
/// scroll view handles intra-chapter paging via `isPagingEnabled`.
///
/// Cross-chapter handoff relies on default UIKit gesture arbitration:
/// the inner scroll view yields its pan once at maxOffset, the outer
/// page controller's recogniser takes over for the chapter swipe.
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
    /// Bridge to the live chapter controller, for anchor capture and marks.
    /// Declared last so both hosts share one parameter order and the SwiftUI
    /// call site stays platform-agnostic.
    let commands: ReaderPageCommands

    func makeCoordinator() -> Coordinator {
        Coordinator(host: self)
    }

    @MainActor
    func makeUIViewController(context: Context) -> UIPageViewController {
        let pageVC = UIPageViewController(
            transitionStyle: pageTransition.pageViewControllerStyle,
            navigationOrientation: .horizontal,
            options: nil
        )
        pageVC.dataSource = context.coordinator
        pageVC.delegate = context.coordinator
        pageVC.view.backgroundColor = .clear

        let initial = context.coordinator.makeChapterVC(at: chapterIndex, restoreFraction: pendingRestoreFraction)
        if let initial {
            pageVC.setViewControllers([initial], direction: .forward, animated: false)
            context.coordinator.didInstallInitial = true
        }
        return pageVC
    }

    @MainActor
    func updateUIViewController(_ uiViewController: UIPageViewController, context: Context) {
        context.coordinator.host = self
        context.coordinator.applyStyleTokensToVisibleChapters(in: uiViewController)
        context.coordinator.consumeSelectionRequestIfNeeded(in: uiViewController)
        // Track what is actually on screen before servicing commands, so an
        // anchor request is answered by the chapter the user is reading.
        context.coordinator.trackCurrentController(in: uiViewController)
        context.coordinator.fulfilPendingAnchorRequest()
        context.coordinator.fulfilSelectionMarkRequest()
        if context.coordinator.consumePageTurnRequestIfNeeded(in: uiViewController) {
            return
        }
        // If the host's chapterIndex Binding diverged from what the page
        // controller currently shows (programmatic jump), re-seed.
        if let current = uiViewController.viewControllers?.first as? EPUBChapterPageController,
           current.chapterIndex != chapterIndex {
            if let next = context.coordinator.makeChapterVC(at: chapterIndex, restoreFraction: pendingRestoreFraction) {
                let direction: UIPageViewController.NavigationDirection =
                    chapterIndex > current.chapterIndex ? .forward : .reverse
                uiViewController.setViewControllers(
                    [next],
                    direction: direction,
                    animated: !AmgiMotion.prefersReducedMotion
                )
                context.coordinator.trackCurrentController(in: uiViewController)
            }
        }
        // Marks last, so a chapter switch repaints with the new chapter's
        // annotations rather than the outgoing one's.
        if context.coordinator.consumeMarksRefresh() {
            context.coordinator.applyPendingMarks()
        }
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, UIPageViewControllerDataSource,
                             UIPageViewControllerDelegate, EPUBChapterPageControllerDelegate {
        var host: EPUBPageViewControllerHost
        var didInstallInitial = false
        private var handledPageTurnSequence = 0
        private var handledSelectionRequestID = 0
        /// The chapter controller currently on screen. Tracked here because the
        /// data source may vend an adjacent controller for a swipe that never
        /// completes, so the page view controller's own `viewControllers` is
        /// not a reliable answer to "what is being read".
        private weak var currentController: EPUBChapterPageController?

        init(host: EPUBPageViewControllerHost) {
            self.host = host
        }

        /// Records which chapter controller is on screen so commands are
        /// answered by the right one.
        func trackCurrentController(in pageVC: UIPageViewController) {
            if let current = pageVC.viewControllers?.first as? EPUBChapterPageController {
                if currentController !== current {
                    currentController = current
                }
            }
        }

        /// Whether the view asked for the chapter's marks to be repainted.
        /// One-shot: a refresh is consumed so it does not re-run on every
        /// SwiftUI update.
        func consumeMarksRefresh() -> Bool {
            guard host.commands.marksRefresh != nil else { return false }
            host.commands.marksRefresh = nil
            return true
        }

        /// Re-apply the marks the view last computed. Called on every chapter
        /// change so a highlight drawn in chapter 3 is still there after
        /// leaving and returning to it.
        func applyPendingMarks() {
            guard let currentController,
                  !host.commands.lastAppliedMarks.isEmpty else { return }
            currentController.applyMarks(host.commands.lastAppliedMarks)
        }

        /// Hands a mark requested from the selection menu to the view. One-shot,
        /// so a two-tap highlight cannot be stored twice.
        func fulfilSelectionMarkRequest() {
            guard let request = host.commands.selectionMarkRequest else { return }
            host.commands.selectionMarkRequest = nil
            host.onSelectionMark?(request.kind, request.anchor, request.excerpt)
        }

        /// Fulfils a pending anchor request from the view against the chapter
        /// on screen.
        func fulfilPendingAnchorRequest() {
            guard let request = host.commands.anchorRequest else { return }
            guard let currentController else {
                host.commands.fulfilAnchorRequest(with: nil)
                return
            }
            currentController.requestCurrentAnchor { anchor in
                request(anchor)
            }
        }

        func makeChapterVC(at index: Int, restoreFraction: Double?) -> EPUBChapterPageController? {
            guard index >= 0, index < host.book.chapters.count else { return nil }
            guard let content = host.chapterContents[index] else { return nil }
            let vc = EPUBChapterPageController(
                chapterIndex: index,
                content: content,
                styleTokens: host.styleTokens,
                pendingRestoreFraction: restoreFraction
            )
            vc.pageDelegate = self
            // Highlight and Bookmark from the selection menu are local marks;
            // they bypass the delegate, which is about lookup.
            vc.selectionHighlightHandler = { [commands = host.commands] payload in
                commands.selectionMarkRequest = .init(
                    kind: .highlight,
                    anchor: payload.anchor,
                    excerpt: payload.text
                )
            }
            vc.selectionBookmarkHandler = { [commands = host.commands] payload in
                commands.selectionMarkRequest = .init(
                    kind: .bookmark,
                    anchor: payload.anchor,
                    excerpt: payload.text
                )
            }
            // Resolve marks through the bus rather than the store: the
            // controller is framework-owned and has no path to the profile.
            vc.annotationProvider = { [commands = host.commands] in
                await commands.markProvider?() ?? []
            }
            vc.runningHead = host.runningHead
            // Swipe is the only gesture that turns a page, and it works
            // identically for every transition — including curl, which
            // `UIPageViewController` cannot pan itself.
            vc.onSwipeTurn = { [weak self] direction in
                guard let self,
                      let pageVC = vc.parent as? UIPageViewController
                else { return }
                _ = self.navigate(direction, from: vc, in: pageVC)
            }
            return vc
        }

        func applyStyleTokensToVisibleChapters(in pageVC: UIPageViewController) {
            for vc in pageVC.viewControllers ?? [] {
                if let chapter = vc as? EPUBChapterPageController, chapter.styleTokens != host.styleTokens {
                    chapter.update(styleTokens: host.styleTokens)
                }
            }
        }

        @discardableResult
        func navigate(
            _ direction: EPUBChapterPageController.PageDirection,
            from controller: EPUBChapterPageController,
            in pageVC: UIPageViewController
        ) -> Bool {
            guard host.pagingEnabled, controller.isReadyForPaging else { return false }
            // A turn stays inside the chapter while the chapter has pages to
            // show, and only crosses a boundary at its edge. This is the
            // single place that decision is made, which is what stops a
            // backward turn from landing at the end of the previous chapter.
            if controller.canTurn(direction) {
                turnWithinChapter(direction, on: controller)
                return true
            }
            return crossChapter(direction, from: controller, in: pageVC)
        }

        /// Turns a page inside the current chapter, applying the selected
        /// transition.
        private func turnWithinChapter(
            _ direction: EPUBChapterPageController.PageDirection,
            on controller: EPUBChapterPageController
        ) {
            let forward = direction == .forward
            let from = controller.currentPageIndex
            let to = forward ? from + 1 : from - 1
            let transition = host.pageTransition
            let onDone: () -> Void = {
                controller.setPage(to, animated: false)
                self.emitPageInfo(of: controller)
            }

            switch transition {
            case .scroll, .slide:
                // The document is the page, so these are an eased move of the
                // scroll offset. `slide` is quicker and harder-eased so the
                // two read as different effects rather than one repeated.
                controller.setPage(to, animated: !AmgiMotion.prefersReducedMotion)
                emitPageInfo(of: controller)
            case .fastFade:
                // Snap, then cross-fade a snapshot of the old page out. The
                // document never animates, so the effect is unambiguous.
                let previous = controller.snapshot(ofPage: from)
                onDone()
                guard !AmgiMotion.prefersReducedMotion, let previous,
                      let view = controller.view else { return }
                let overlay = UIImageView(image: previous)
                overlay.frame = view.bounds
                overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                overlay.isUserInteractionEnabled = false
                view.addSubview(overlay)
                UIView.animate(
                    withDuration: ReaderPageTransition.fastFade.duration,
                    animations: { overlay.alpha = 0 },
                    completion: { _ in overlay.removeFromSuperview() }
                )
            case .curl:
                curlFrom(controller, from: from, to: to, forward: forward, in: viewFor(controller))
            }
        }

        private func viewFor(_ controller: EPUBChapterPageController) -> UIView? {
            controller.parent?.view ?? controller.view.superview
        }

        /// A real page curl, using `UIPageViewController`'s own curl over
        /// snapshots of the two pages.
        ///
        /// UIKit can only curl between view controllers, and one controller
        /// here holds a whole chapter rather than a page, so the curl is run
        /// over page images and the document is snapped to the destination
        /// underneath. That is what gives a genuine peel, a matching shadow,
        /// and the same easing as every other Apple reader — rather than a
        /// horizontal nudge wearing curl's name.
        private func curlFrom(
            _ controller: EPUBChapterPageController,
            from: Int,
            to: Int,
            forward: Bool,
            in container: UIView?
        ) {
            guard !AmgiMotion.prefersReducedMotion,
                  let container,
                  let outgoing = controller.snapshot(ofPage: from),
                  let incoming = controller.snapshot(ofPage: to)
            else {
                controller.setPage(to, animated: true)
                emitPageInfo(of: controller)
                return
            }
            withPageCurl(from: outgoing, to: incoming, forward: forward, in: container) {
                controller.setPage(to, animated: false)
                self.emitPageInfo(of: controller)
            }
        }

        /// Runs a one-shot `UIPageViewController(.pageCurl)` between two page
        /// images and tears it down when it settles.
        private func withPageCurl(
            from outgoing: UIImage,
            to incoming: UIImage,
            forward: Bool,
            in container: UIView,
            completion: @escaping () -> Void
        ) {
            let pager = UIPageViewController(
                transitionStyle: .pageCurl,
                navigationOrientation: .horizontal,
                options: nil
            )
            pager.view.frame = container.bounds
            pager.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            pager.view.backgroundColor = .clear
            // The curl reveals the *back* of the turning page, so the page
            // behind it has to be the destination.
            let start = forward ? outgoing : incoming
            let end = forward ? incoming : outgoing
            pager.setViewControllers(
                [ReaderPageImageController(image: start)],
                direction: forward ? .forward : .reverse,
                animated: false
            )
            container.addSubview(pager.view)

            let finish: (Bool) -> Void = { _ in
                completion()
                pager.view.removeFromSuperview()
            }
            pager.dataSource = ReaderPageImagePagerDataSource(
                first: ReaderPageImageController(image: end)
            )
            pager.setViewControllers(
                [ReaderPageImageController(image: end)],
                direction: forward ? .forward : .reverse,
                animated: true,
                completion: finish
            )
            // UIKit's page-curl pan is not interactive here, which is
            // intentional: the swipe is handled by the chapter's own
            // recogniser so that every transition is reachable the same way.
        }

        private func emitPageInfo(of controller: EPUBChapterPageController) {
            // Record what this chapter actually laid out to, so the running
            // page number can be expressed in book-wide pages rather than
            // pages-within-a-chapter.
            if let index = host.paginationIndex {
                var updated = index
                updated.record(chapter: controller.chapterIndex, pageCount: controller.pageCount)
                host.paginationIndex = updated
            }
            controller.refreshPageFurniture()
            host.onPageInfo(controller.currentPageIndex, controller.pageCount)
        }

        /// Moves across a chapter boundary.
        @discardableResult
        private func crossChapter(
            _ direction: EPUBChapterPageController.PageDirection,
            from controller: EPUBChapterPageController,
            in pageVC: UIPageViewController
        ) -> Bool {
            let forward = direction == .forward
            let targetIndex = controller.chapterIndex + (forward ? 1 : -1)
            guard targetIndex >= 0, targetIndex < host.book.chapters.count,
                  let next = makeChapterVC(
                    at: targetIndex,
                    // Entering a chapter forwards starts at its first page;
                    // entering backwards continues at its last, so stepping
                    // back reads as the reverse of stepping forward.
                    restoreFraction: forward ? 0 : 1
                  ) else {
                if forward { host.onReachedEnd() }
                return false
            }
            advance(to: next, direction: direction, in: pageVC, from: controller)
            return true
        }

        /// Performs the chapter change with the user's chosen effect.
        ///
        /// `UIPageViewController` only offers two transition styles, so Fast
        /// Fade and Slide are composed: Fade swaps the controllers without UIKit
        /// animating and crossfades the container itself; Slide disables the
        /// data source (so UIKit's own scroll does not also run) and animates
        /// the two chapter views directly.
        private func advance(
            to next: EPUBChapterPageController,
            direction: EPUBChapterPageController.PageDirection,
            in pageVC: UIPageViewController,
            from current: EPUBChapterPageController
        ) {
            let forward = direction == .forward
            let navigationDirection: UIPageViewController.NavigationDirection = forward ? .forward : .reverse
            let targetIndex = next.chapterIndex
            let finish: (Bool) -> Void = { [weak self] _ in
                self?.host.chapterIndex = targetIndex
            }

            if AmgiMotion.prefersReducedMotion {
                pageVC.setViewControllers([next], direction: navigationDirection, animated: false, completion: finish)
                return
            }

            switch host.pageTransition {
            case .curl, .scroll:
                pageVC.setViewControllers(
                    [next],
                    direction: navigationDirection,
                    animated: true,
                    completion: finish
                )
            case .fastFade:
                // No lateral movement, so UIKit's own animation is replaced by
                // a crossfade of the container. `animated: false` is what makes
                // the swap instantaneous and leaves us something to fade.
                pageVC.setViewControllers(
                    [next],
                    direction: navigationDirection,
                    animated: false,
                    completion: nil
                )
                guard let container = pageVC.view.superview else {
                    finish(true)
                    return
                }
                UIView.transition(
                    with: container,
                    duration: ReaderPageTransition.fastFade.duration,
                    options: [.transitionCrossDissolve, .beginFromCurrentState],
                    animations: nil
                ) { _ in
                    finish(true)
                }
            case .slide:
                slide(
                    to: next,
                    forward: forward,
                    in: pageVC,
                    from: current,
                    completion: finish
                )
            }
        }

        /// Apple's "Slide": the outgoing page slides left a little while the
        /// incoming page slides in from the edge, with no shadow between them.
        private func slide(
            to next: EPUBChapterPageController,
            forward: Bool,
            in pageVC: UIPageViewController,
            from current: EPUBChapterPageController,
            completion: @escaping (Bool) -> Void
        ) {
            // The data source would fight the manual animation with a scroll
            // transition, so it is suspended for the duration.
            let wasDataSourceEnabled = host.pagingEnabled
            pageVC.dataSource = nil
            pageVC.setViewControllers([next], direction: forward ? .forward : .reverse, animated: false)
            host.chapterIndex = next.chapterIndex
            guard wasDataSourceEnabled else {
                completion(true)
                return
            }

            let container = next.view
            guard let superview = container?.superview else {
                completion(true)
                return
            }
            let width = superview.bounds.width
            container?.frame = superview.bounds
            container?.transform = CGAffineTransform(
                translationX: forward ? width : -width,
                y: 0
            )
            current.view?.transform = CGAffineTransform(
                translationX: forward ? -width * 0.28 : width * 0.28,
                y: 0
            )
            UIView.animate(
                withDuration: ReaderPageTransition.slide.duration,
                delay: 0,
                options: [.curveEaseOut, .beginFromCurrentState]
            ) {
                container?.transform = .identity
                current.view?.transform = .identity
            } completion: { _ in
                current.view?.transform = .identity
                completion(true)
            }
        }

        @discardableResult
        func consumePageTurnRequestIfNeeded(in pageVC: UIPageViewController) -> Bool {
            guard let request = host.pageTurnRequest,
                  request.sequence > handledPageTurnSequence,
                  let current = pageVC.viewControllers?.first as? EPUBChapterPageController,
                  current.isReadyForPaging else { return false }
            handledPageTurnSequence = request.sequence
            return navigate(
                request.direction == .forward ? .forward : .backward,
                from: current,
                in: pageVC
            )
        }

        func consumeSelectionRequestIfNeeded(in pageVC: UIPageViewController) {
            guard host.selectionRequestID > handledSelectionRequestID else { return }
            handledSelectionRequestID = host.selectionRequestID
            (pageVC.viewControllers?.first as? EPUBChapterPageController)?
                .requestSelectionForNote()
        }

        // MARK: UIPageViewControllerDataSource
        //
        // Deliberately empty.
        //
        // This used to vend the adjacent chapter, which is what made the
        // reader feel like it was jumping around: UIKit would pre-load a
        // neighbouring chapter and, with `.pageCurl` in play, the ordering
        // between that and the chapter's own scroll offset was unpredictable.
        // Every turn now goes through `navigate`, which decides
        // intra-chapter vs. chapter-boundary from the page index alone, so
        // there is nothing for UIKit to pre-load and nothing to race.
        //
        // Vending nothing also means the pager no longer has an interactive
        // pan of its own, which is what was leaving a curl-mode user with no
        // way to go back.

        func pageViewController(
            _ pageViewController: UIPageViewController,
            viewControllerBefore viewController: UIViewController
        ) -> UIViewController? {
            nil
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            viewControllerAfter viewController: UIViewController
        ) -> UIViewController? {
            nil
        }

        // MARK: UIPageViewControllerDelegate

        func pageViewController(
            _ pageViewController: UIPageViewController,
            didFinishAnimating finished: Bool,
            previousViewControllers: [UIViewController],
            transitionCompleted completed: Bool
        ) {
            guard completed,
                  let current = pageViewController.viewControllers?.first as? EPUBChapterPageController
            else { return }
            if host.chapterIndex != current.chapterIndex {
                host.chapterIndex = current.chapterIndex
            }
        }

        // MARK: EPUBChapterPageControllerDelegate

        func epubChapter(
            _ controller: EPUBChapterPageController,
            didReportPageInfoIndex pageIndex: Int,
            pageCount: Int
        ) {
            // Only forward updates from the currently-visible chapter so
            // prefetched VCs don't clobber the page strip.
            guard controller.chapterIndex == host.chapterIndex else { return }
            host.onPageInfo(pageIndex, pageCount)
            // No navigation is started from here. This fires on every scroll
            // settle, so consuming a queued page-turn request from inside it
            // could turn the page *and* re-enter the transition that was
            // already running — which is how the reader ended up jumping
            // between chapters. Turns are serviced once per SwiftUI update in
            // `updateUIViewController` instead.
        }

        func epubChapter(
            _ controller: EPUBChapterPageController,
            didReportProgressFraction fraction: Double,
            pageIndex: Int
        ) {
            guard controller.chapterIndex == host.chapterIndex else { return }
            host.onProgress(fraction, pageIndex)
        }

        func epubChapter(
            _ controller: EPUBChapterPageController,
            didSelectText text: String,
            token: String,
            sentence: String,
            anchor: ReaderSourceAnchor?
        ) {
            // Reached only when the user picks Look Up or Add Note from the
            // selection menu, never from the long press itself.
            host.onSelectionForNote(token)
        }

        func epubChapter(
            _ controller: EPUBChapterPageController,
            didTapWord token: String,
            sentence: String,
            anchor: ReaderSourceAnchor?
        ) {
            host.onWordTap(token, sentence, anchor)
        }

        func epubChapter(
            _ controller: EPUBChapterPageController,
            didSelectTextForNote text: String
        ) {
            host.onSelectionForNote(text)
        }

        func epubChapterDidTapEmptySpace(
            _ controller: EPUBChapterPageController,
            atRelativeX relativeX: CGFloat
        ) {
            // Edge-tap zones: left/right 15% page and cross chapter without
            // waiting for a swipe. Outside that, toggle chrome. There is no
            // competing native tap recognizer: empty and token taps are
            // dispatched mutually exclusively by the injected document script.
            let leftEdge: CGFloat = 0.15
            let rightEdge: CGFloat = 0.85
            if relativeX <= leftEdge {
                guard let pageVC = controller.parent as? UIPageViewController else { return }
                navigate(.backward, from: controller, in: pageVC)
            } else if relativeX >= rightEdge {
                guard let pageVC = controller.parent as? UIPageViewController else { return }
                navigate(.forward, from: controller, in: pageVC)
            } else {
                host.onTapEmpty(relativeX)
            }
        }
    }
}

#endif

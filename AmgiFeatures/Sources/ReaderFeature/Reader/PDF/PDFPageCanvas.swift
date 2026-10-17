import AmgiReader
import AmgiReaderPDF
import PDFKit
import SwiftUI

#if canImport(UIKit) && !os(macOS)
import UIKit
#endif

/// Keeps `PDFView` in step with `PDFReaderNavigation`.
@MainActor
@Observable
final class PDFViewCoordinator: NSObject {
    private var navigation: PDFReaderNavigation
    private var isApplyingModelChange = false
    private(set) weak var view: PDFView?
    private var isScrubberActive = false
    private var hasUserZoom = false
    private var savedUserScale: CGFloat = 1
    private var appliedRotationQuarterTurns = 0
    private var didInitialFit = false
    private weak var configuredDocument: PDFDocument?
    private var pendingProgrammaticPageIndex: Int?

    var onPageChanged: ((Int) -> Void)?
    var onSearchResultsChanged: ((Int) -> Void)?
    var onSelectionChanged: ((PDFSelectionContext?) -> Void)?
    var onTapCenter: (() -> Void)?
    var onTapPrevPage: (() -> Void)?
    var onTapNextPage: (() -> Void)?
    /// A tap landed on a capture mark: its id, kind (`card`, `cardDraft`),
    /// and where, in window coordinates.
    var onCaptureMarkTap: ((_ id: String, _ kind: String, _ point: CGPoint) -> Void)?

    var contextProvider: ((
        _ source: PDFSelectionContext.Source,
        _ draggedRect: PDFNormalizedRect?
    ) -> PDFSelectionContext?)?

    private var savedSelection: PDFSelection?

    /// The reader's items for the system selection menu, built for the
    /// selection as it is when the menu opens. Set by the reader view, which
    /// owns the card session and the annotation model.
    @ObservationIgnored var selectionMenu: (() -> (entries: [ReaderSelectionMenuEntry], actions: ReaderSelectionMenuActions)?)?

    /// Clears the text selection, which also dismisses the system menu.
    func clearSelection() {
        view?.clearSelection()
        savedSelection = nil
    }

    init(navigation: PDFReaderNavigation) {
        self.navigation = navigation
    }

    func attach(_ view: PDFView) {
        if self.view === view { return }
        detach()
        self.view = view
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(pageChanged),
            name: .PDFViewPageChanged,
            object: view
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(selectionChanged),
            name: .PDFViewSelectionChanged,
            object: view
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scaleChanged),
            name: .PDFViewScaleChanged,
            object: view
        )
        didInitialFit = false
    }

    func detach() {
        NotificationCenter.default.removeObserver(self, name: .PDFViewPageChanged, object: view)
        NotificationCenter.default.removeObserver(self, name: .PDFViewSelectionChanged, object: view)
        NotificationCenter.default.removeObserver(self, name: .PDFViewScaleChanged, object: view)
        view = nil
        savedSelection = nil
    }

    @objc private func selectionChanged() {
        onSearchResultsChanged?(view?.highlightedSelections?.count ?? 0)
        savedSelection = view?.currentSelection
        onSelectionChanged?(contextProvider?(.textSelection, nil))
    }

    @objc private func pageChanged() {
        guard !isApplyingModelChange else { return }
        guard let view, let page = view.currentPage else { return }
        let index = view.document?.index(for: page) ?? 0
        // A delayed page notification can arrive after a later drag sample.
        // Keep the scrubber's current target authoritative for the full drag.
        if isScrubberActive { return }
        if let pendingProgrammaticPageIndex {
            self.pendingProgrammaticPageIndex = nil
            if index == pendingProgrammaticPageIndex { return }
        }
        // Refit a completed page turn in paged mode, but never change scale
        // under a continuous scroll gesture: that changes the scroll geometry
        // while PDFKit is deciding which page is current.
        if navigation.transition != .continuous {
            if hasUserZoom {
                applyUserScale(to: view, scale: savedUserScale)
            } else {
                applyFit(to: view)
            }
        }
        onPageChanged?(index)
    }

    @objc private func scaleChanged() {
        guard !isApplyingModelChange, let view else { return }
        hasUserZoom = true
        savedUserScale = view.scaleFactor
    }

    func setScrubberActive(_ active: Bool) {
        isScrubberActive = active
    }

    /// The window changed size. Refit only while the reader is in its initial
    /// fit mode; a user zoom remains their chosen magnification.
    func layoutChanged() {
        guard let view else { return }
        if hasUserZoom {
            applyUserScale(to: view, scale: savedUserScale)
        } else if !didInitialFit, view.bounds.width > 0 {
            applyFit(to: view)
            didInitialFit = true
        } else {
            // A resize keeps the reader where it was rather than jumping a
            // long page back to its top.
            applyFit(to: view, scrollToTop: false)
        }
    }

    func zoom(by factor: CGFloat) {
        guard let view else { return }
        let scale = min(max(view.scaleFactor * factor, view.minScaleFactor), view.maxScaleFactor)
        hasUserZoom = true
        savedUserScale = scale
        applyUserScale(to: view, scale: scale)
    }

    func useActualSize() {
        guard let view else { return }
        hasUserZoom = true
        savedUserScale = 1
        applyUserScale(to: view, scale: 1)
    }

    func fitToWindow() {
        guard let view else { return }
        hasUserZoom = false
        applyFit(to: view)
    }

    func restoreSelection() {
        guard let view, let saved = savedSelection else { return }
        view.setCurrentSelection(saved, animate: false)
    }

    /// An area of a page, from a box drawn over the view, rendered from the
    /// page itself — crisp at any zoom, unlike a screenshot — with the page
    /// and the box's place on it as its anchor.
    func regionCapture(viewRect: CGRect, bookID: String) -> ReaderRegionCapture? {
        guard let view, let document = view.document,
              let page = view.page(for: CGPoint(x: viewRect.midX, y: viewRect.midY), nearest: true) else { return nil }
        let box = page.bounds(for: .mediaBox)
        let onPage = view.convert(viewRect, to: page).intersection(box)
        guard !onPage.isNull, onPage.width >= 2, onPage.height >= 2,
              let normalised = PDFRegionCapture.normalizedRect(from: onPage, on: page) else { return nil }
        // The page draws its annotations into the crop, and the reader's own
        // capture marks are annotations: lift them off for the draw, so a
        // picture never carries the box or highlight of an earlier capture.
        let marks = page.annotations.filter { PDFCaptureMarks.parse($0.userName) != nil }
        marks.forEach(page.removeAnnotation)
        let png = PDFRegionCapture.capture(page: page, rect: normalised)
        marks.forEach(page.addAnnotation)
        guard let png else { return nil }
        let index = document.index(for: page)
        let text = ReaderSourceAnchor.normalize(page.selection(for: onPage)?.string ?? "")
        return ReaderRegionCapture(
            image: png,
            anchor: ReaderSourceAnchor(bookID: bookID, cfi: index, quote: text),
            region: ReaderPageRegion(
                page: index,
                x: (onPage.minX - box.minX) / box.width,
                y: (box.maxY - onPage.maxY) / box.height,
                width: onPage.width / box.width,
                height: onPage.height / box.height
            )
        )
    }

    func pageRect(for viewRect: CGRect) -> (rect: PDFNormalizedRect, pageIndex: Int)? {
        guard let view, let page = view.currentPage,
              let document = view.document else { return nil }
        let index = document.index(for: page)
        let pageRect = view.convert(viewRect, to: page)
        guard let normalised = PDFRegionCapture.normalizedRect(from: pageRect, on: page)
        else { return nil }
        return (normalised, index)
    }

    func selectionContext(
        source: PDFSelectionContext.Source,
        draggedRect: PDFNormalizedRect?,
        details: PDFSelectionContext.Details
    ) -> PDFSelectionContext? {
        // A text selection is on its own page, which in a continuous scroll
        // or a two-up spread need not be the one PDFKit calls current.
        let selectionPage = source == .textSelection ? view?.currentSelection?.pages.first : nil
        guard let view, let page = selectionPage ?? view.currentPage, let document = view.document else {
            return nil
        }
        let index = document.index(for: page)
        let label = details.pageLabel(index)

        switch source {
        case .textSelection:
            guard let selection = view.currentSelection,
                  let quote = selection.string, !quote.isEmpty
            else { return nil }
            let lines = selection.selectionsByLine()
            let bounds = lines.reduce(CGRect.null) { $0.union($1.bounds(for: page)) }
            guard !bounds.isNull,
                  let rect = PDFRegionCapture.normalizedRect(from: bounds, on: page)
            else { return nil }
            let neighbours = Self.neighbouringText(quote: quote, on: page)
            return PDFSelectionContext(
                text: quote,
                anchor: PDFSourceAnchor(
                    bookID: details.bookID,
                    pageIndex: index,
                    pageLabel: label,
                    rect: rect,
                    quote: quote,
                    contextBefore: neighbours.before,
                    contextAfter: neighbours.after,
                    documentFingerprint: details.documentFingerprint
                ),
                regionRect: rect,
                pageBounds: bounds,
                pageIndex: index,
                pageLabel: label,
                source: source
            )
        case .region(let dragRect):
            return PDFSelectionContext(
                text: "",
                anchor: PDFSourceAnchor(
                    bookID: details.bookID,
                    pageIndex: index,
                    pageLabel: label,
                    rect: draggedRect ?? dragRect,
                    quote: "",
                    documentFingerprint: details.documentFingerprint
                ),
                regionRect: draggedRect ?? dragRect,
                pageBounds: nil,
                pageIndex: index,
                pageLabel: label,
                source: source
            )
        }
    }

    private static func neighbouringText(
        quote: String,
        on page: PDFPage
    ) -> (before: String?, after: String?) {
        guard let pageText = page.string,
              let range = pageText.range(of: quote)
        else { return (nil, nil) }
        let count = PDFSourceAnchor.contextCharacterCount
        let before = pageText[pageText.startIndex..<range.lowerBound]
        let after = pageText[range.upperBound...]
        return (
            String(before.suffix(count)).isEmpty ? nil : String(before.suffix(count)),
            String(after.prefix(count)).isEmpty ? nil : String(after.prefix(count))
        )
    }

    /// Applies the navigation state to the view.
    func apply(_ navigation: PDFReaderNavigation) {
        self.navigation = navigation
        guard let view, let document = view.document else { return }
        if configuredDocument !== document {
            configuredDocument = document
            pendingProgrammaticPageIndex = nil
            appliedRotationQuarterTurns = 0
            hasUserZoom = false
            savedUserScale = 1
            didInitialFit = false
        }
        let wantedMode = Self.displayMode(for: navigation.transition)
        #if os(iOS)
        let wantsPageViewController = navigation.transition != .continuous
        if view.isUsingPageViewController != wantsPageViewController {
            let options: [UIPageViewController.OptionsKey: Any] = [.interPageSpacing: 10]
            view.usePageViewController(wantsPageViewController, withViewOptions: options)
        }
        #endif

        if view.displayMode != wantedMode {
            view.displayMode = wantedMode
        }

        let wantedDirection: PDFDisplayDirection = (navigation.isTwoUp || navigation.transition != .continuous) ? .horizontal : .vertical
        if view.displayDirection != wantedDirection {
            view.displayDirection = wantedDirection
        }
        if view.displaysAsBook != navigation.isTwoUp {
            view.displaysAsBook = navigation.isTwoUp
        }
        if navigation.isTwoUp, view.pageBreakMargins.top != 0 {
            view.pageBreakMargins = .init(top: 0, left: 0, bottom: 0, right: 0)
        }

        if navigation.rotationQuarterTurns != appliedRotationQuarterTurns {
            let delta = navigation.rotationQuarterTurns - appliedRotationQuarterTurns
            isApplyingModelChange = true
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index) else { continue }
                page.rotation = (page.rotation + delta * 90 + 360) % 360
            }
            appliedRotationQuarterTurns = navigation.rotationQuarterTurns
            isApplyingModelChange = false
            didInitialFit = false
        }

        let visiblePageIndex = view.currentPage.map { document.index(for: $0) } ?? -1
        if visiblePageIndex != navigation.pageIndex,
           let target = document.page(at: navigation.pageIndex) {
            isApplyingModelChange = true
            pendingProgrammaticPageIndex = navigation.pageIndex
            view.go(to: target)
            isApplyingModelChange = false
        }

        // The first fit waits for a real width: a view not laid out yet
        // cannot tell a tall page from an ordinary one, and `layoutChanged`
        // finishes the job once it can.
        if !didInitialFit, view.bounds.width > 0 {
            applyFit(to: view)
            didInitialFit = true
        }
    }

    func go(toPageIndex index: Int) {
        guard let view, let document = view.document,
              let page = document.page(at: index) else { return }
        guard document.index(for: view.currentPage ?? page) != index else { return }
        isApplyingModelChange = true
        pendingProgrammaticPageIndex = index
        defer { isApplyingModelChange = false }
        view.go(to: page)
    }

    @discardableResult
    func search(_ term: String?) -> Int {
        guard let view, let document = view.document else { return 0 }
        guard let term, !term.isEmpty else {
            view.highlightedSelections = nil
            onSearchResultsChanged?(0)
            return 0
        }
        let selections = document.findString(term, withOptions: [.caseInsensitive])
        view.highlightedSelections = selections
        if let first = selections.first {
            isApplyingModelChange = true
            view.setCurrentSelection(first, animate: true)
            if let page = first.pages.first {
                pendingProgrammaticPageIndex = document.index(for: page)
            }
            view.go(to: first)
            isApplyingModelChange = false
            if let page = first.pages.first {
                let index = document.index(for: page)
                onPageChanged?(index)
            }
        }
        onSearchResultsChanged?(selections.count)
        return selections.count
    }

    func stepSearchResult(by delta: Int) {
        guard let view, let selections = view.highlightedSelections, !selections.isEmpty
        else { return }
        guard let current = view.currentSelection,
              let index = selections.firstIndex(of: current)
        else {
            goToSearchResult(at: delta > 0 ? 0 : selections.count - 1, in: selections)
            return
        }
        let next = (index + delta + selections.count) % selections.count
        goToSearchResult(at: next, in: selections)
    }

    private func goToSearchResult(at index: Int, in selections: [PDFSelection]) {
        guard let view, selections.indices.contains(index) else { return }
        isApplyingModelChange = true
        view.setCurrentSelection(selections[index], animate: true)
        if let page = selections[index].pages.first, let document = view.document {
            pendingProgrammaticPageIndex = document.index(for: page)
        }
        view.go(to: selections[index])
        isApplyingModelChange = false
        if let document = view.document, let page = selections[index].pages.first {
            onPageChanged?(document.index(for: page))
        }
    }

    /// The reader's resting zoom. Ordinary pages fit whole. A page much
    /// taller than the view — a stitched screenshot, a web capture, a
    /// continuous export — would shrink to an unreadable strip that way, so
    /// it fits the view's width instead and starts at its top, the way a
    /// browser shows a long page.
    private func applyFit(to view: PDFView, scrollToTop: Bool = true) {
        isApplyingModelChange = true
        view.minScaleFactor = 0.25
        view.maxScaleFactor = 5.0
        view.autoScales = false
        let fit = view.scaleFactorForSizeToFit
        if let page = view.currentPage ?? view.document?.page(at: navigation.pageIndex),
           let widthFit = Self.widthFitScale(for: page, in: view, pageFit: fit) {
            view.scaleFactor = widthFit
            if scrollToTop {
                let bounds = page.bounds(for: view.displayBox)
                view.go(to: PDFDestination(page: page, at: CGPoint(x: bounds.minX, y: bounds.maxY)))
            }
        } else if fit > 0 {
            view.scaleFactor = fit
        }
        isApplyingModelChange = false
    }

    /// The scale that makes `page` span the view's width, when fitting the
    /// whole page would leave it narrower than 70% of the view; nil for
    /// pages that fit well whole.
    static func widthFitScale(for page: PDFPage, in view: PDFView, pageFit: CGFloat) -> CGFloat? {
        var size = page.bounds(for: view.displayBox).size
        if abs(page.rotation) % 180 == 90 { size = CGSize(width: size.height, height: size.width) }
        let viewWidth = view.bounds.width
        guard size.width > 0, viewWidth > 0, pageFit > 0 else { return nil }
        guard size.width * pageFit < viewWidth * 0.7 else { return nil }
        return min(viewWidth / size.width, view.maxScaleFactor)
    }

    private func applyUserScale(to view: PDFView, scale: CGFloat) {
        isApplyingModelChange = true
        view.minScaleFactor = 0.25
        view.maxScaleFactor = 5.0
        view.autoScales = false
        view.scaleFactor = min(max(scale, view.minScaleFactor), view.maxScaleFactor)
        isApplyingModelChange = false
    }

    private static func displayMode(for transition: PDFReaderNavigation.Transition) -> PDFDisplayMode {
        switch transition {
        case .scroll, .pageCurl: .singlePage
        case .continuous: .singlePageContinuous
        }
    }

    #if os(iOS)
    @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard let view else { return }
        // A tap away from a selection dismisses it, as it does everywhere
        // else in the system. This recogniser wins over PDFKit's own
        // tap-to-deselect, so it has to do that itself; returning early here
        // left the selection and its menu up no matter where you tapped.
        if view.currentSelection != nil {
            clearSelection()
            onSelectionChanged?(nil)
            return
        }
        let point = recognizer.location(in: view)
        // A capture mark opens its card, or brings its draft forward.
        if let page = view.page(for: point, nearest: false),
           let mark = PDFCaptureMarks.parse(page.annotation(at: view.convert(point, to: page))?.userName) {
            onCaptureMarkTap?(mark.id, mark.kind, view.convert(point, to: nil))
            return
        }
        let width = view.bounds.width
        if navigation.transition != .continuous {
            if point.x < width * 0.18 {
                onTapPrevPage?()
                return
            } else if point.x > width * 0.82 {
                onTapNextPage?()
                return
            }
        }
        onTapCenter?()
    }

    @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        guard let view else { return }
        let pageFit = view.scaleFactorForSizeToFit
        let fit = view.currentPage
            .flatMap { Self.widthFitScale(for: $0, in: view, pageFit: pageFit) } ?? pageFit
        let target = (view.scaleFactor > fit * 1.2) ? fit : min(fit * 2.2, view.maxScaleFactor)
        UIView.animate(withDuration: 0.25) {
            view.scaleFactor = target
        }
        hasUserZoom = target > fit * 1.05
        savedUserScale = target
    }
    #endif
}

/// A region the user is dragging out, not yet an annotation.
struct PDFDraftRegion: Equatable {
    var start: CGPoint
    var current: CGPoint

    var rect: CGRect {
        CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
    }

    var isMeaningful: Bool {
        rect.width >= 4 && rect.height >= 4
    }
}

/// The `PDFView` itself with gesture support and theme styling.
struct PDFPageCanvas: View {
    let model: PDFReaderModel
    let navigation: PDFReaderNavigation
    let coordinator: PDFViewCoordinator
    let searchTerm: String?
    var theme: ReaderTypographyPreferences.Theme = .default
    let onPageChanged: (Int) -> Void
    let onSearchResultsChanged: (Int) -> Void
    var onStepSearchResult: ((Int) -> Void)?
    var onSelectionChanged: ((PDFSelectionContext?) -> Void)?
    var onTapCenter: (() -> Void)? = nil
    var onTapPrevPage: (() -> Void)? = nil
    var onTapNextPage: (() -> Void)? = nil

    var body: some View {
        PlatformCanvas(
            model: model,
            navigation: navigation,
            coordinator: coordinator,
            searchTerm: searchTerm,
            theme: theme,
            onPageChanged: onPageChanged,
            onSearchResultsChanged: onSearchResultsChanged,
            onSelectionChanged: onSelectionChanged ?? { _ in },
            onTapCenter: onTapCenter,
            onTapPrevPage: onTapPrevPage,
            onTapNextPage: onTapNextPage
        )
    }
}

#if canImport(UIKit) && !os(macOS)
@MainActor
private struct PlatformCanvas: UIViewRepresentable {
    let model: PDFReaderModel
    let navigation: PDFReaderNavigation
    let coordinator: PDFViewCoordinator
    let searchTerm: String?
    let theme: ReaderTypographyPreferences.Theme
    let onPageChanged: (Int) -> Void
    let onSearchResultsChanged: (Int) -> Void
    let onSelectionChanged: (PDFSelectionContext?) -> Void
    let onTapCenter: (() -> Void)?
    let onTapPrevPage: (() -> Void)?
    let onTapNextPage: (() -> Void)?

    func makeCoordinator() -> PDFViewCoordinator {
        coordinator.onTapCenter = onTapCenter
        coordinator.onTapPrevPage = onTapPrevPage
        coordinator.onTapNextPage = onTapNextPage
        return coordinator
    }

    func makeUIView(context: Context) -> PDFView {
        let view = PDFPageCanvasSupport.configure(
            context.coordinator,
            model: model,
            navigation: navigation,
            theme: theme
        )
        let coordinator = context.coordinator
        let singleTap = UITapGestureRecognizer(target: coordinator, action: #selector(PDFViewCoordinator.handleTap(_:)))
        singleTap.numberOfTapsRequired = 1
        let doubleTap = UITapGestureRecognizer(target: coordinator, action: #selector(PDFViewCoordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        singleTap.require(toFail: doubleTap)
        view.addGestureRecognizer(singleTap)
        view.addGestureRecognizer(doubleTap)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        context.coordinator.onTapCenter = onTapCenter
        context.coordinator.onTapPrevPage = onTapPrevPage
        context.coordinator.onTapNextPage = onTapNextPage
        PDFPageCanvasSupport.refresh(
            context.coordinator, view: view, model: model,
            navigation: navigation, theme: theme,
            onPageChanged: onPageChanged,
            onSearchResultsChanged: onSearchResultsChanged,
            onSelectionChanged: onSelectionChanged
        )
    }

    static func dismantleUIView(_ view: PDFView, coordinator: PDFViewCoordinator) {
        coordinator.detach()
    }
}
#else
@MainActor
private struct PlatformCanvas: NSViewRepresentable {
    let model: PDFReaderModel
    let navigation: PDFReaderNavigation
    let coordinator: PDFViewCoordinator
    let searchTerm: String?
    let theme: ReaderTypographyPreferences.Theme
    let onPageChanged: (Int) -> Void
    let onSearchResultsChanged: (Int) -> Void
    let onSelectionChanged: (PDFSelectionContext?) -> Void
    let onTapCenter: (() -> Void)?
    let onTapPrevPage: (() -> Void)?
    let onTapNextPage: (() -> Void)?

    func makeCoordinator() -> PDFViewCoordinator {
        coordinator.onTapCenter = onTapCenter
        coordinator.onTapPrevPage = onTapPrevPage
        coordinator.onTapNextPage = onTapNextPage
        return coordinator
    }

    func makeNSView(context: Context) -> PDFView {
        PDFPageCanvasSupport.configure(
            context.coordinator,
            model: model,
            navigation: navigation,
            theme: theme
        )
    }

    func updateNSView(_ view: PDFView, context: Context) {
        context.coordinator.onTapCenter = onTapCenter
        context.coordinator.onTapPrevPage = onTapPrevPage
        context.coordinator.onTapNextPage = onTapNextPage
        PDFPageCanvasSupport.refresh(
            context.coordinator, view: view, model: model,
            navigation: navigation, theme: theme,
            onPageChanged: onPageChanged,
            onSearchResultsChanged: onSearchResultsChanged,
            onSelectionChanged: onSelectionChanged
        )
    }

    static func dismantleNSView(_ view: PDFView, coordinator: PDFViewCoordinator) {
        coordinator.detach()
    }
}
#endif

@MainActor
enum PDFPageCanvasSupport {
    static func pageBackgroundColour(for theme: ReaderTypographyPreferences.Theme) -> PlatformColor {
        #if canImport(UIKit) && !os(macOS)
        switch theme {
        case .default: return UIColor(red: 0.98, green: 0.97, blue: 0.95, alpha: 1.0)
        case .sepia: return UIColor(red: 0.96, green: 0.93, blue: 0.85, alpha: 1.0)
        case .dark: return UIColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1.0)
        }
        #else
        switch theme {
        case .default: return NSColor(calibratedWhite: 0.15, alpha: 1.0)
        case .sepia: return NSColor(red: 0.96, green: 0.93, blue: 0.85, alpha: 1.0)
        case .dark: return NSColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1.0)
        }
        #endif
    }

    static func configure(
        _ coordinator: PDFViewCoordinator,
        model: PDFReaderModel,
        navigation: PDFReaderNavigation,
        theme: ReaderTypographyPreferences.Theme
    ) -> PDFView {
        let view = ReaderPDFView()
        view.onWidthChange = { [weak coordinator] in coordinator?.layoutChanged() }
        view.menuSource = coordinator
        view.autoScales = true
        view.minScaleFactor = 0.25
        view.maxScaleFactor = 5.0
        view.displayBox = .mediaBox
        view.backgroundColor = PDFPageCanvasSupport.pageBackgroundColour(for: theme)
        view.document = model.document
        coordinator.attach(view)
        coordinator.apply(navigation)
        return view
    }

    static func refresh(
        _ coordinator: PDFViewCoordinator,
        view: PDFView,
        model: PDFReaderModel,
        navigation: PDFReaderNavigation,
        theme: ReaderTypographyPreferences.Theme,
        onPageChanged: @escaping (Int) -> Void,
        onSearchResultsChanged: @escaping (Int) -> Void,
        onSelectionChanged: @escaping (PDFSelectionContext?) -> Void
    ) {
        if view.document !== model.document {
            view.document = model.document
        }
        view.backgroundColor = PDFPageCanvasSupport.pageBackgroundColour(for: theme)
        coordinator.onPageChanged = onPageChanged
        coordinator.onSearchResultsChanged = onSearchResultsChanged
        coordinator.onSelectionChanged = onSelectionChanged
        coordinator.contextProvider = { source, draggedRect in
            coordinator.selectionContext(
                source: source,
                draggedRect: draggedRect,
                details: PDFSelectionContext.Details(
                    bookID: model.book.id,
                    documentFingerprint: model.descriptor?.documentFingerprint ?? "",
                    pageLabel: { index in
                        MainActor.assumeIsolated { model.label(forPage: index) }
                    }
                )
            )
        }
        coordinator.apply(navigation)
    }
}

/// A `PDFView` that reports when its width changes. The resting zoom depends
/// on the width (a tall page fits it), and the first real width arrives in
/// layout — after `configure` ran against a zero-sized view — so this is
/// what makes the very first fit happen at all, on every platform.
final class ReaderPDFView: PDFView {
    var onWidthChange: (() -> Void)?
    /// Supplies the reader's items for PDFKit's own selection menu, the same
    /// way `ReaderWebView` does for WebKit's. One menu at the selection; no
    /// separate bar for the waiting card to cover.
    weak var menuSource: PDFViewCoordinator?
    private var lastWidth: CGFloat = 0

    #if canImport(UIKit) && !os(macOS)
    override func buildMenu(with builder: any UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard let menu = menuSource?.selectionMenu?() else { return }
        ReaderSystemSelectionMenu.merge(
            ReaderSystemSelectionMenu.elements(for: menu.entries, actions: menu.actions),
            into: builder
        )
    }
    #else
    override func menu(for event: NSEvent) -> NSMenu? {
        let base = super.menu(for: event)
        guard let menu = menuSource?.selectionMenu?() else { return base }
        let merged = base ?? NSMenu()
        ReaderSystemSelectionMenu.merge(menu.entries, actions: menu.actions, into: merged)
        return merged
    }
    #endif

    #if canImport(UIKit) && !os(macOS)
    override func layoutSubviews() {
        super.layoutSubviews()
        reportWidthChange()
    }
    #else
    override func layout() {
        super.layout()
        reportWidthChange()
    }
    #endif

    private func reportWidthChange() {
        guard bounds.width != lastWidth else { return }
        lastWidth = bounds.width
        onWidthChange?()
    }
}


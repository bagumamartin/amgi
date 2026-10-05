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

    var contextProvider: ((
        _ source: PDFSelectionContext.Source,
        _ draggedRect: PDFNormalizedRect?
    ) -> PDFSelectionContext?)?

    private var savedSelection: PDFSelection?

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
        } else {
            applyFit(to: view)
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
        guard let view, let page = view.currentPage, let document = view.document else {
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

        if !didInitialFit {
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

    private func applyFit(to view: PDFView) {
        isApplyingModelChange = true
        view.minScaleFactor = 0.25
        view.maxScaleFactor = 5.0
        view.autoScales = false
        let fit = view.scaleFactorForSizeToFit
        if fit > 0 {
            view.scaleFactor = fit
        }
        isApplyingModelChange = false
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
        if view.currentSelection != nil { return }
        let point = recognizer.location(in: view)
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
        let fit = view.scaleFactorForSizeToFit
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
        let view = PDFView()
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

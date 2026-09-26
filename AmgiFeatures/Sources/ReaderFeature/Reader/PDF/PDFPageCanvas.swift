import AmgiReaderPDF
import PDFKit
import SwiftUI

/// Keeps `PDFView` in step with `PDFReaderNavigation`.
///
/// The direction of synchronisation matters, and is the whole reason this is a
/// coordinator rather than a plain binding. Two flows exist:
///
/// - **Model → view**: the user tapped a thumbnail, an outline row, a search hit
///   or a page number. `navigation` has already changed and this asks the view
///   to go there.
/// - **View → model**: the user scrolled, swiped, or used a hardware control.
///   `PDFView` has already moved and this reports where.
///
/// Collapsing the two into one "did it change?" check produces a feedback loop:
/// the view moves, the model is told, the model tells the view to move, and
/// `PDFView` scrolls again. The `isApplyingModelChange` guard is not an
/// optimisation — without it the reader fights itself, and the symptom is a page
/// that jumps on every turn.
@MainActor
@Observable
final class PDFViewCoordinator: NSObject {
    private var navigation: PDFReaderNavigation
    private var isApplyingModelChange = false
    private weak var view: PDFView?

    /// Called when the view reports a new current page.
    var onPageChanged: ((Int) -> Void)?
    /// Called when the view reports a new match count for the search term.
    var onSearchResultsChanged: ((Int) -> Void)?

    init(navigation: PDFReaderNavigation) {
        self.navigation = navigation
    }

    func attach(_ view: PDFView) {
        self.view = view
        // PDFKit's notification is the reliable signal for "the user moved". Its
        // delegate callbacks fire for programmatic changes too, which is exactly
        // the half of the traffic that must not be treated as a page turn.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(pageChanged),
            name: .PDFViewPageChanged,
            object: view
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(searchChanged),
            name: .PDFViewSelectionChanged,
            object: view
        )
    }

    func detach() {
        // Removing by notification centre rather than by selector: the
        // selector-taking overload is AppKit-only, so using it fails to compile
        // for iOS — and the whole file is built for both.
        NotificationCenter.default.removeObserver(self, name: .PDFViewPageChanged, object: view)
        NotificationCenter.default.removeObserver(self, name: .PDFViewSelectionChanged, object: view)
        view = nil
    }

    @objc private func pageChanged() {
        guard !isApplyingModelChange else { return }
        guard let view, let page = view.currentPage else { return }
        onPageChanged?(view.document?.index(for: page) ?? 0)
    }

    @objc private func searchChanged() {
        onSearchResultsChanged?(view?.highlightedSelections?.count ?? 0)
    }

    /// Applies the navigation state to the view.
    func apply(_ navigation: PDFReaderNavigation) {
        self.navigation = navigation
        guard let view, let document = view.document else { return }
        isApplyingModelChange = true
        defer { isApplyingModelChange = false }

        let wantedMode = Self.displayMode(for: navigation.transition)
        if view.displayMode != wantedMode {
            view.displayMode = wantedMode
            // Changing display mode sends the view back to the first page, which
            // is never what the user asked for. Putting it back is not a
            // workaround: the mode change genuinely discards the position, and
            // leaving it discarded is a visible jump.
            if let target = document.page(at: navigation.pageIndex) {
                view.go(to: target)
            }
        }

        // Two-up is horizontal, single-page is vertical. Getting this backwards
        // makes a two-up spread scroll the wrong way, which reads as the
        // navigation being broken rather than as a layout setting.
        let wantedDirection: PDFDisplayDirection = navigation.isTwoUp ? .horizontal : .vertical
        if view.displayDirection != wantedDirection {
            view.displayDirection = wantedDirection
        }
        if view.displaysAsBook != navigation.isTwoUp {
            view.displaysAsBook = navigation.isTwoUp
        }
        if navigation.isTwoUp, view.pageBreakMargins.top != 0 {
            // `PDFEdgeInsets` is `NSEdgeInsets`/`UIEdgeInsets`, whose memberwise
            // order is top, left, bottom, right — not the reading order. The
            // compiler catches the mistake, but the error names neither
            // "top" nor "right", so the asymmetry is worth a comment.
            view.pageBreakMargins = .init(top: 0, left: 0, bottom: 0, right: 0)
        }

        applyRotation(navigation.rotationQuarterTurns, to: view, document: document)

        if let current = view.currentPage,
           document.index(for: current) != navigation.pageIndex,
           let target = document.page(at: navigation.pageIndex) {
            view.go(to: target)
        }
        applyZoom(navigation.zoom, to: view)
    }

    /// A jump requested by the user: page field, thumbnail, outline, search hit.
    func go(toPageIndex index: Int) {
        guard let view, let document = view.document,
              let page = document.page(at: index) else { return }
        isApplyingModelChange = true
        defer { isApplyingModelChange = false }
        view.go(to: page)
    }

    /// Runs a search and moves to the first match.
    ///
    /// - Returns: how many matches there are, so the UI can say "3 of 12" or
    ///   "No results" rather than leaving the user tapping a next button that
    ///   does nothing.
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
            view.go(to: first)
            isApplyingModelChange = false
        }
        onSearchResultsChanged?(selections.count)
        return selections.count
    }

    /// Moves to the next or previous match.
    func stepSearchResult(by delta: Int) {
        guard let view, let selections = view.highlightedSelections, !selections.isEmpty
        else { return }
        guard let current = view.currentSelection,
              let index = selections.firstIndex(of: current)
        else {
            goToSearchResult(at: delta > 0 ? 0 : selections.count - 1, in: selections)
            return
        }
        // Wraps, because a search box that stops at the last match leaves the
        // user tapping a dead button with results still on screen.
        let next = (index + delta + selections.count) % selections.count
        goToSearchResult(at: next, in: selections)
    }

    private func goToSearchResult(at index: Int, in selections: [PDFSelection]) {
        guard let view, selections.indices.contains(index) else { return }
        isApplyingModelChange = true
        view.setCurrentSelection(selections[index], animate: true)
        view.go(to: selections[index])
        isApplyingModelChange = false
    }

    private func applyZoom(_ zoom: PDFReaderNavigation.Zoom, to view: PDFView) {
        switch zoom {
        case .fitWidth, .fitPage:
            // `scaleFactorForSizeToFit` is the only measure of "fits", and
            // setting both ends of the scale range to it is what actually pins
            // the zoom. Setting only `scaleFactor` lets the next relayout undo it.
            let fit = view.scaleFactorForSizeToFit
            guard fit > 0 else { return }
            view.minScaleFactor = fit
            view.maxScaleFactor = fit
            view.scaleFactor = fit
        case .actualSize:
            let fit = max(view.scaleFactorForSizeToFit, 0.01)
            view.minScaleFactor = fit / 4
            view.maxScaleFactor = 4
            view.scaleFactor = 1
        }
    }

    private func applyRotation(
        _ quarterTurns: Int,
        to view: PDFView,
        document: PDFDocument
    ) {
        // PDFKit's `rotation` is absolute, so the wanted value is computed from
        // the turn count rather than incremented — incrementing would compound
        // with whatever rotation the page already carried.
        let degrees = quarterTurns * 90
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            if page.rotation != degrees {
                page.rotation = degrees
            }
        }
    }

    private static func displayMode(for transition: PDFReaderNavigation.Transition) -> PDFDisplayMode {
        switch transition {
        case .scroll, .pageCurl: .singlePage
        case .continuous: .singlePageContinuous
        }
    }
}

/// A region the user is dragging out, not yet an annotation.
struct PDFDraftRegion: Equatable {
    var start: CGPoint
    var current: CGPoint

    /// The rectangle, normalised so a drag in any direction gives a positive size.
    ///
    /// Not cosmetic: a rectangle built from two arbitrary points has a negative
    /// width when the drag runs right-to-left or bottom-to-top, and a negative
    /// width is not a valid annotation rectangle — the file would record it and
    /// no reader would draw it.
    var rect: CGRect {
        CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
    }

    /// Whether the drag is far enough to be an annotation.
    ///
    /// A one-pixel drag is almost always an accidental touch, and writing a
    /// zero-area annotation for one is how a page fills with invisible marks.
    var isMeaningful: Bool {
        rect.width >= 4 && rect.height >= 4
    }
}

/// The `PDFView` itself.
///
/// Wrapped rather than subclassed: `PDFView`'s own gesture recognisers already
/// handle scrolling, selection and zoom, and adding a pan recogniser on top
/// would fight them. The one gesture this adds is the annotation drag, and it
/// lives in `PDFPageCanvasContainer` and is installed only while a tool is
/// active — otherwise it would swallow every touch in the document and make the
/// page impossible to scroll.
///
/// Split by platform because `UIViewRepresentable` and `NSViewRepresentable`
/// are distinct protocols with no common supertype. The bodies are otherwise
/// identical, and the divergence is confined to the type name.
struct PDFPageCanvas: View {
    let model: PDFReaderModel
    let navigation: PDFReaderNavigation
    let searchTerm: String?
    let onPageChanged: (Int) -> Void
    let onSearchResultsChanged: (Int) -> Void
    /// Called with a match count when the user asks for the next or previous one.
    var onStepSearchResult: ((Int) -> Void)?

    var body: some View {
        PlatformCanvas(
            model: model,
            navigation: navigation,
            searchTerm: searchTerm,
            onPageChanged: onPageChanged,
            onSearchResultsChanged: onSearchResultsChanged
        )
    }
}

#if canImport(UIKit) && !os(macOS)
@MainActor
private struct PlatformCanvas: UIViewRepresentable {
    let model: PDFReaderModel
    let navigation: PDFReaderNavigation
    let searchTerm: String?
    let onPageChanged: (Int) -> Void
    let onSearchResultsChanged: (Int) -> Void

    func makeCoordinator() -> PDFViewCoordinator { PDFViewCoordinator(navigation: navigation) }

    func makeUIView(context: Context) -> PDFView {
        PDFPageCanvasSupport.configure(context.coordinator, model: model, navigation: navigation)
    }

    func updateUIView(_ view: PDFView, context: Context) {
        PDFPageCanvasSupport.refresh(
            context.coordinator, view: view, model: model,
            navigation: navigation, onPageChanged: onPageChanged,
            onSearchResultsChanged: onSearchResultsChanged
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
    let searchTerm: String?
    let onPageChanged: (Int) -> Void
    let onSearchResultsChanged: (Int) -> Void

    func makeCoordinator() -> PDFViewCoordinator { PDFViewCoordinator(navigation: navigation) }

    func makeNSView(context: Context) -> PDFView {
        PDFPageCanvasSupport.configure(context.coordinator, model: model, navigation: navigation)
    }

    func updateNSView(_ view: PDFView, context: Context) {
        PDFPageCanvasSupport.refresh(
            context.coordinator, view: view, model: model,
            navigation: navigation, onPageChanged: onPageChanged,
            onSearchResultsChanged: onSearchResultsChanged
        )
    }

    static func dismantleNSView(_ view: PDFView, coordinator: PDFViewCoordinator) {
        coordinator.detach()
    }
}
#endif

/// The platform-independent half of the canvas.
///
/// Shared because the two representables differ only in their protocol name,
/// and duplicating the setup would be two places to fix for one bug.
@MainActor
enum PDFPageCanvasSupport {
    /// The colour behind the page.
    ///
    /// Different names on the two platforms for the same intent, so it is
    /// resolved once here rather than at each use.
    static var pageBackgroundColour: PlatformColor {
        #if canImport(UIKit) && !os(macOS)
        PlatformColor.secondarySystemBackground
        #else
        PlatformColor.windowBackgroundColor
        #endif
    }

    static func configure(
        _ coordinator: PDFViewCoordinator,
        model: PDFReaderModel,
        navigation: PDFReaderNavigation
    ) -> PDFView {
        let view = PDFView()
        view.autoScales = false
        view.displayBox = .mediaBox
        view.backgroundColor = PDFPageCanvasSupport.pageBackgroundColour
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
        onPageChanged: @escaping (Int) -> Void,
        onSearchResultsChanged: @escaping (Int) -> Void
    ) {
        if view.document !== model.document {
            view.document = model.document
        }
        coordinator.onPageChanged = onPageChanged
        coordinator.onSearchResultsChanged = onSearchResultsChanged
        coordinator.apply(navigation)
    }
}

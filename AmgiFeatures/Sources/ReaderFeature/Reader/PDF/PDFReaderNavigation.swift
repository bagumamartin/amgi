import Foundation
import Observation

/// The single source of truth for where the reader is.
///
/// Every transition writes here and nothing else writes to `PDFView` directly.
/// That is not tidiness: `PDFView` can be moved by the user scrolling, by a
/// thumbnail, by a search hit, by a restored position and by a programmatic page
/// change, and the last writer wins. Routing all of them through one value
/// means the page counter, the outline highlight, the thumbnail selection and
/// the saved position cannot disagree — and it is what makes it possible to
/// tell a *user's* page turn from a programmatic move, which matters because
/// only the former is reading progress.
@MainActor
@Observable
final class PDFReaderNavigation: Equatable {
    /// How pages advance.
    enum Transition: String, CaseIterable, Identifiable, Sendable {
        /// One page at a time, by swipe or arrow key. Preview's default.
        case scroll
        /// One page at a time, with a visible page-turn curl.
        case pageCurl
        /// Continuous vertical scrolling with no page boundary.
        case continuous

        var id: String { rawValue }

        var label: String {
            switch self {
            case .scroll: "Page"
            case .pageCurl: "Page Curl"
            case .continuous: "Continuous"
            }
        }

        var symbolName: String {
            switch self {
            case .scroll: "rectangle.on.rectangle"
            case .pageCurl: "book.closed"
            case .continuous: "scroll"
            }
        }
    }

    /// How much of the page is shown.
    enum Zoom: String, CaseIterable, Identifiable, Sendable {
        case fitWidth
        case fitPage
        case actualSize

        var id: String { rawValue }

        var label: String {
            switch self {
            case .fitWidth: "Fit Width"
            case .fitPage: "Fit Page"
            case .actualSize: "Actual Size"
            }
        }

        var symbolName: String {
            switch self {
            case .fitWidth: "arrow.left.and.right"
            case .fitPage: "arrow.up.and.down"
            case .actualSize: "1.magnifyingglass"
            }
        }
    }

    /// Zero-based index of the page in front of the reader.
    public private(set) var pageIndex: Int = 0
    /// The label shown in the page field, in the document's own numbering.
    public private(set) var pageLabel: String = "1"
    public private(set) var pageCount: Int = 0

    var transition: Transition = .scroll
    var zoom: Zoom = .fitWidth
    var isTwoUp: Bool = false
    public private(set) var rotationQuarterTurns: Int = 0
    var isSidebarVisible: Bool = true

    /// Whether the last move came from the user.
    ///
    /// Restoring a saved position is not the user turning a page, and recording
    /// it would move the timestamp — and therefore the resume point — every time
    /// the book was opened. That is how a reader ends up always resuming from
    /// the moment it was *last looked at* rather than the last place it was
    /// *read*.
    public private(set) var isUserInitiated = false

    init() {}

    static func == (lhs: PDFReaderNavigation, rhs: PDFReaderNavigation) -> Bool {
        lhs.pageIndex == rhs.pageIndex
            && lhs.pageCount == rhs.pageCount
            && lhs.pageLabel == rhs.pageLabel
            && lhs.transition == rhs.transition
            && lhs.zoom == rhs.zoom
            && lhs.isTwoUp == rhs.isTwoUp
            && lhs.rotationQuarterTurns == rhs.rotationQuarterTurns
    }

    /// Records a page change.
    ///
    /// - Parameter userInitiated: false for programmatic moves — restoring a
    ///   position, following an outline link — which must not overwrite the
    ///   reading position.
    func move(toPage index: Int, label: String, count: Int, userInitiated: Bool) {
        let clamped = max(0, min(index, max(0, count - 1)))
        // A no-op update would still publish, and publishing on every scroll tick
        // makes the whole sidebar re-render while the user is reading.
        guard clamped != pageIndex || label != pageLabel || count != pageCount else { return }
        pageIndex = clamped
        pageLabel = label
        pageCount = count
        isUserInitiated = userInitiated
    }

    /// Updates only the label and count, for a move within the same page.
    func update(label: String, count: Int) {
        guard label != pageLabel || count != pageCount else { return }
        pageLabel = label
        pageCount = count
    }

    /// The page a turn lands on, respecting the current layout.
    ///
    /// In two-up mode a turn moves by two, because a spread is what the reader
    /// is looking at and advancing by one leaves half the previous spread behind.
    func turn(by delta: Int, from index: Int? = nil) -> Int {
        let current = index ?? pageIndex
        let step = isTwoUp ? 2 * delta : delta
        let target = current + step
        return isTwoUp ? Self.alignToSpreadStart(target) : max(0, target)
    }

    /// The first page of the spread containing `index`.
    ///
    /// A two-up spread is pages 0-1, 2-3 and so on, so any page can begin one.
    /// Aligning is what stops a turn landing on a lone right-hand page with
    /// nothing beside it, which is the same rule Preview applies.
    static func alignToSpreadStart(_ index: Int) -> Int {
        let clamped = max(0, index)
        return clamped - (clamped % 2)
    }

    func rotateClockwise() {
        rotationQuarterTurns = (rotationQuarterTurns + 1) % 4
    }

    func rotateCounterClockwise() {
        rotationQuarterTurns = (rotationQuarterTurns + 3) % 4
    }

    var rotationDegrees: Int { rotationQuarterTurns * 90 }
}

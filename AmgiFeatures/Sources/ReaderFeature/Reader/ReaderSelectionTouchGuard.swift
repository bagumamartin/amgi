#if os(iOS)
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Claims a touch that lands on the text selection, so page-turn gestures
/// that are made to wait on it stand down.
///
/// Recognises at once for a touch on the selection and fails at once for any
/// other, so a swipe elsewhere on the page is not delayed. It never cancels or
/// delays touches and runs alongside every other recogniser, so WebKit still
/// gets the whole touch: the long press that lifts the selection, the drag
/// that follows, and the handles.
final class ReaderSelectionTouchGuard: UIGestureRecognizer, UIGestureRecognizerDelegate {
    private let isOnSelection: (UITouch) -> Bool

    init(isOnSelection: @escaping (UITouch) -> Bool) {
        self.isOnSelection = isOnSelection
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard state == .possible else { return }
        guard touches.count == 1, let touch = touches.first, isOnSelection(touch) else {
            state = .failed
            return
        }
        state = .began
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        if state == .began || state == .changed { state = .changed }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        state = (state == .began || state == .changed) ? .ended : .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        state = .cancelled
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        true
    }
}
#endif

#if os(iOS)
/// Watches touches on the page without ever taking part in them, so the
/// reader can put up its page pictures the moment a horizontal drag starts —
/// just before UIKit's curl begins rendering the pages it turns.
final class ReaderTouchObserver: UIGestureRecognizer, UIGestureRecognizerDelegate {
    var onHorizontalDragBegan: ((UITouch) -> Void)?
    var onTouchesEnded: (() -> Void)?

    private var start: CGPoint?
    private var didReportDrag = false
    /// Movement that counts as the start of a page drag: below the curl's own
    /// threshold, so the pictures are up before it starts.
    private static let dragThreshold: CGFloat = 3

    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard start == nil, let touch = touches.first else { return }
        start = touch.location(in: view)
        didReportDrag = false
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let start, !didReportDrag, let touch = touches.first else { return }
        let point = touch.location(in: view)
        let dx = abs(point.x - start.x), dy = abs(point.y - start.y)
        guard dx > Self.dragThreshold, dx >= dy else { return }
        didReportDrag = true
        onHorizontalDragBegan?(touch)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        finish()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        finish()
    }

    private func finish() {
        start = nil
        didReportDrag = false
        onTouchesEnded?()
        // Never recognises: it only watches.
        state = .failed
    }

    override func reset() {
        super.reset()
        start = nil
        didReportDrag = false
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        true
    }
}
#endif

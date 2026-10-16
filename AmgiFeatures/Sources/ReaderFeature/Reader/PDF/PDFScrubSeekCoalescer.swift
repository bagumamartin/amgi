import Foundation

#if canImport(UIKit) && !os(macOS)
import QuartzCore
#endif

/// Remembers only the latest page a scrub asked for, and hands it out once.
///
/// A finger crossing a 600-page strip passes several pages per frame. Queuing
/// a seek for each makes `PDFView` lay out pages the user is already past;
/// keeping the latest target and applying it at most once per frame keeps the
/// page in step with the finger at the cost of skipping pages no one sees.
struct PDFScrubSeekLatch: Equatable {
    private(set) var pending: Int?
    private(set) var applied: Int?

    init(applied: Int? = nil) {
        self.applied = applied
    }

    /// Records a target, replacing any that has not been applied yet.
    mutating func request(_ page: Int) {
        pending = page
    }

    /// The page to seek to now, or nil when nothing new is waiting.
    mutating func take() -> Int? {
        guard let page = pending else { return nil }
        pending = nil
        guard page != applied else { return nil }
        applied = page
        return page
    }
}

/// Drives a `PDFScrubSeekLatch` from the display's refresh, so the live seek
/// lands at most once per frame.
///
/// On macOS, where the strip is driven by a pointer that reports far fewer
/// samples, the latch is drained immediately.
@MainActor
final class PDFScrubSeekCoalescer: NSObject {
    private var latch = PDFScrubSeekLatch()
    private var apply: (Int) -> Void = { _ in }
    #if canImport(UIKit) && !os(macOS)
    private var displayLink: CADisplayLink?
    #endif

    /// Starts a scrub that begins on `page`, seeking through `apply`.
    func begin(at page: Int, apply: @escaping (Int) -> Void) {
        latch = PDFScrubSeekLatch(applied: page)
        self.apply = apply
        #if canImport(UIKit) && !os(macOS)
        if displayLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(frame))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
        #endif
    }

    func request(_ page: Int) {
        latch.request(page)
        #if !(canImport(UIKit) && !os(macOS))
        drain()
        #endif
    }

    /// Stops the per-frame seeks. Whatever is still pending is dropped: the
    /// caller commits the final page itself.
    func end() {
        #if canImport(UIKit) && !os(macOS)
        displayLink?.invalidate()
        displayLink = nil
        #endif
        latch = PDFScrubSeekLatch()
        apply = { _ in }
    }

    @objc private func frame() {
        drain()
    }

    private func drain() {
        if let page = latch.take() {
            apply(page)
        }
    }
}

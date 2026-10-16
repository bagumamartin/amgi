import Observation
import SwiftUI

/// The page under the scrubber's finger, shared with the reader's page badge.
///
/// Live scrub seeks deliberately bypass `PDFReaderNavigation` — publishing it
/// re-evaluates the whole reader body every frame. Without this the "N of M"
/// badge, which reads the navigation page, froze until the finger lifted.
///
/// Its own observable object so that only views which read `page` — the
/// scrubber and `PDFPageBadgeText` — re-render as the finger moves; the
/// reader container holds it but never reads `page` in its body.
@MainActor
@Observable
final class PDFScrubState {
    /// The scrubbed page while the finger is down; nil otherwise.
    var page: Int?

    /// The page to show in a page counter: the scrubbed page while scrubbing,
    /// else the reader's committed page.
    func displayedPage(navigationPage: Int) -> Int {
        page ?? navigationPage
    }
}

/// "N of M", tracking the scrubber's finger on the same frame as its haptic
/// tick, and the reader's page otherwise.
struct PDFPageBadgeText: View {
    let scrubState: PDFScrubState
    let navigationPage: Int
    let pageCount: Int

    var body: some View {
        Text("\(scrubState.displayedPage(navigationPage: navigationPage) + 1) of \(max(1, pageCount))")
    }
}

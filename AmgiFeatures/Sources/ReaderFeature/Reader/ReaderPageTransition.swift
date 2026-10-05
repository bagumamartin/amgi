import Foundation

/// How the reader turns a page, matching Apple Books' four options.
///
/// Only `curl` and `scroll` map onto a UIKit transition style. The other two
/// are Apple's own effects and have no `UIPageViewController` equivalent, so
/// they are composed from primitives — see `ReaderPageTransition` in each
/// platform host for how.
///
/// `curl` is the default because it is what a book does, and because it makes
/// the reader feel like a book rather than a scrolling web page.
enum ReaderPageTransition: String, CaseIterable, Identifiable, Sendable {
    /// A page peels over from the right edge. `UIPageViewController`'s
    /// `.pageCurl`.
    case curl
    /// The page slides horizontally. `UIPageViewController`'s `.scroll`.
    case slide
    /// A quick crossfade with no lateral movement.
    case fastFade
    /// Continuous scroll, with the page boundary visible as you pass it.
    case scroll

    var id: String { rawValue }

    var label: String {
        switch self {
        case .curl: "Curl"
        case .slide: "Slide"
        case .fastFade: "Fast Fade"
        case .scroll: "Scroll"
        }
    }

    var systemImage: String {
        switch self {
        case .curl: "book.closed"
        case .slide: "arrow.left.arrow.right"
        case .fastFade: "circle.lefthalf.filled"
        case .scroll: "scroll"
        }
    }

    /// Whether the selected transition can follow a finger. EPUB curl uses
    /// UIPageViewController's native interactive page turn; the other modes
    /// use the reader's horizontal pan recognizer.
    var supportsInteractivePan: Bool {
        true
    }

    /// Duration of a non-interactive turn. Curl is fixed by UIKit; the others
    /// are ours, and Fast Fade is deliberately quicker than Slide so the two
    /// feel like different effects rather than the same one twice.
    var duration: TimeInterval {
        switch self {
        case .curl: 0
        case .slide: 0.32
        case .fastFade: 0.16
        case .scroll: 0
        }
    }
}

#if os(iOS)
import UIKit

extension ReaderPageTransition {
    /// The `UIPageViewController` style this effect rides on.
    ///
    /// Fast Fade and Slide both borrow `.scroll` as their carrier and then
    /// replace UIKit's animation — the style is what the controller is built
    /// with, not what the user ends up seeing.
    var pageViewControllerStyle: UIPageViewController.TransitionStyle {
        switch self {
        case .curl: .pageCurl
        case .slide, .fastFade, .scroll: .scroll
        }
    }
}
#endif

enum ReaderPreferenceKeys {
    /// Stored in the app group so the choice follows the profile-independent
    /// reader setting, matching the other `reader_typo_*` keys.
    static let pageTransition = "reader_typo_page_transition"
}

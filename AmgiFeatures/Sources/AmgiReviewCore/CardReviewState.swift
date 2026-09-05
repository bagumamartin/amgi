public import AnkiKit
import Foundation

/// Which scheduling category the current card belongs to, derived from the
/// card's `type` field at advance time and surfaced as the state dot in the
/// review title bar. Lives in AmgiReviewCore (not AnkiKit) because only the
/// reviewer paints it.
public enum CardReviewState: Sendable {
    case new
    case learning
    case review
    case relearning

    public init(cardType: Int16) {
        switch cardType {
        case 1, 3: self = .learning
        case 2: self = .review
        default: self = .new
        }
    }

    /// Convenience for queue-based callers; `type == 3` is learning for the
    /// same reason as above.
    public init(cardQueue: Int16) {
        switch cardQueue {
        case 0: self = .new
        case 1, 3, 4: self = .learning // Learn / DayLearn / PreviewRepeat → orange
        case 2: self = .review
        default: self = .new
        }
    }
}

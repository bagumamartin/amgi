import AmgiTheme
import AmgiUI
import AmgiReviewCore
import AnkiKit
import SwiftUI

/// Title-bar context dots for the reviewer: the current card's scheduling
/// category and its last rating, color-coded with the same hues as the
/// progress indicators and rating bar. Dots only — color carries the
/// meaning; a hairline ring keeps them visible on tinted card chrome.
/// The rating dot is tappable to repeat the last rating (new cards default
/// to Again); it dims while the answer isn't showing, since repeat only
/// applies then. Rendered in the `DailyProgressBar` header center so the
/// pair sits at the true bar midpoint.
struct ReviewContextDots: View {
    let session: ReviewSession

    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 5) {
            contextDot(stateColor)
                .accessibilityLabel(stateLabel)
            ratingDot
        }
    }

    private var stateColor: Color {
        switch session.currentCardState {
        case .new: palette.cardStateNew
        case .learning: palette.cardStateLearning
        case .review: palette.cardStateReview
        case .relearning: palette.cardStateLearning // relearning is learning for the progress bar (orange, not red)
        }
    }

    private var stateLabel: String {
        switch session.currentCardState {
        case .new: "New card"
        case .learning, .relearning: "Learning"
        case .review: "Review"
        }
    }

    /// Same hue mapping the rating bar uses (Again/Good ↔ relearn/review
    /// etc.). Never-reviewed cards show the new-state hue.
    private var lastRatingColor: Color {
        switch session.currentCardLastRating {
        case .again: palette.cardStateRelearn
        case .hard: palette.cardStateLearning
        case .good: palette.cardStateReview
        case .easy: palette.cardStateNew
        case nil: palette.cardStateNew
        }
    }

    /// Neutral grey used *before* the answer is revealed so the dot doesn't
    /// give away the previous rating's hue. Theme-aware via the palette
    /// (`cardStateSuspended` is the designated neutral state grey and exists
    /// in every palette / light+dark variant, unlike a hardcoded system grey).
    private var neutralRatingColor: Color {
        palette.cardStateSuspended
    }

    /// The color actually painted for the rating dot — neutral grey on the
    /// front, the true rating hue only after `showAnswer`.
    private var effectiveRatingColor: Color {
        session.showAnswer ? lastRatingColor : neutralRatingColor
    }

    private var lastRatingLabel: String {
        switch session.currentCardLastRating {
        case .again: "Last rated Again"
        case .hard: "Last rated Hard"
        case .good: "Last rated Good"
        case .easy: "Last rated Easy"
        case nil: "Never reviewed"
        }
    }

    private func contextDot(_ color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .overlay(Circle().strokeBorder(palette.separator.opacity(0.5), lineWidth: 1))
    }

    private var ratingDot: some View {
        Button {
            session.answerWithLastRating()
        } label: {
            contextDot(effectiveRatingColor)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!session.showAnswer || session.isAdvancing)
        .opacity(session.isAdvancing ? 0.45 : 1)
        .accessibilityLabel("\(lastRatingLabel). Tap to repeat it")
    }
}

import SwiftUI
import AmgiTheme
import AmgiUI
import AmgiReviewCore
import AmgiAppCore
import AnkiKit

/// Shared layout limits for roomy review windows. Keeping these as constants
/// makes the responsive behavior testable without launching a multi-window UI.
enum ReviewLayoutMetrics {
    static let contentMaxWidth: CGFloat = 980
    static let compactRatingMaxWidth: CGFloat = 720
    static let macRatingMaxWidth: CGFloat = 600
}

/// Optional queue/session inspector for regular-width iPad and every macOS
/// review window. It is observational only: every mutation still goes through
/// `ReviewSession` and its serialized scheduler lease.
struct ReviewSessionInspector: View {
    let session: ReviewSession

    @Environment(\.palette) private var palette

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AmgiSpacing.lg) {
                header
                queueSection
                progressSection
                currentCardSection
                historySection
            }
            .padding(AmgiSpacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(palette.background)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: AmgiSpacing.xs) {
            Label("Review Session", systemImage: "rectangle.stack")
                .font(.headline)
                .foregroundStyle(palette.textPrimary)
            Text(session.profile.displayName)
                .amgiFont(.caption)
                .foregroundStyle(palette.textSecondary)
        }
    }

    private var queueSection: some View {
        inspectorSection("Queue") {
            countRow("New", value: session.remainingCounts.newCount, color: palette.cardStateNew)
            countRow("Learning", value: session.remainingCounts.learnCount, color: palette.cardStateLearning)
            countRow("Review", value: session.remainingCounts.reviewCount, color: palette.cardStateReview)
        }
    }

    private var progressSection: some View {
        inspectorSection("Today") {
            valueRow("Answered", session.dailyCompletedToday)
            valueRow("Session reviews", session.sessionStats.reviewed)
            valueRow("Correct", session.sessionStats.correct)
            valueRow("Streak", session.correctStreak)
            valueRow("Answer time", answerTimeLabel)
        }
    }

    private var currentCardSection: some View {
        inspectorSection("Current Card") {
            valueRow("State", currentStateTitle)
            valueRow("Ordinal", (session.currentCardOrdinal + 1).formatted())
            valueRow("Queue remaining", max(session.remainingCounts.total, 0).formatted())
            valueRow("Deck", session.activeDeckName.isEmpty ? session.deckName : session.activeDeckName)
        }
    }

    private var historySection: some View {
        inspectorSection("History") {
            valueRow("Undo", session.canUndo ? "Available" : "Empty")
            valueRow("Redo", session.canRedo ? "Available" : "Empty")
            valueRow(
                "Scheduler",
                ReviewSessionCoordinator.shared.activeSession?.sessionID == session.sessionID
                    ? "Owned by this session"
                    : "Unavailable"
            )
        }
    }

    @ViewBuilder
    private func inspectorSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: AmgiSpacing.sm) {
            Text(title.uppercased())
                .amgiFont(.micro)
                .foregroundStyle(palette.textSecondary)
            VStack(spacing: AmgiSpacing.sm) {
                content()
            }
            .padding(AmgiSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: AmgiRadius.control, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: AmgiRadius.control, style: .continuous)
                    .strokeBorder(palette.separator, lineWidth: 1)
            }
        }
    }

    private func countRow(_ title: String, value: Int, color: Color) -> some View {
        HStack {
            Label(title, systemImage: "circle.fill")
                .foregroundStyle(palette.textPrimary)
                .symbolRenderingMode(.hierarchical)
                .tint(color)
            Spacer()
            Text(value.formatted())
                .monospacedDigit()
                .foregroundStyle(palette.textPrimary)
        }
        .amgiFont(.body)
    }

    private func valueRow(_ title: String, _ value: Int) -> some View {
        valueRow(title, value.formatted())
    }

    private func valueRow(_ title: String, _ value: String) -> some View {
        LabeledContent(title) {
            Text(value)
                .foregroundStyle(palette.textPrimary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
        .amgiFont(.body)
    }

    private var answerTimeLabel: String {
        let seconds = max(session.sessionStats.totalTimeMs, 0) / 1_000
        if seconds < 60 { return "\(seconds)s" }
        return "\(seconds / 60)m \(seconds % 60)s"
    }

    private var currentStateTitle: String {
        switch session.currentCardState {
        case .new: "New"
        case .learning: "Learning"
        case .review: "Review"
        case .relearning: "Relearning"
        }
    }
}

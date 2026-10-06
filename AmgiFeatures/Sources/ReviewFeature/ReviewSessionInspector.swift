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
            Label(L10n.text("Review Session"), systemImage: "rectangle.stack")
                .font(.headline)
                .foregroundStyle(palette.textPrimary)
            Text(session.profile.displayName)
                .amgiFont(.caption)
                .foregroundStyle(palette.textSecondary)
        }
    }

    private var queueSection: some View {
        inspectorSection(L10n.text("Queue")) {
            countRow(L10n.text("New"), value: session.remainingCounts.newCount, color: palette.cardStateNew)
            countRow(L10n.text("Learning"), value: session.remainingCounts.learnCount, color: palette.cardStateLearning)
            countRow(L10n.text("Review"), value: session.remainingCounts.reviewCount, color: palette.cardStateReview)
        }
    }

    private var progressSection: some View {
        inspectorSection(L10n.text("Today")) {
            valueRow(L10n.text("Answered"), session.dailyCompletedToday)
            valueRow(L10n.text("Session reviews"), session.sessionStats.reviewed)
            valueRow(L10n.text("Correct"), session.sessionStats.correct)
            valueRow(L10n.text("Streak"), session.correctStreak)
            valueRow(L10n.text("Answer time"), answerTimeLabel)
        }
    }

    private var currentCardSection: some View {
        inspectorSection(L10n.text("Current Card")) {
            valueRow(L10n.text("State"), currentStateTitle)
            valueRow(L10n.text("Ordinal"), (session.currentCardOrdinal + 1).formatted())
            valueRow(L10n.text("Queue remaining"), max(session.remainingCounts.total, 0).formatted())
            valueRow(L10n.text("Deck"), session.activeDeckName.isEmpty ? session.deckName : session.activeDeckName)
        }
    }

    private var historySection: some View {
        inspectorSection(L10n.text("History")) {
            valueRow(L10n.text("Undo"), session.canUndo ? L10n.text("Available") : L10n.text("Not available"))
            valueRow(L10n.text("Redo"), session.canRedo ? L10n.text("Available") : L10n.text("Not available"))
            valueRow(
                L10n.text("Scheduler"),
                ReviewSessionCoordinator.shared.activeSession?.sessionID == session.sessionID
                    ? L10n.text("Owned by this session")
                    : L10n.text("Unavailable")
            )
        }
    }

    @ViewBuilder
    private func inspectorSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: AmgiSpacing.sm) {
            Text(title.uppercased(with: L10n.locale))
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
        case .new: L10n.text("New")
        case .learning: L10n.text("Learning")
        case .review: L10n.text("Review")
        case .relearning: L10n.text("Relearning")
        }
    }
}

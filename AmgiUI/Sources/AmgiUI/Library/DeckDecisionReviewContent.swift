#if !os(watchOS)
public import SwiftUI

/// Engine-free body of the decision flow. Empty, skipped, loading, and
/// unavailable are distinct so a failed read never looks like a healthy queue.
public struct DeckDecisionReviewContent: View {
    let data: DeckTriageData
    let skippedCount: Int
    let onAction: (DeckTriageItem, DeckTriageAction) -> Void
    let onSkip: (DeckTriageItem) -> Void
    let onReviewSkipped: () -> Void
    let onRetry: () -> Void

    public init(data: DeckTriageData, skippedCount: Int = 0,
                onAction: @escaping (DeckTriageItem, DeckTriageAction) -> Void,
                onSkip: @escaping (DeckTriageItem) -> Void = { _ in },
                onReviewSkipped: @escaping () -> Void = {}, onRetry: @escaping () -> Void = {}) {
        self.data = data
        self.skippedCount = skippedCount
        self.onAction = onAction
        self.onSkip = onSkip
        self.onReviewSkipped = onReviewSkipped
        self.onRetry = onRetry
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if data.readiness == .unavailable {
                    ContentUnavailableView {
                        Label("Decisions unavailable", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text("Refresh Library and try again.")
                    } actions: {
                        Button("Try Again", action: onRetry)
                    }
                } else if !data.isHidden {
                    DeckTriageCard(data: data, onAction: onAction)
                    if data.isResolved, let item = data.focusedItem {
                        Button { onSkip(item) } label: {
                            Text("Skip for this pass").frame(minHeight: 44).contentShape(Rectangle())
                        }
                        .disabled(data.busyID != nil)
                    }
                } else {
                    ContentUnavailableView {
                        Label("No more decisions", systemImage: "checkmark.circle")
                    } description: {
                        if skippedCount > 0 { Text("Skipped decisions are still waiting in Library.") }
                        else { Text("There is nothing else to decide right now.") }
                    }
                    if skippedCount > 0 {
                        Button("Review skipped decisions", action: onReviewSkipped)
                    }
                }
            }
            .frame(maxWidth: 800)
            .frame(maxWidth: .infinity)
            .padding(20)
        }
        .amgiScreenCanvas()
    }
}

#if DEBUG
#Preview("Decision flow — complete") {
    DeckDecisionReviewContent(data: .resolvedEmpty, onAction: { _, _ in })
}
#Preview("Decision flow — unavailable") {
    DeckDecisionReviewContent(data: DeckTriageData(items: [], readiness: .unavailable), onAction: { _, _ in })
}
#endif
#endif

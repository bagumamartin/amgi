import SwiftUI
import AmgiUI
import AnkiKit

/// The end of a review, once nothing is left today.
struct ReviewCelebrationCard: View {
    let deckName: String
    let sessionStats: SessionStats
    let dailyCompletedToday: Int
    let onDismiss: () -> Void

    init(
        deckName: String,
        sessionStats: SessionStats,
        dailyCompletedToday: Int,
        onDismiss: @escaping () -> Void
    ) {
        self.deckName = deckName
        self.sessionStats = sessionStats
        self.dailyCompletedToday = dailyCompletedToday
        self.onDismiss = onDismiss
    }

    var body: some View {
        SessionDoneContent(
            title: title,
            subtitle: subtitle,
            reviewed: sessionStats.reviewed,
            accuracyPercent: sessionStats.reviewed > 0 ? Int(sessionStats.accuracy * 100) : nil,
            timeLabel: formattedTime(sessionStats.totalTimeMs),
            graduatedToday: dailyCompletedToday,
            onDone: onDismiss
        )
    }

    private var title: String {
        let name = deckName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == "All Decks" { return "Done for today" }
        return name.components(separatedBy: "::").last ?? name
    }

    private var subtitle: String {
        let name = deckName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == "All Decks" {
            return "Nothing left across your decks."
        }
        return "Nothing left in this deck."
    }

    private func formattedTime(_ ms: Int) -> String {
        let totalSeconds = max(0, ms / 1000)
        if totalSeconds < 60 { return "\(totalSeconds)s" }
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        if minutes < 60 {
            return seconds > 0 ? "\(minutes)m \(seconds)s" : "\(minutes)m"
        }
        let hours = minutes / 60
        let remMinutes = minutes % 60
        return remMinutes > 0 ? "\(hours)h \(remMinutes)m" : "\(hours)h"
    }
}

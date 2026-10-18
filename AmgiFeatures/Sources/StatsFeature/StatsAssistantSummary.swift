import AmgiCharts
import AnkiKit
import Foundation

/// The dashboard's figures as plain text for the assistant: what the user
/// can see, in words, so "how am I doing?" is answered from the same
/// numbers.
enum StatsAssistantSummary {
    static func text(_ snapshot: GraphsSnapshot, period: StatsPeriod, deck: String?) -> String {
        var lines = ["The user is on the Statistics screen, showing \(period.rawValue) for \(deck ?? "all decks")."]

        let today = snapshot.today
        let minutes = today.answerMillis / 60_000
        let correct = today.answerCount > 0 ? Int((Double(today.correctCount) / Double(today.answerCount) * 100).rounded()) : nil
        lines.append("Today: \(today.answerCount) reviews in \(minutes) min" + (correct.map { ", \($0)% correct" } ?? "") + ".")

        let days = snapshot.reviews.count.filter { $0.key <= 0 && $0.key > -period.days }
        let reviews = days.values.reduce(0) { $0 + $1.learn + $1.relearn + $1.young + $1.mature + $1.filtered }
        let studied = days.values.filter { $0.learn + $0.relearn + $0.young + $0.mature + $0.filtered > 0 }.count
        let window = min(period.days, max(days.keys.map { -$0 + 1 }.max() ?? 1, 1))
        lines.append("Over the period: \(reviews) reviews, studied on \(studied) of \(window) days.")

        let retention = [
            ("today", snapshot.trueRetention.today), ("this week", snapshot.trueRetention.week),
            ("this month", snapshot.trueRetention.month), ("this year", snapshot.trueRetention.year),
        ].compactMap { label, value -> String? in
            let passed = value.youngPassed + value.maturePassed
            let total = passed + value.youngFailed + value.matureFailed
            guard total > 0 else { return nil }
            return "\(label) \(Int((Double(passed) / Double(total) * 100).rounded()))% of \(total)"
        }
        if !retention.isEmpty { lines.append("True retention: " + retention.joined(separator: "; ") + ".") }

        let counts = snapshot.cardCounts.excludingInactive
        lines.append("Cards: \(counts.newCards) new, \(counts.learn + counts.relearn) learning, \(counts.young) young, \(counts.mature) mature, \(snapshot.cardCounts.includingInactive.suspended) suspended.")

        let due = snapshot.futureDue
        let week = (0..<7).map { due.futureDue[$0] ?? 0 }
        lines.append("Due over the next 7 days: " + week.map(String.init).joined(separator: ", ") + ". Daily load about \(due.dailyLoad).")
        if due.backlogCount > 0 { lines.append("Overdue backlog: \(due.backlogCount) cards.") }
        if snapshot.fsrs { lines.append("Scheduler: FSRS.") }
        return lines.joined(separator: "\n")
    }
}

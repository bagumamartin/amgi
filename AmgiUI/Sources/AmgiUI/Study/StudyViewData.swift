import Foundation

// MARK: - DTOs (no AnkiKit / AnkiClients imports — pure view data)

/// Where the Study desk is in today's sitting.
public enum StudyDeskPhase: Equatable, Sendable {
    /// Cards are answerable and nothing has been graduated yet today.
    case due
    /// Some of today is already done, and cards are still answerable.
    case leftover
    /// Nothing is answerable right now.
    case caughtUp
}

/// Aggregate due-card counts for the Study summary ring.
public struct StudySummaryData: Equatable, Sendable {
    /// Milliseconds assumed per card until today's own answers exist.
    public static let fallbackMillisPerCard = 8_000

    public let totalDue: Int
    public let newCount: Int
    public let learnCount: Int
    public let reviewCount: Int
    /// e.g. "Today"
    public let todayLabel: String
    /// e.g. "Wednesday · 4 decks due"
    public let subtitleLabel: String
    /// Number of decks with cards due — used by the legend's deck line.
    public let deckCount: Int
    /// Cards graduated today for the whole collection — answered today and
    /// now scheduled for a future Anki day ("completed" in day-progress terms).
    public let reviewedToday: Int
    /// Live daily denominator — graduated today plus cards still answerable.
    public let dueBaselineToday: Int
    /// Learning cards due later today, outside the scheduler's learn-ahead
    /// window. They are not in `totalDue` and cannot be studied yet.
    public let learningReturning: Int
    /// Answers recorded today (`GraphsSnapshot.today`). Zero until that
    /// fetch lands; drives the leftover phase and the time-studied line.
    public let answerCount: Int
    public let answerMillis: Int
    public let streak: Int
    /// True while the revlog fetch that fills streak, time, and tomorrow
    /// is still in flight.
    public let streakPending: Bool
    /// Cards due on the next Anki day. Nil until the forecast fetch lands.
    public let tomorrowDue: Int?
    public let backlogNote: String?
    public let rolloverNote: String?

    public init(
        totalDue: Int,
        newCount: Int,
        learnCount: Int,
        reviewCount: Int,
        todayLabel: String,
        subtitleLabel: String,
        deckCount: Int,
        reviewedToday: Int = 0,
        dueBaselineToday: Int = 0,
        learningReturning: Int = 0,
        answerCount: Int = 0,
        answerMillis: Int = 0,
        streak: Int = 0,
        streakPending: Bool = false,
        tomorrowDue: Int? = nil,
        backlogNote: String? = nil,
        rolloverNote: String? = nil
    ) {
        self.totalDue = totalDue
        self.newCount = newCount
        self.learnCount = learnCount
        self.reviewCount = reviewCount
        self.todayLabel = todayLabel
        self.subtitleLabel = subtitleLabel
        self.deckCount = deckCount
        self.reviewedToday = reviewedToday
        self.dueBaselineToday = dueBaselineToday
        self.learningReturning = learningReturning
        self.answerCount = answerCount
        self.answerMillis = answerMillis
        self.streak = streak
        self.streakPending = streakPending
        self.tomorrowDue = tomorrowDue
        self.backlogNote = backlogNote
        self.rolloverNote = rolloverNote
    }

    public var phase: StudyDeskPhase {
        guard totalDue > 0 else { return .caughtUp }
        if reviewedToday > 0 || answerCount > 0 { return .leftover }
        return .due
    }

    /// Primary action. Nil when nothing is answerable — the desk must not
    /// show a disabled play button.
    public var primaryActionTitle: String? {
        switch phase {
        case .due: "Start · \(totalDue)"
        case .leftover: "Continue · \(totalDue) left"
        case .caughtUp: nil
        }
    }

    public var caughtUpTitle: String {
        if learningReturning > 0 { return "Done for now" }
        if reviewedToday > 0 || answerCount > 0 { return "Done for today" }
        return "Nothing due today"
    }

    /// Learning is always served before the new/review queue.
    public var sessionShape: String {
        var parts: [String] = []
        if learnCount > 0 { parts.append("Learning first") }
        switch (reviewCount > 0, newCount > 0) {
        case (true, true):
            parts.append(learnCount > 0 ? "then reviews and new" : "Reviews, then new")
        case (true, false):
            parts.append(learnCount > 0 ? "then reviews" : "Reviews")
        case (false, true):
            parts.append(learnCount > 0 ? "then new" : "New cards")
        case (false, false):
            break
        }
        return parts.joined(separator: ", ")
    }

    public var estimateLabel: String? {
        guard totalDue > 0 else { return nil }
        let minutes = Self.estimatedMinutes(
            remaining: totalDue,
            answerCount: answerCount,
            answerMillis: answerMillis
        )
        if minutes < 1 { return "Under a minute" }
        return "About \(minutes) min"
    }

    public var returningNote: String? {
        guard learningReturning > 0 else { return nil }
        let noun = learningReturning == 1 ? "card returns" : "cards return"
        return "\(learningReturning) learning \(noun) later today"
    }

    public var streakLabel: String? {
        guard streak > 0 else { return nil }
        return "\(streak)-day streak"
    }

    public var timeStudiedLabel: String? {
        guard answerMillis > 0 else { return nil }
        let minutes = max(1, Int((Double(answerMillis) / 60_000).rounded()))
        return "\(minutes) min studied"
    }

    public var tomorrowLabel: String? {
        guard let tomorrowDue, tomorrowDue > 0 else { return nil }
        return "Tomorrow · \(tomorrowDue) cards"
    }

    public static func estimatedMinutes(remaining: Int, answerCount: Int, answerMillis: Int) -> Int {
        guard remaining > 0 else { return 0 }
        let perCard: Double
        if answerCount > 0, answerMillis > 0 {
            perCard = Double(answerMillis) / Double(answerCount)
        } else {
            perCard = Double(fallbackMillisPerCard)
        }
        return Int((Double(remaining) * perCard / 60_000).rounded())
    }

    public static func backlogNote(haveBacklog: Bool) -> String? {
        haveBacklog ? "Daily limits are holding reviews back" : nil
    }

    public func withLiveCounts(
        totalDue: Int,
        newCount: Int,
        learnCount: Int,
        reviewCount: Int
    ) -> StudySummaryData {
        StudySummaryData(
            totalDue: totalDue,
            newCount: newCount,
            learnCount: learnCount,
            reviewCount: reviewCount,
            todayLabel: todayLabel,
            subtitleLabel: subtitleLabel,
            deckCount: deckCount,
            reviewedToday: reviewedToday,
            dueBaselineToday: dueBaselineToday,
            learningReturning: learningReturning,
            answerCount: answerCount,
            answerMillis: answerMillis,
            streak: streak,
            streakPending: streakPending,
            tomorrowDue: tomorrowDue,
            backlogNote: backlogNote,
            rolloverNote: rolloverNote
        )
    }

    public func withActivity(
        answerCount: Int,
        answerMillis: Int,
        streak: Int,
        tomorrowDue: Int,
        backlogNote: String?,
        rolloverNote: String?
    ) -> StudySummaryData {
        StudySummaryData(
            totalDue: totalDue,
            newCount: newCount,
            learnCount: learnCount,
            reviewCount: reviewCount,
            todayLabel: todayLabel,
            subtitleLabel: subtitleLabel,
            deckCount: deckCount,
            reviewedToday: reviewedToday,
            dueBaselineToday: dueBaselineToday,
            learningReturning: learningReturning,
            answerCount: answerCount,
            answerMillis: answerMillis,
            streak: streak,
            streakPending: false,
            tomorrowDue: tomorrowDue,
            backlogNote: backlogNote,
            rolloverNote: rolloverNote
        )
    }

    /// Fraction of today's due baseline completed. Clamped to 1 so re-learning
    /// a card past the morning baseline reads as 100%, not 101%.
    public var todayProgressFraction: Double {
        let baseline = max(dueBaselineToday, 1)
        return min(1, Double(max(reviewedToday, 0)) / Double(baseline))
    }

    public var todayProgressPercent: Int {
        Int((todayProgressFraction * 100).rounded())
    }

    /// Cards still to answer before the ring closes for today (frozen
    /// baseline minus reviewed). Drives the "N to close the ring" nudge.
    public var cardsRemainingToClose: Int {
        max(dueBaselineToday - reviewedToday, 0)
    }
}

/// A deck the Study desk can start right now.
///
/// Subdecks are a caption (`includesLabel`), not a nested tree — choosing
/// a session is not browsing the collection. `subdecks` stays for callers
/// that still nest, and the desk does not render it.
public struct StudyDeckRowData: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let name: String
    public let totalDue: Int
    public let newCount: Int
    public let learnCount: Int
    public let reviewCount: Int
    public let isFiltered: Bool
    public let subdecks: [StudyDeckRowData]
    /// Due subdeck names, already phrased ("Includes Vocab, Sentences").
    public let includesLabel: String?
    /// Persisted or name-derived icon (Phosphor case name). Nil ⇒ the row
    /// falls back to the letter/monogram tile.
    public var iconName: String?

    public init(
        id: Int64,
        name: String,
        totalDue: Int,
        newCount: Int,
        learnCount: Int,
        reviewCount: Int,
        isFiltered: Bool,
        subdecks: [StudyDeckRowData] = [],
        includesLabel: String? = nil,
        iconName: String? = nil
    ) {
        self.id = id
        self.name = name
        self.totalDue = totalDue
        self.learnCount = learnCount
        self.newCount = newCount
        self.reviewCount = reviewCount
        self.isFiltered = isFiltered
        self.subdecks = subdecks
        self.includesLabel = includesLabel
        self.iconName = iconName
    }

    public func updatingIconName(_ newName: String?) -> StudyDeckRowData {
        StudyDeckRowData(
            id: id, name: name, totalDue: totalDue,
            newCount: newCount, learnCount: learnCount, reviewCount: reviewCount,
            isFiltered: isFiltered, subdecks: subdecks,
            includesLabel: includesLabel, iconName: newName
        )
    }
}

/// One caught-up action. Search strings are the contract the model turns
/// into a filtered deck — stable names so a repeat tap updates one deck.
public struct StudyKeepGoingAction: Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let detail: String
    public let search: String
    public let limit: UInt32
    public let reschedule: Bool
    public let deckName: String

    public init(
        id: String,
        title: String,
        detail: String,
        search: String,
        limit: UInt32,
        reschedule: Bool,
        deckName: String
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.search = search
        self.limit = limit
        self.reschedule = reschedule
        self.deckName = deckName
    }
}

public enum StudyKeepGoing {
    public static let forgotten = StudyKeepGoingAction(
        id: "forgotten",
        title: "Forgotten",
        detail: "Cards you marked Again today",
        search: "rated:1:1",
        limit: 50,
        reschedule: true,
        deckName: "Study · Again today"
    )

    public static let ahead = StudyKeepGoingAction(
        id: "ahead",
        title: "Review ahead",
        detail: "Reviews due by tomorrow",
        search: "is:review prop:due<=1",
        limit: 50,
        reschedule: true,
        deckName: "Study · Ahead"
    )

    public static let previewNew = StudyKeepGoingAction(
        id: "previewNew",
        title: "Preview new",
        detail: "Look at new cards without starting them",
        search: "is:new",
        limit: 20,
        reschedule: false,
        deckName: "Study · Preview"
    )

    public static let actions: [StudyKeepGoingAction] = [forgotten, ahead, previewNew]
}

/// A book recommendation card in the Study "Reading recommendations" horizontal strip.
public struct StudyReadingRecData: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let coverImagePath: String?
    /// e.g. "ANTOINE DE SAINT-EXUPÉRY"
    public let authorLabel: String

    public init(
        id: String,
        title: String,
        coverImagePath: String? = nil,
        authorLabel: String
    ) {
        self.id = id
        self.title = title
        self.coverImagePath = coverImagePath
        self.authorLabel = authorLabel
    }
}

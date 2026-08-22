import Foundation

// MARK: - DTOs (no AnkiKit / AnkiClients imports — pure view data)

/// Aggregate due-card counts for the Study summary ring.
public struct StudySummaryData: Equatable, Sendable {
    public let totalDue: Int
    public let newCount: Int
    public let learnCount: Int
    public let reviewCount: Int
    /// e.g. "Today"
    public let todayLabel: String
    /// e.g. "Wednesday · 4 decks due"
    public let subtitleLabel: String
    /// Number of decks with cards due — used by ring's "across N decks" subline.
    public let deckCount: Int
    /// Cards graduated today for the whole collection — answered today and
    /// now scheduled for a future Anki day ("completed" in day-progress terms).
    public let reviewedToday: Int
    /// Frozen daily denominator — cards due + already reviewed, captured at
    /// the first observation of today's Anki day.
    public let dueBaselineToday: Int

    public init(
        totalDue: Int,
        newCount: Int,
        learnCount: Int,
        reviewCount: Int,
        todayLabel: String,
        subtitleLabel: String,
        deckCount: Int,
        reviewedToday: Int = 0,
        dueBaselineToday: Int = 0
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

/// A single deck row in the Study "Up Next" list.
///
/// Carries an optional nested `subdecks` array so the Study list can show
/// only top-level decks and reveal their subdecks on demand. Subdeck names
/// are the last path segment only (never the `parent::child` full path).
public struct StudyDeckRowData: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let name: String
    public let totalDue: Int
    public let newCount: Int
    public let learnCount: Int
    public let reviewCount: Int
    public let isFiltered: Bool
    public let subdecks: [StudyDeckRowData]
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
        iconName: String? = nil
    ) {
        self.id = id
        self.name = name
        self.totalDue = totalDue
        self.newCount = newCount
        self.learnCount = learnCount
        self.reviewCount = reviewCount
        self.isFiltered = isFiltered
        self.subdecks = subdecks
        self.iconName = iconName
    }

    public func updatingIconName(_ newName: String?) -> StudyDeckRowData {
        StudyDeckRowData(
            id: id, name: name, totalDue: totalDue,
            newCount: newCount, learnCount: learnCount, reviewCount: reviewCount,
            isFiltered: isFiltered, subdecks: subdecks, iconName: newName
        )
    }
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

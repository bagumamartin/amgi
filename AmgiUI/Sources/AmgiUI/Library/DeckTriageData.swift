import Foundation

/// Triage payload for the Library "Needs a decision" card. Anki-agnostic —
/// the container classifies its domain rows into `DeckTriageItem`s and
/// AmgiUI formats and renders. Mirrors `HeatmapCardData`: the model
/// classifies, AmgiUI owns the copy.
public struct DeckTriageData: Equatable, Hashable, Sendable {
    /// At most `DeckTriage`'s visible cap — further matches fold into
    /// `overflowCount` rather than growing the card.
    public let items: [DeckTriageItem]
    /// False while the per-deck review history the signals depend on is
    /// still in flight — same deal as the heatmap slot in
    /// `LibraryListContent`. The card renders a placeholder until then.
    public let isResolved: Bool
    /// Matches beyond the visible cap.
    public let overflowCount: Int

    public init(items: [DeckTriageItem], isResolved: Bool, overflowCount: Int = 0) {
        self.items = items
        self.isResolved = isResolved
        self.overflowCount = overflowCount
    }

    public static let unresolved = DeckTriageData(items: [], isResolved: false)
    public static let resolvedEmpty = DeckTriageData(items: [], isResolved: true)

    /// The card hides entirely — like the Archived section, it only mounts
    /// when there is something to show.
    public var isHidden: Bool { isResolved && items.isEmpty }
}

/// One deck with one problem. Carries the whole `DeckRowViewData` (not
/// parallel fields) so tapping a row reuses the existing `onTapDeck` path —
/// no second navigation plumbing to keep in sync.
public struct DeckTriageItem: Equatable, Hashable, Sendable, Identifiable {
    public let row: DeckRowViewData
    public let issue: DeckTriageIssue

    public init(row: DeckRowViewData, issue: DeckTriageIssue) {
        self.row = row
        self.issue = issue
    }

    public var id: Int64 { row.id }

    /// One line naming the problem. Derived here (not in the classifier)
    /// so the copy is testable without the engine, the way `HeroData`'s
    /// derivations are.
    public var subtitle: String {
        switch issue {
        case .neglected(let daysAgo):
            let when = daysAgo.map { "Not studied in \($0) days" } ?? "Not studied in over a year"
            return "\(when) · \(row.totalCount) due"
        case .neverStarted:
            return "Never started · \(row.newCount) new"
        case .newBacklog(let perDay, let daysToClear):
            // The horizon gate guarantees at least two weeks, so no
            // singular handling. "about" marks the projection as the
            // estimate it is.
            return "\(row.newCount) new · about \(daysToClear / 7) weeks at \(perDay)/day"
        case .empty:
            return "Nothing due · never reviewed"
        case .parked(let daysAgo):
            let when = daysAgo.map { "Parked \($0) days ago" } ?? "Parked"
            return "\(when) · all cards suspended"
        }
    }
}

/// The single problem a triaged deck has. One case per signal so the card
/// can icon each distinctly; precedence (neglected → never started →
/// new backlog → empty) is applied by the classifier.
public enum DeckTriageIssue: Equatable, Hashable, Sendable {
    /// Cards due, last review at least the neglect threshold ago. `nil`
    /// means no reviews inside the rank window (a year) — "over a year".
    case neglected(daysAgo: Int?)
    /// Untouched new cards and no review history at all.
    case neverStarted
    /// Unseen backlog far above the deck's daily new limit.
    case newBacklog(perDay: Int, daysToClear: Int)
    /// Nothing due and never reviewed — a candidate for deletion.
    case empty
    /// Fully suspended (parked) long enough to reconsider: resume or
    /// delete. `nil` means no reviews inside the rank window (a year).
    case parked(daysAgo: Int?)
}

#if DEBUG
public extension DeckTriageData {
    static let sample = DeckTriageData(
        items: [
            DeckTriageItem(
                row: DeckRowViewData(
                    id: 11, name: "한국어", fullName: "Languages::한국어",
                    newCount: 12, learnCount: 8, reviewCount: 42,
                    isFiltered: false, subdeckCount: 2
                ),
                issue: .neglected(daysAgo: 47)
            ),
            DeckTriageItem(
                row: DeckRowViewData(
                    id: 12, name: "TOPIK", fullName: "Languages::한국어::TOPIK",
                    newCount: 340, learnCount: 0, reviewCount: 0,
                    isFiltered: false, subdeckCount: 0
                ),
                issue: .neverStarted
            ),
            DeckTriageItem(
                row: DeckRowViewData(
                    id: 13, name: "Anatomy", fullName: "Med::Anatomy",
                    newCount: 412, learnCount: 5, reviewCount: 30,
                    isFiltered: false, subdeckCount: 0
                ),
                issue: .newBacklog(perDay: 20, daysToClear: 21)
            ),
        ],
        isResolved: true,
        overflowCount: 2
    )
}
#endif

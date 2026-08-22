public import SwiftUI
import AmgiTheme

/// Pure rendering surface for the Study landing screen. Owns no I/O.
/// The container in the app target loads data and maps it to the
/// single `State` value passed here.
public struct StudyLandingContent: View {
    public enum State: Equatable, Sendable {
        case loading
        case empty
        case loaded(
            summary: StudySummaryData,
            decks: [StudyDeckRowData],
            readingRecs: [StudyReadingRecData]
        )
    }

    let state: State
    let onBeginSession: () -> Void
    let onSelectDeck: (Int64) -> Void
    let onSelectBook: (String) -> Void
    let onRefresh: () async -> Void

    @Environment(\.palette) private var palette
    @SwiftUI.State private var expandedIDs: Set<Int64> = []

    public init(
        state: State,
        onBeginSession: @escaping () -> Void,
        onSelectDeck: @escaping (Int64) -> Void,
        onSelectBook: @escaping (String) -> Void,
        onRefresh: @escaping () async -> Void
    ) {
        self.state = state
        self.onBeginSession = onBeginSession
        self.onSelectDeck = onSelectDeck
        self.onSelectBook = onSelectBook
        self.onRefresh = onRefresh
    }

    public var body: some View {
        switch state {
        case .loading:
            loadingView
        case .empty:
            emptyView
        case let .loaded(summary, decks, readingRecs):
            loadedScrollView(summary: summary, decks: decks, readingRecs: readingRecs)
        }
    }

    // MARK: - Loading

    private var loadingView: some View {
        ProgressView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty

    private var emptyView: some View {
        ContentUnavailableView(
            "No decks yet",
            systemImage: "graduationcap",
            description: Text("Add an Anki deck to get started.")
        )
    }

    // MARK: - Loaded scroll view (whole page scrolls, no pinned hero)

    private func loadedScrollView(
        summary: StudySummaryData,
        decks: [StudyDeckRowData],
        readingRecs: [StudyReadingRecData]
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                inlineHeader(summary: summary)
                ringHero(summary: summary)
                beginButton(totalDue: summary.totalDue)
                    .padding(.top, 20)
                loadedBody(summary: summary, decks: decks, readingRecs: readingRecs)
                    .padding(.top, 8)
            }
            // Readable column on wide layouts (Mac window, iPad regular
            // width); no-op on iPhone where the screen is narrower.
            .frame(maxWidth: StudyColumn.maxWidth)
            .frame(maxWidth: .infinity)
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
        .refreshable { await onRefresh() }
    }

    // MARK: - Inline header

    private func inlineHeader(summary: StudySummaryData) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(summary.todayLabel)
                .amgiFont(.displayHero)
                .foregroundStyle(palette.textPrimary)
            Text(summary.subtitleLabel)
                .amgiFont(.caption)
                .foregroundStyle(palette.textSecondary)
        }
        .padding(.top, 20)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Ring (scrolls with page)

    private func ringHero(summary: StudySummaryData) -> some View {
        StudyDueRing(summary: summary)
            .frame(maxWidth: .infinity)
    }

    // MARK: - Begin button

    private func beginButton(totalDue: Int) -> some View {
        Button(action: onBeginSession) {
            HStack(spacing: 8) {
                Image(systemName: "play.fill")
                    .font(.system(size: 14, weight: .bold))
                Text(totalDue > 0 ? "Begin session · \(totalDue) cards" : "Nothing due")
                    .amgiFont(.body)
                    .bold()
            }
            .foregroundStyle(totalDue > 0 ? .white : palette.textSecondary)
            .padding(.horizontal, 28)
            .padding(.vertical, 14)
            .frame(maxWidth: 420)
            .background(
                totalDue > 0 ? palette.accent : palette.accentSoft,
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
        .disabled(totalDue == 0)
        .frame(maxWidth: .infinity)
        .animation(.easeInOut(duration: 0.2), value: totalDue)
    }

    // MARK: - Loaded content body

    @ViewBuilder
    private func loadedBody(
        summary: StudySummaryData,
        decks: [StudyDeckRowData],
        readingRecs: [StudyReadingRecData]
    ) -> some View {
        upNextSection(decks: decks)
        if !readingRecs.isEmpty {
            readingRecsSection(readingRecs: readingRecs)
        }
    }

    // MARK: - Up Next

    @ViewBuilder
    private func upNextSection(decks: [StudyDeckRowData]) -> some View {
        if !decks.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader("Up Next")
                    .padding(.bottom, 4)
                VStack(spacing: 0) {
                    StudyDeckListRows(
                        decks: decks,
                        expandedIDs: $expandedIDs,
                        onSelectDeck: { onSelectDeck($0) }
                    )
                }
                .background(
                    palette.surfaceElevated,
                    in: RoundedRectangle(cornerRadius: AmgiRadius.inset, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: AmgiRadius.inset, style: .continuous)
                        .strokeBorder(palette.border, lineWidth: 0.5)
                )
            }
            .padding(.top, 20)
        }
    }

    // MARK: - Reading recommendations

    @ViewBuilder
    private func readingRecsSection(readingRecs: [StudyReadingRecData]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Reading recommendations")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(readingRecs) { rec in
                        StudyReadingRec(data: rec) { onSelectBook(rec.id) }
                    }
                }
                .padding(.horizontal, 1)  // prevents clip at edge
            }
        }
        .padding(.top, 24)
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .amgiFont(.sectionHeading)
            .foregroundStyle(palette.textPrimary)
            .padding(.bottom, 8)
    }
}

// MARK: - Up Next deck list

/// Recursive renderer for the Study "Up Next" deck list. Top-level decks are
/// rendered at `depth == 0`; each expanded deck reveals its due subdecks
/// beneath it (indented under the parent name). Hairline dividers separate
/// sibling rows and match the Library deck-card look.
private struct StudyDeckListRows: View {
    let decks: [StudyDeckRowData]
    let depth: Int
    @Binding var expandedIDs: Set<Int64>
    let onSelectDeck: (Int64) -> Void

    @Environment(\.palette) private var palette

    init(
        decks: [StudyDeckRowData],
        depth: Int = 0,
        expandedIDs: Binding<Set<Int64>>,
        onSelectDeck: @escaping (Int64) -> Void
    ) {
        self.decks = decks
        self.depth = depth
        self._expandedIDs = expandedIDs
        self.onSelectDeck = onSelectDeck
    }

    var body: some View {
        ForEach(Array(decks.enumerated()), id: \.element.id) { index, deck in
            deckGroup(deck, isLastInLevel: index == decks.count - 1)
        }
    }

    @ViewBuilder
    private func deckGroup(_ deck: StudyDeckRowData, isLastInLevel: Bool) -> some View {
        let isExpanded = expandedIDs.contains(deck.id)

        StudyDeckRow(
            data: deck,
            depth: depth,
            isExpanded: isExpanded,
            onTap: { onSelectDeck(deck.id) },
            onToggleExpand: { toggle(deck.id) }
        )
        .padding(.horizontal, 12)

        if isExpanded && !deck.subdecks.isEmpty {
            VStack(spacing: 0) {
                divider
                StudyDeckListRows(
                    decks: deck.subdecks,
                    depth: depth + 1,
                    expandedIDs: $expandedIDs,
                    onSelectDeck: onSelectDeck
                )
            }
            .transition(.opacity)
        }

        if !isLastInLevel {
            divider
        }
    }

    private func toggle(_ id: Int64) {
        withAnimation(.easeInOut(duration: 0.25)) {
            if expandedIDs.contains(id) {
                expandedIDs.remove(id)
            } else {
                expandedIDs.insert(id)
            }
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(palette.border)
            .frame(height: 0.5)
            .padding(.leading, dividerLeading)
    }

    /// Aligns the hairline with the row name column. Top-level decks and their
    /// direct subdecks both start their names 64pt in (12 padding + 40 tile +
    /// 12 spacing); deeper nesting steps in an extra 20pt per level.
    private var dividerLeading: CGFloat {
        64 + CGFloat(max(0, depth - 1)) * 20
    }
}

/// Study content column width, mirroring the Library column so both screens
/// read comfortably on regular-width layouts without pinning the scroll
/// indicator to the column edge.
private enum StudyColumn {
    static let maxWidth: CGFloat = 800
}

// MARK: - Previews

#if DEBUG

private let busySummary = StudySummaryData(
    totalDue: 55,
    newCount: 25,
    learnCount: 17,
    reviewCount: 13,
    todayLabel: "Today",
    subtitleLabel: "Wednesday · 3 decks due",
    deckCount: 3,
    reviewedToday: 38,
    dueBaselineToday: 93
)

private let busyDecks: [StudyDeckRowData] = [
    StudyDeckRowData(
        id: 1, name: "한국어", totalDue: 25,
        newCount: 10, learnCount: 8, reviewCount: 7, isFiltered: false,
        subdecks: [
            StudyDeckRowData(id: 11, name: "Vocab Typing", totalDue: 15,
                             newCount: 6, learnCount: 5, reviewCount: 4, isFiltered: false),
            StudyDeckRowData(id: 12, name: "Sentences", totalDue: 10,
                             newCount: 4, learnCount: 3, reviewCount: 3, isFiltered: false),
        ]
    ),
    StudyDeckRowData(id: 2, name: "ComputerScience", totalDue: 17,
                     newCount: 8, learnCount: 5, reviewCount: 4, isFiltered: false),
    StudyDeckRowData(id: 3, name: "Français", totalDue: 13,
                     newCount: 7, learnCount: 4, reviewCount: 2, isFiltered: false),
]

private let sampleRecs: [StudyReadingRecData] = [
    StudyReadingRecData(id: "lp", title: "어린 왕자",
                        coverImagePath: nil, authorLabel: "Antoine de Saint-Exupéry"),
    StudyReadingRecData(id: "nw", title: "Norwegian Wood",
                        coverImagePath: nil, authorLabel: "Haruki Murakami"),
    StudyReadingRecData(id: "dq", title: "Don Quijote",
                        coverImagePath: nil, authorLabel: "Miguel de Cervantes"),
]

#Preview("Busy day") {
    NavigationStack {
        StudyLandingContent(
            state: .loaded(summary: busySummary, decks: busyDecks, readingRecs: sampleRecs),
            onBeginSession: {},
            onSelectDeck: { _ in },
            onSelectBook: { _ in },
            onRefresh: {}
        )
    }
    .environment(\.palette, .vividLight)
}

#Preview("All done") {
    NavigationStack {
        StudyLandingContent(
            state: .loaded(
                summary: StudySummaryData(
                    totalDue: 0, newCount: 0, learnCount: 0, reviewCount: 0,
                    todayLabel: "Today", subtitleLabel: "Wednesday", deckCount: 0
                ),
                decks: [],
                readingRecs: sampleRecs
            ),
            onBeginSession: {},
            onSelectDeck: { _ in },
            onSelectBook: { _ in },
            onRefresh: {}
        )
    }
    .environment(\.palette, .vividLight)
}

#Preview("Loading") {
    NavigationStack {
        StudyLandingContent(
            state: .loading,
            onBeginSession: {},
            onSelectDeck: { _ in },
            onSelectBook: { _ in },
            onRefresh: {}
        )
    }
    .environment(\.palette, .vividLight)
}

#Preview("Empty") {
    NavigationStack {
        StudyLandingContent(
            state: .empty,
            onBeginSession: {},
            onSelectDeck: { _ in },
            onSelectBook: { _ in },
            onRefresh: {}
        )
    }
    .environment(\.palette, .vividLight)
}
#endif

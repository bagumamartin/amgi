public import SwiftUI
import AmgiTheme

/// Pure rendering surface for the Study landing screen. Owns no I/O.
/// The container loads data and maps it to the single `State` value
/// passed here. The period title lives on the navigation bar.
public enum StudyLandingState: Equatable, Sendable {
    case loading
    case empty
    /// A load that threw. Distinct from `.empty`, which means the
    /// collection has no decks.
    case failed(String)
    case loaded(
        summary: StudySummaryData,
        decks: [StudyDeckRowData],
        continueReading: StudyReadingRecData?
    )
}

public struct StudyLandingContent: View {
    /// Back-compat spelling of ``StudyLandingState``.
    public typealias State = StudyLandingState

    let state: State
    let showsContinueReading: Bool
    let grain: StudyGrain
    let chart: StudyChartModel
    let showsTodayDesk: Bool
    let spanHeadline: String
    let spanRows: [StudyTimeRow]
    let spanRowsLoading: Bool
    let canStepPast: Bool
    let canStepFuture: Bool
    let onBeginSession: () -> Void
    let onSelectDeck: (Int64) -> Void
    let onSelectBook: (String) -> Void
    let onOpenLibrary: () -> Void
    let onRefresh: () async -> Void
    let onStepPast: () -> Void
    let onStepFuture: () -> Void
    let onSelectGrain: (StudyGrain) -> Void
    let onSelectOffset: (Int) -> Void
    let onSelectTimeRow: (StudyTimeRow) -> Void
    let onDoCoolingNow: () -> Void
    let onSelectMonth: (Int) -> Void

    @Environment(\.palette) private var palette
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var choseToWait = false

    public init(
        state: State,
        showsContinueReading: Bool = false,
        grain: StudyGrain = .day,
        chart: StudyChartModel = .bars([]),
        showsTodayDesk: Bool = true,
        spanHeadline: String = "",
        spanRows: [StudyTimeRow] = [],
        spanRowsLoading: Bool = false,
        canStepPast: Bool = true,
        canStepFuture: Bool = true,
        onBeginSession: @escaping () -> Void,
        onSelectDeck: @escaping (Int64) -> Void,
        onSelectBook: @escaping (String) -> Void,
        onOpenLibrary: @escaping () -> Void = {},
        onRefresh: @escaping () async -> Void,
        onStepPast: @escaping () -> Void = {},
        onStepFuture: @escaping () -> Void = {},
        onSelectGrain: @escaping (StudyGrain) -> Void = { _ in },
        onSelectOffset: @escaping (Int) -> Void = { _ in },
        onSelectTimeRow: @escaping (StudyTimeRow) -> Void = { _ in },
        onDoCoolingNow: @escaping () -> Void = {},
        onSelectMonth: @escaping (Int) -> Void = { _ in }
    ) {
        self.state = state
        self.showsContinueReading = showsContinueReading
        self.grain = grain
        self.chart = chart
        self.showsTodayDesk = showsTodayDesk
        self.spanHeadline = spanHeadline
        self.spanRows = spanRows
        self.spanRowsLoading = spanRowsLoading
        self.canStepPast = canStepPast
        self.canStepFuture = canStepFuture
        self.onBeginSession = onBeginSession
        self.onSelectDeck = onSelectDeck
        self.onSelectBook = onSelectBook
        self.onOpenLibrary = onOpenLibrary
        self.onRefresh = onRefresh
        self.onStepPast = onStepPast
        self.onStepFuture = onStepFuture
        self.onSelectGrain = onSelectGrain
        self.onSelectOffset = onSelectOffset
        self.onSelectTimeRow = onSelectTimeRow
        self.onDoCoolingNow = onDoCoolingNow
        self.onSelectMonth = onSelectMonth
    }

    public var body: some View {
        content
            .amgiScreenCanvas()
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .empty:
            ContentUnavailableView {
                Label("No decks yet", systemImage: "rectangle.stack")
            } description: {
                Text("Add a deck in Library, then come back here to study.")
            } actions: {
                Button("Open Library", action: onOpenLibrary)
            }
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't load today", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try again") { Task { await onRefresh() } }
            }
        case let .loaded(summary, decks, continueReading):
            loadedScrollView(summary: summary, decks: decks, continueReading: continueReading)
        }
    }

    private func loadedScrollView(
        summary: StudySummaryData,
        decks: [StudyDeckRowData],
        continueReading: StudyReadingRecData?
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                spanControls
                StudySpanChart(model: chart, onSelectOffset: onSelectOffset, onSelectMonth: onSelectMonth)
                    .contentShape(Rectangle())
                    .simultaneousGesture(periodSwipe)
                if showsTodayDesk {
                    if horizontalSizeClass == .regular {
                        regularLayout(summary: summary, decks: decks, continueReading: continueReading)
                    } else {
                        compactLayout(summary: summary, decks: decks, continueReading: continueReading)
                    }
                } else {
                    spanBody
                }
            }
            .frame(maxWidth: StudyColumn.maxWidth)
            .frame(maxWidth: .infinity)
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
        .refreshable { await onRefresh() }
    }

    /// A clearly horizontal drag steps one period. Vertical movement keeps scrolling.
    private var periodSwipe: some Gesture {
        DragGesture(minimumDistance: 28)
            .onEnded { value in
                let dx = value.translation.width
                let dy = value.translation.height
                guard abs(dx) > abs(dy) * 1.5, abs(dx) > 48 else { return }
                if dx > 0 {
                    if canStepPast { onStepPast() }
                } else if canStepFuture {
                    onStepFuture()
                }
            }
    }

    private var spanControls: some View {
        HStack(spacing: 12) {
            stepButton(systemName: "chevron.left", enabled: canStepPast, action: onStepPast)
            Picker("Span", selection: Binding(get: { grain }, set: { onSelectGrain($0) })) {
                ForEach(StudyGrain.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            stepButton(systemName: "chevron.right", enabled: canStepFuture, action: onStepFuture)
        }
    }

    private func stepButton(systemName: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(enabled ? palette.textPrimary : palette.textTertiary)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private var spanBody: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !spanHeadline.isEmpty {
                Text(spanHeadline)
                    .amgiFont(.sectionHeading)
                    .foregroundStyle(palette.textPrimary)
            }
            if spanRowsLoading && spanRows.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 12)
            } else if !spanRows.isEmpty {
                timeRowsSection
            }
        }
    }

    private var timeRowsSection: some View {
        VStack(spacing: 0) {
            ForEach(Array(spanRows.enumerated()), id: \.element.id) { index, row in
                Button {
                    onSelectTimeRow(row)
                } label: {
                    HStack(spacing: 12) {
                        Text(row.title)
                            .amgiFont(.body)
                            .fontWeight(.semibold)
                            .foregroundStyle(palette.textPrimary)
                        Spacer(minLength: 12)
                        Text("\(row.count)")
                            .amgiFont(.body)
                            .monospacedDigit()
                            .foregroundStyle(palette.textSecondary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(palette.textTertiary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.pressScale)
                if index < spanRows.count - 1 {
                    Rectangle()
                        .fill(palette.border)
                        .frame(height: 0.5)
                        .padding(.leading, 12)
                }
            }
        }
        .background(palette.surfaceElevated, in: RoundedRectangle(cornerRadius: AmgiRadius.inset, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AmgiRadius.inset, style: .continuous)
                .strokeBorder(palette.border, lineWidth: 0.5)
        )
    }

    private func compactLayout(
        summary: StudySummaryData,
        decks: [StudyDeckRowData],
        continueReading: StudyReadingRecData?
    ) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 16) {
                StudyDueRing(summary: summary, diameter: 156)
                legend(summary)
            }
            .frame(maxWidth: .infinity)
            primary(summary)
            sections(summary: summary, decks: decks, continueReading: continueReading)
        }
    }

    private func regularLayout(
        summary: StudySummaryData,
        decks: [StudyDeckRowData],
        continueReading: StudyReadingRecData?
    ) -> some View {
        HStack(alignment: .top, spacing: 28) {
            VStack(alignment: .leading, spacing: 16) {
                StudyDueRing(summary: summary, diameter: 188)
                    .frame(maxWidth: .infinity)
                legend(summary)
                primary(summary)
            }
            .frame(maxWidth: 360)
            sections(summary: summary, decks: decks, continueReading: continueReading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Legend

    private func legend(_ summary: StudySummaryData) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if summary.phase == .caughtUp {
                Text(summary.caughtUpTitle)
                    .amgiFont(.sectionHeading)
                    .foregroundStyle(palette.textPrimary)
            } else {
                mixLine("New", count: summary.newCount, color: palette.cardStateNew)
                mixLine("Learn", count: summary.learnCount, color: palette.cardStateLearning)
                mixLine("Review", count: summary.reviewCount, color: palette.cardStateReview)
            }
            streakLine(summary)
            if summary.learningReturning == 0 || choseToWait {
                note(summary.returningNote)
            }
            if summary.phase != .caughtUp, summary.cardsRemainingToClose > 0 {
                note("\(summary.cardsRemainingToClose) to close the ring")
            }
            if summary.phase == .caughtUp {
                note(summary.timeStudiedLabel)
                note(summary.tomorrowLabel)
            }
            note(summary.rolloverNote)
            note(summary.backlogNote)
            if summary.deckCount > 0, summary.phase != .caughtUp {
                let n = summary.deckCount
                note("across \(n) deck\(n == 1 ? "" : "s")")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func mixLine(_ name: String, count: Int, color: Color) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(name)
                .amgiFont(.caption)
                .foregroundStyle(palette.textSecondary)
            Spacer(minLength: 8)
            Text("\(count)")
                .amgiFont(.caption)
                .monospacedDigit()
                .foregroundStyle(palette.textPrimary)
        }
    }

    @ViewBuilder
    private func streakLine(_ summary: StudySummaryData) -> some View {
        if summary.streakPending {
            Text("36-day streak")
                .amgiFont(.caption)
                .foregroundStyle(palette.textSecondary)
                .redacted(reason: .placeholder)
        } else if let label = summary.streakLabel {
            Text(label)
                .amgiFont(.caption)
                .foregroundStyle(palette.textSecondary)
        }
    }

    @ViewBuilder
    private func note(_ text: String?) -> some View {
        if let text {
            Text(text)
                .amgiFont(.caption)
                .foregroundStyle(palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Primary

    @ViewBuilder
    private func primary(_ summary: StudySummaryData) -> some View {
        if let title = summary.primaryActionTitle {
            VStack(spacing: 8) {
                Button(action: onBeginSession) {
                    HStack(spacing: 8) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 14, weight: .bold))
                        Text(title)
                            .amgiFont(.body)
                            .bold()
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity)
                    .background(palette.accent, in: Capsule())
                }
                .buttonStyle(.pressScale)
                if !summary.sessionShape.isEmpty {
                    Text(sessionLine(summary))
                        .amgiFont(.caption)
                        .foregroundStyle(palette.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func sessionLine(_ summary: StudySummaryData) -> String {
        if let estimate = summary.estimateLabel, summary.phase != .caughtUp {
            return "\(estimate) · \(summary.sessionShape)"
        }
        return summary.sessionShape
    }

    // MARK: - Sections

    @ViewBuilder
    private func sections(
        summary: StudySummaryData,
        decks: [StudyDeckRowData],
        continueReading: StudyReadingRecData?
    ) -> some View {
        let studyDecks = decks.filter { !$0.isFiltered }
        let extra = decks.filter(\.isFiltered)
        VStack(alignment: .leading, spacing: 24) {
            if summary.phase != .caughtUp {
                if !studyDecks.isEmpty {
                    deckSection("Study one deck", decks: studyDecks)
                }
                if !extra.isEmpty {
                    deckSection("Extra session", decks: extra)
                }
            } else {
                if summary.learningReturning > 0, !choseToWait {
                    SessionCoolingCard(
                        count: summary.learningReturning,
                        onWait: { choseToWait = true },
                        onDoNow: onDoCoolingNow
                    )
                }
                if showsContinueReading, let continueReading {
                    continueReadingSection(continueReading)
                }
            }
        }
    }

    private func deckSection(_ title: String, decks: [StudyDeckRowData]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(title)
            VStack(spacing: 0) {
                ForEach(Array(decks.enumerated()), id: \.element.id) { index, deck in
                    StudyDeckRow(data: deck) { onSelectDeck(deck.id) }
                    if index < decks.count - 1 {
                        Rectangle()
                            .fill(palette.border)
                            .frame(height: 0.5)
                            .padding(.leading, 64)
                    }
                }
            }
            .background(palette.surfaceElevated, in: RoundedRectangle(cornerRadius: AmgiRadius.inset, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AmgiRadius.inset, style: .continuous)
                    .strokeBorder(palette.border, lineWidth: 0.5)
            )
        }
    }

    private func continueReadingSection(_ rec: StudyReadingRecData) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Continue reading")
            Button { onSelectBook(rec.id) } label: {
                HStack(spacing: 12) {
                    Image(systemName: "book")
                        .amgiFont(.body)
                        .foregroundStyle(palette.accent)
                        .frame(width: 40, height: 40)
                        .background(palette.accentSoft, in: RoundedRectangle(cornerRadius: AmgiRadius.control, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(rec.title)
                            .amgiFont(.body)
                            .fontWeight(.semibold)
                            .foregroundStyle(palette.textPrimary)
                            .lineLimit(1)
                        if !rec.authorLabel.isEmpty {
                            Text(rec.authorLabel)
                                .amgiFont(.caption)
                                .foregroundStyle(palette.textSecondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 12)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(palette.textTertiary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressScale)
            .background(palette.surfaceElevated, in: RoundedRectangle(cornerRadius: AmgiRadius.inset, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AmgiRadius.inset, style: .continuous)
                    .strokeBorder(palette.border, lineWidth: 0.5)
            )
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .amgiFont(.sectionHeading)
            .foregroundStyle(palette.textPrimary)
            .padding(.bottom, 8)
    }
}

private enum StudyColumn {
    static let maxWidth: CGFloat = 880
}

// MARK: - Previews

#if DEBUG

private let dueSummary = StudySummaryData(
    totalDue: 55,
    newCount: 25,
    learnCount: 17,
    reviewCount: 13,
    todayLabel: "Today",
    subtitleLabel: "Wednesday · 3 decks due",
    deckCount: 3,
    reviewedToday: 0,
    dueBaselineToday: 55,
    learningReturning: 4,
    streak: 12,
    rolloverNote: "New day in 2 hours"
)

private let leftoverSummary = StudySummaryData(
    totalDue: 22,
    newCount: 8,
    learnCount: 4,
    reviewCount: 10,
    todayLabel: "Today",
    subtitleLabel: "Wednesday · 2 decks due",
    deckCount: 2,
    reviewedToday: 38,
    dueBaselineToday: 60,
    answerCount: 40,
    answerMillis: 12 * 60 * 1000,
    streak: 12
)

private let caughtUpSummary = StudySummaryData(
    totalDue: 0,
    newCount: 0,
    learnCount: 0,
    reviewCount: 0,
    todayLabel: "Today",
    subtitleLabel: "Wednesday",
    deckCount: 0,
    reviewedToday: 55,
    dueBaselineToday: 55,
    learningReturning: 8,
    answerCount: 60,
    answerMillis: 18 * 60 * 1000,
    streak: 36,
    tomorrowDue: 40,
    backlogNote: "Daily limits are holding reviews back"
)

private let busyDecks: [StudyDeckRowData] = [
    StudyDeckRowData(
        id: 1, name: "한국어", totalDue: 25,
        newCount: 10, learnCount: 8, reviewCount: 7, isFiltered: false,
        includesLabel: "Includes Vocab, Sentences"
    ),
    StudyDeckRowData(
        id: 2, name: "ComputerScience", totalDue: 17,
        newCount: 8, learnCount: 5, reviewCount: 4, isFiltered: false
    ),
    StudyDeckRowData(
        id: 9, name: "Study · Ahead", totalDue: 13,
        newCount: 0, learnCount: 0, reviewCount: 13, isFiltered: true
    ),
]

private let sampleReading = StudyReadingRecData(
    id: "lp", title: "어린 왕자",
    coverImagePath: nil, authorLabel: "Antoine de Saint-Exupéry"
)

#Preview("Due") {
    NavigationStack {
        StudyLandingContent(
            state: .loaded(summary: dueSummary, decks: busyDecks, continueReading: sampleReading),
            onBeginSession: {},
            onSelectDeck: { _ in },
            onSelectBook: { _ in },
            onRefresh: {}
        )
        .navigationTitle("Today")
    }
    .environment(\.palette, .vividLight)
}

#Preview("Leftover") {
    NavigationStack {
        StudyLandingContent(
            state: .loaded(summary: leftoverSummary, decks: busyDecks, continueReading: nil),
            onBeginSession: {},
            onSelectDeck: { _ in },
            onSelectBook: { _ in },
            onRefresh: {}
        )
        .navigationTitle("Today")
    }
    .environment(\.palette, .vividLight)
}

#Preview("Caught up") {
    NavigationStack {
        StudyLandingContent(
            state: .loaded(summary: caughtUpSummary, decks: [], continueReading: sampleReading),
            showsContinueReading: true,
            onBeginSession: {},
            onSelectDeck: { _ in },
            onSelectBook: { _ in },
            onRefresh: {}
        )
        .navigationTitle("Today")
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

#Preview("Failed") {
    NavigationStack {
        StudyLandingContent(
            state: .failed("The collection could not be opened."),
            onBeginSession: {},
            onSelectDeck: { _ in },
            onSelectBook: { _ in },
            onRefresh: {}
        )
    }
    .environment(\.palette, .vividLight)
}
#endif

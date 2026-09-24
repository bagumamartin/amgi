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
    let scopeLabel: String?
    let onShowAllDecks: () -> Void
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
    let onExploreHistory: () -> Void
    /// Secondary workload data. These stay separate from the loaded summary
    /// so a slow forecast or deck-relevance request never blocks the primary
    /// Today action.
    let forecast: StudyForecastData?
    let todayAttentionRows: [StudyTimeRow]
    let spanDeckRows: [StudyTimeRow]
    let spanDeckRowsLoading: Bool
    let spanDeckTitle: String
    let showsRelevantDecks: Bool
    let spanRowsError: String?
    let spanDeckRowsError: String?
    let workloadError: String?

    @Environment(\.palette) private var palette
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var choseToWait = false

    private var prefersWideLayout: Bool {
        #if os(macOS)
        true
        #else
        horizontalSizeClass == .regular
        #endif
    }

    public init(
        state: State,
        showsContinueReading: Bool = false,
        scopeLabel: String? = nil,
        onShowAllDecks: @escaping () -> Void = {},
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
        onSelectMonth: @escaping (Int) -> Void = { _ in },
        onExploreHistory: @escaping () -> Void = {},
        forecast: StudyForecastData? = nil,
        todayAttentionRows: [StudyTimeRow] = [],
        spanDeckRows: [StudyTimeRow] = [],
        spanDeckRowsLoading: Bool = false,
        spanDeckTitle: String = "Relevant decks",
        showsRelevantDecks: Bool = false,
        spanRowsError: String? = nil,
        spanDeckRowsError: String? = nil,
        workloadError: String? = nil
    ) {
        self.state = state
        self.showsContinueReading = showsContinueReading
        self.scopeLabel = scopeLabel
        self.onShowAllDecks = onShowAllDecks
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
        self.onExploreHistory = onExploreHistory
        self.forecast = forecast
        self.todayAttentionRows = todayAttentionRows
        self.spanDeckRows = spanDeckRows
        self.spanDeckRowsLoading = spanDeckRowsLoading
        self.spanDeckTitle = spanDeckTitle
        self.showsRelevantDecks = showsRelevantDecks
        self.spanRowsError = spanRowsError
        self.spanDeckRowsError = spanDeckRowsError
        self.workloadError = workloadError
    }

    public var body: some View {
        content
            .amgiScreenCanvas()
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            VStack(spacing: AmgiSpacing.md) {
                ProgressView()
                    .controlSize(.large)
                Text("Preparing your study desk…")
                    .amgiFont(.body)
                    .foregroundStyle(palette.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .empty:
            ContentUnavailableView {
                Label("No decks yet", systemImage: "rectangle.stack")
            } description: {
                Text("Add a deck in Library, then come back here to study.")
            } actions: {
                Button("Open Library", action: onOpenLibrary)
                    .buttonStyle(AmgiPrimaryButtonStyle())
            }
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't load today", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try again") { Task { await onRefresh() } }
                    .buttonStyle(AmgiPrimaryButtonStyle())
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
            LazyVStack(alignment: .leading, spacing: AmgiSpacing.xl) {
                if showsTodayDesk {
                    todayLayout(
                        summary: summary,
                        decks: decks,
                        continueReading: continueReading
                    )
                } else {
                    historyLayout
                }
            }
            .frame(maxWidth: StudyColumn.maxWidth)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, AmgiSpacing.lg)
            .padding(.bottom, AmgiSpacing.xxl)
        }
        .refreshable { await onRefresh() }
        .onChange(of: summary.totalDue) { _, _ in
            choseToWait = false
        }
        .onChange(of: showsTodayDesk) { _, _ in
            choseToWait = false
        }
    }

    private func todayLayout(
        summary: StudySummaryData,
        decks: [StudyDeckRowData],
        continueReading: StudyReadingRecData?
    ) -> some View {
        VStack(alignment: .leading, spacing: AmgiSpacing.xl) {
            todayHero(summary)
            if let forecast {
                StudyForecastCard(data: forecast, onSelectDay: onSelectOffset)
            }
            if !prefersWideLayout {
                legend(summary, includeMix: false)
            }
            if !todayAttentionRows.isEmpty {
                attentionSection(title: "Needs attention", rows: todayAttentionRows)
            }
            if let workloadError {
                inlineError(workloadError)
            }
            if prefersWideLayout {
                regularTodayColumns(summary: summary, decks: decks, continueReading: continueReading)
            } else {
                compactTodayColumns(summary: summary, decks: decks, continueReading: continueReading)
            }
            activityCard
        }
    }

    private var historyLayout: some View {
        VStack(alignment: .leading, spacing: AmgiSpacing.xl) {
            spanControls
            if !spanHeadline.isEmpty {
                Text(spanHeadline)
                    .amgiFont(.sectionHeading)
                    .foregroundStyle(palette.textPrimary)
            }
            activityCard
            if spanRowsLoading && spanRows.isEmpty {
                loadingCard(message: "Loading this period…")
            } else if !spanRows.isEmpty {
                VStack(alignment: .leading, spacing: AmgiSpacing.sm) {
                    Text("Study cuts")
                        .amgiFont(.sectionHeading)
                        .foregroundStyle(palette.textPrimary)
                    timeRowsSection
                }
            }
            if let spanRowsError {
                inlineError(spanRowsError)
            }
            if showsRelevantDecks {
                relevantDecksSection
            }
        }
    }

    private var activityCard: some View {
        AmgiCard(
            background: .surface,
            shadow: palette.shadows.sm,
            cornerRadius: AmgiRadius.inset,
            contentInsets: EdgeInsets(
                top: AmgiSpacing.lg,
                leading: AmgiSpacing.lg,
                bottom: AmgiSpacing.lg,
                trailing: AmgiSpacing.lg
            )
        ) {
            VStack(alignment: .leading, spacing: AmgiSpacing.md) {
                HStack {
                    Text(showsTodayDesk ? "Your activity" : "Review activity")
                        .amgiFont(.cardTitle)
                        .foregroundStyle(palette.textPrimary)
                    Spacer()
                    if showsTodayDesk {
                        Button("Explore history", action: onExploreHistory)
                            .amgiFont(.caption)
                            .foregroundStyle(palette.accent)
                            .accessibilityHint("Opens yesterday's review history")
                    } else {
                        Text("Recorded answers")
                            .amgiFont(.caption)
                            .foregroundStyle(palette.textTertiary)
                    }
                }
                StudySpanChart(
                    model: chart,
                    onSelectOffset: onSelectOffset,
                    onSelectMonth: onSelectMonth
                )
                .contentShape(Rectangle())
                .simultaneousGesture(periodSwipe)
                if !showsTodayDesk {
                    HStack(spacing: AmgiSpacing.md) {
                        legendKey(title: "Answers", color: palette.accent)
                        legendKey(title: "Scheduled", color: palette.textTertiary)
                    }
                }
            }
        }
    }

    private func todayHero(_ summary: StudySummaryData) -> some View {
        AmgiCard(
            background: .surfaceElevated,
            shadow: palette.shadows.md,
            cornerRadius: AmgiRadius.hero
        ) {
            Group {
                if prefersWideLayout {
                    HStack(alignment: .center, spacing: AmgiSpacing.xl) {
                        todayHeroCopy(summary)
                        StudyDueRing(summary: summary, diameter: 188)
                    }
                } else {
                    VStack(alignment: .leading, spacing: AmgiSpacing.lg) {
                        todayHeroCopy(summary)
                        StudyDueRing(summary: summary, diameter: 156)
                            .frame(maxWidth: .infinity)
                        primary(summary)
                    }
                }
            }
        }
    }

    private func todayHeroCopy(_ summary: StudySummaryData) -> some View {
        VStack(alignment: .leading, spacing: AmgiSpacing.sm) {
            HStack(spacing: AmgiSpacing.sm) {
                Text(scopeLabel.map { "TODAY · \($0)" } ?? "TODAY")
                    .amgiFont(size: 13, weight: .semibold, tracking: 0.4, relativeTo: .footnote)
                    .foregroundStyle(palette.textTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer(minLength: 4)
                if scopeLabel != nil {
                    Button("All decks", action: onShowAllDecks)
                        .amgiFont(.caption)
                        .foregroundStyle(palette.accent)
                }
            }
            Text(summary.phase == .caughtUp ? summary.caughtUpTitle : "\(summary.totalDue) cards left")
                .amgiFont(.displayHero)
                .foregroundStyle(palette.textPrimary)
            if let estimate = summary.estimateLabel {
                Text(estimate)
                    .amgiFont(.body)
                    .foregroundStyle(palette.textSecondary)
            } else if summary.phase == .caughtUp {
                Text("Your next review is scheduled by the deck limits.")
                    .amgiFont(.body)
                    .foregroundStyle(palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if prefersWideLayout {
                primary(summary)
            }
            categoryLegend(summary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func categoryLegend(_ summary: StudySummaryData) -> some View {
        VStack(alignment: .leading, spacing: AmgiSpacing.xs) {
            Text("Remaining mix")
                .amgiFont(.micro)
                .foregroundStyle(palette.textTertiary)
            HStack(spacing: AmgiSpacing.md) {
                legendItem("New", count: summary.newCount, color: palette.cardStateNew)
                legendItem("Learn", count: summary.learnCount, color: palette.cardStateLearning)
                legendItem("Review", count: summary.reviewCount, color: palette.cardStateReview)
            }
        }
        .padding(.top, AmgiSpacing.xs)
    }

    private func legendKey(title: String, color: Color) -> some View {
        HStack(spacing: AmgiSpacing.xs) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(title)
                .amgiFont(.micro)
                .foregroundStyle(palette.textTertiary)
        }
    }

    private func legendItem(_ title: String, count: Int, color: Color) -> some View {
        HStack(spacing: AmgiSpacing.xs) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(title)
                .amgiFont(.micro)
                .foregroundStyle(palette.textSecondary)
            Text("\(count)")
                .amgiFont(.micro, .monospacedDigits)
                .foregroundStyle(palette.textPrimary)
        }
    }

    private func compactTodayColumns(
        summary: StudySummaryData,
        decks: [StudyDeckRowData],
        continueReading: StudyReadingRecData?
    ) -> some View {
        VStack(alignment: .leading, spacing: AmgiSpacing.xl) {
            todayQueue(summary: summary, decks: decks, continueReading: continueReading)
        }
    }

    private func regularTodayColumns(
        summary: StudySummaryData,
        decks: [StudyDeckRowData],
        continueReading: StudyReadingRecData?
    ) -> some View {
        HStack(alignment: .top, spacing: AmgiSpacing.xl) {
            VStack(alignment: .leading, spacing: AmgiSpacing.lg) {
                legend(summary, includeMix: false)
            }
            .frame(maxWidth: 280)
            todayQueue(summary: summary, decks: decks, continueReading: continueReading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func todayQueue(
        summary: StudySummaryData,
        decks: [StudyDeckRowData],
        continueReading: StudyReadingRecData?
    ) -> some View {
        VStack(alignment: .leading, spacing: AmgiSpacing.xl) {
            if summary.phase != .caughtUp {
                deckSections(decks)
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

    private var relevantDecksSection: some View {
        VStack(alignment: .leading, spacing: AmgiSpacing.sm) {
            Text(spanDeckTitle)
                .amgiFont(.sectionHeading)
                .foregroundStyle(palette.textPrimary)
            Text("Counts use each card's current deck placement.")
                .amgiFont(.caption)
                .foregroundStyle(palette.textTertiary)
            if spanDeckRowsLoading {
                loadingCard(message: "Finding relevant decks…")
            } else if !spanDeckRows.isEmpty {
                timeRowList(spanDeckRows)
            } else {
                Text("No deck activity to show for this day.")
                    .amgiFont(.caption)
                    .foregroundStyle(palette.textTertiary)
                    .padding(.vertical, AmgiSpacing.sm)
            }
            if let spanDeckRowsError {
                inlineError(spanDeckRowsError)
            }
        }
    }

    private func inlineError(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .amgiFont(.caption)
            .foregroundStyle(palette.warning)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func loadingCard(message: String) -> some View {
        HStack(spacing: AmgiSpacing.sm) {
            ProgressView()
            Text(message)
                .amgiFont(.caption)
                .foregroundStyle(palette.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, AmgiSpacing.md)
    }

    private func attentionSection(title: String, rows: [StudyTimeRow]) -> some View {
        VStack(alignment: .leading, spacing: AmgiSpacing.sm) {
            Text(title)
                .amgiFont(.sectionHeading)
                .foregroundStyle(palette.textPrimary)
            timeRowList(rows)
        }
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
        VStack(alignment: .leading, spacing: AmgiSpacing.sm) {
            Text("History")
                .amgiFont(.cardTitle)
                .foregroundStyle(palette.textPrimary)
            HStack(spacing: AmgiSpacing.sm) {
                stepButton(
                    systemName: "chevron.left",
                    label: "Previous period",
                    enabled: canStepPast,
                    action: onStepPast
                )
                Picker("Period", selection: Binding(get: { grain }, set: { onSelectGrain($0) })) {
                    ForEach(StudyGrain.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("History period")
                stepButton(
                    systemName: "chevron.right",
                    label: "Next period",
                    enabled: canStepFuture,
                    action: onStepFuture
                )
            }
        }
    }

    private func stepButton(
        systemName: String,
        label: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(enabled ? palette.textPrimary : palette.textTertiary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
        .accessibilityHint(enabled ? "Double-tap to change period" : "No further period")
    }

    private var timeRowsSection: some View {
        timeRowList(spanRows)
    }

    private func timeRowList(_ rows: [StudyTimeRow]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                Button {
                    onSelectTimeRow(row)
                } label: {
                    HStack(spacing: AmgiSpacing.md) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.title)
                                .amgiFont(.body)
                                .fontWeight(.semibold)
                                .foregroundStyle(palette.textPrimary)
                            if let subtitle = row.subtitle {
                                Text(subtitle)
                                    .amgiFont(.caption)
                                    .foregroundStyle(palette.textTertiary)
                                    .lineLimit(2)
                            }
                        }
                        Spacer(minLength: AmgiSpacing.md)
                        Text("\(row.count)")
                            .amgiFont(.body, .monospacedDigits)
                            .foregroundStyle(palette.textSecondary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(palette.textTertiary)
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, AmgiSpacing.lg)
                    .padding(.vertical, AmgiSpacing.md)
                    .frame(minHeight: 52)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.pressScale)
                .accessibilityLabel(accessibilityLabel(for: row))
                if index < rows.count - 1 {
                    Rectangle()
                        .fill(palette.border)
                        .frame(height: 0.5)
                        .padding(.leading, AmgiSpacing.lg)
                }
            }
        }
        .background(palette.surfaceElevated, in: RoundedRectangle(cornerRadius: AmgiRadius.inset, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AmgiRadius.inset, style: .continuous)
                .strokeBorder(palette.border, lineWidth: 0.5)
        )
    }

    private func accessibilityLabel(for row: StudyTimeRow) -> String {
        var parts = [row.title, "\(row.count) cards"]
        if let subtitle = row.subtitle { parts.append(subtitle) }
        return parts.joined(separator: ", ")
    }

    private func deckSections(_ decks: [StudyDeckRowData]) -> some View {
        let studyDecks = decks.filter { !$0.isFiltered }
        let extra = decks.filter(\.isFiltered)
        return VStack(alignment: .leading, spacing: AmgiSpacing.xl) {
            if !studyDecks.isEmpty {
                deckSection("Up next", decks: studyDecks)
            }
            if !extra.isEmpty {
                deckSection("Extra session", decks: extra)
            }
            if studyDecks.isEmpty && extra.isEmpty {
                Text("No answerable decks right now.")
                    .amgiFont(.caption)
                    .foregroundStyle(palette.textTertiary)
            }
        }
    }

    // MARK: - Legend

    private func legend(_ summary: StudySummaryData, includeMix: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if includeMix {
                if summary.phase == .caughtUp {
                    Text(summary.caughtUpTitle)
                        .amgiFont(.sectionHeading)
                        .foregroundStyle(palette.textPrimary)
                } else {
                    mixLine("New", count: summary.newCount, color: palette.cardStateNew)
                    mixLine("Learn", count: summary.learnCount, color: palette.cardStateLearning)
                    mixLine("Review", count: summary.reviewCount, color: palette.cardStateReview)
                }
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
            if (forecast?.backlogCount ?? 0) == 0 {
                note(summary.backlogNote)
            }
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
            VStack(spacing: AmgiSpacing.sm) {
                Button(action: onBeginSession) {
                    HStack(spacing: AmgiSpacing.sm) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 14, weight: .bold))
                        Text(title)
                            .bold()
                    }
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 44)
                }
                .buttonStyle(AmgiPrimaryButtonStyle())
                .accessibilityHint("Begins a review session using the current deck limits")
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

    private func deckSection(_ title: String, decks: [StudyDeckRowData]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(title)
            LazyVStack(spacing: 0) {
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
        VStack(alignment: .leading, spacing: AmgiSpacing.sm) {
            sectionHeader("Continue reading")
            HStack(alignment: .center, spacing: AmgiSpacing.lg) {
                StudyReadingRec(data: rec) { onSelectBook(rec.id) }
                VStack(alignment: .leading, spacing: AmgiSpacing.sm) {
                    Text("Pick up where you left off")
                        .amgiFont(.caption)
                        .foregroundStyle(palette.textTertiary)
                    Text(rec.title)
                        .amgiFont(.cardTitle)
                        .foregroundStyle(palette.textPrimary)
                        .lineLimit(3)
                    if !rec.authorLabel.isEmpty {
                        Text(rec.authorLabel)
                            .amgiFont(.caption)
                            .foregroundStyle(palette.textSecondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                    Label("Resume", systemImage: "book.fill")
                        .amgiFont(.bodyEmphasis)
                        .foregroundStyle(palette.accent)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(AmgiSpacing.lg)
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

private let sampleForecast = StudyForecastData(
    days: [
        StudyForecastDay(offset: 0, label: "Today", accessibilityLabel: "Today, 55 cards", count: 55),
        StudyForecastDay(offset: -1, label: "Tomorrow", accessibilityLabel: "Tomorrow, 40 cards", count: 40),
        StudyForecastDay(offset: -2, label: "Thu", accessibilityLabel: "Thursday, 22 cards", count: 22),
        StudyForecastDay(offset: -3, label: "Fri", accessibilityLabel: "Friday, 60 cards", count: 60),
        StudyForecastDay(offset: -4, label: "Sat", accessibilityLabel: "Saturday, 18 cards", count: 18),
        StudyForecastDay(offset: -5, label: "Sun", accessibilityLabel: "Sunday, 8 cards", count: 8),
        StudyForecastDay(offset: -6, label: "Mon", accessibilityLabel: "Monday, 12 cards", count: 12)
    ],
    tomorrowDue: 40,
    dailyLoad: 34,
    backlogCount: 18,
    hasBacklog: true,
    unstableDueCount: 7,
    fsrsEnabled: true
)

#Preview("Due") {
    NavigationStack {
        StudyLandingContent(
            state: .loaded(summary: dueSummary, decks: busyDecks, continueReading: sampleReading),
            onBeginSession: {},
            onSelectDeck: { _ in },
            onSelectBook: { _ in },
            onRefresh: {},
            forecast: sampleForecast
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
            onRefresh: {},
            forecast: sampleForecast
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

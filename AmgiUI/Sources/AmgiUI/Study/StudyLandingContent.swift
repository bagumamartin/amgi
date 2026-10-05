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

enum StudyContentLayout: Equatable {
    case compact
    case regular
    case wide

    static let minimumRegularWidth: CGFloat = 700
    static let minimumWideWidth: CGFloat = 720

    static func resolve(
        availableWidth: CGFloat,
        isAccessibilitySize: Bool
    ) -> StudyContentLayout {
        if isAccessibilitySize { return .compact }
        if availableWidth >= minimumWideWidth { return .wide }
        if availableWidth >= minimumRegularWidth { return .regular }
        return .compact
    }

    var presentation: StudyDashboardPresentation {
        switch self {
        case .compact: .compact
        case .regular: .regular
        case .wide: .wide
        }
    }

    var maximumContentWidth: CGFloat {
        switch self {
        case .compact: 640
        case .regular: 920
        case .wide: 1_280
        }
    }

    var horizontalPadding: CGFloat {
        switch self {
        case .compact: AmgiSpacing.lg
        case .regular: AmgiSpacing.xl
        case .wide: 20
        }
    }

    var columnSpacing: CGFloat {
        switch self {
        case .compact, .regular: AmgiSpacing.xl
        case .wide: 14
        }
    }
}

enum StudyDashboardPresentation: Sendable {
    case compact
    case medium
    case regular
    case wide

    /// The root iPad detail can be wide enough for two columns while still
    /// being too narrow for the roomy desktop card metrics. Keep that as a
    /// named policy instead of burying the breakpoint in the view body.
    static let mediumWideMaximumWidth: CGFloat = 820

    static func resolveWideLayout(availableWidth: CGFloat) -> StudyDashboardPresentation {
        availableWidth < mediumWideMaximumWidth ? .medium : .wide
    }
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var choseToWait = false

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
        GeometryReader { proxy in
            let layout = StudyContentLayout.resolve(
                availableWidth: proxy.size.width,
                isAccessibilitySize: dynamicTypeSize.isAccessibilitySize
            )
            ScrollView {
                LazyVStack(alignment: .leading, spacing: layout.columnSpacing) {
                    if showsTodayDesk {
                        todayLayout(
                            summary: summary,
                            decks: decks,
                            continueReading: continueReading,
                            layout: layout,
                            availableWidth: proxy.size.width
                        )
                    } else {
                        historyLayout(layout: layout)
                    }
                }
                .frame(maxWidth: layout.maximumContentWidth)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, layout.horizontalPadding)
                .padding(.bottom, 96)
            }
            .refreshable { await onRefresh() }
        }
        .onChange(of: summary.totalDue) { _, _ in
            choseToWait = false
        }
        .onChange(of: showsTodayDesk) { _, _ in
            choseToWait = false
        }
    }

    @ViewBuilder
    private func todayLayout(
        summary: StudySummaryData,
        decks: [StudyDeckRowData],
        continueReading: StudyReadingRecData?,
        layout: StudyContentLayout,
        availableWidth: CGFloat
    ) -> some View {
        switch layout {
        case .compact, .regular:
            VStack(alignment: .leading, spacing: layout.columnSpacing) {
                todayHero(summary, presentation: layout.presentation)
                forecastCard(presentation: layout.presentation)
                supplementaryTodayContent
                todayQueue(
                    summary: summary,
                    decks: decks,
                    continueReading: continueReading
                )
                activityCard(presentation: layout.presentation)
            }
        case .wide:
            wideTodayLayout(
                summary: summary,
                decks: decks,
                continueReading: continueReading,
                availableWidth: availableWidth
            )
        }
    }

    private func wideTodayLayout(
        summary: StudySummaryData,
        decks: [StudyDeckRowData],
        continueReading: StudyReadingRecData?,
        availableWidth: CGFloat
    ) -> some View {
        let presentation = StudyDashboardPresentation.resolveWideLayout(
            availableWidth: availableWidth
        )
        return VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top, spacing: 14) {
                todayHero(summary, presentation: presentation)
                    .frame(minWidth: 360, maxWidth: .infinity)
                forecastCard(presentation: presentation)
                    .frame(minWidth: 240, idealWidth: 300, maxWidth: 340)
            }

            if hasTodayQueueContent(
                summary: summary,
                decks: decks,
                continueReading: continueReading
            ) {
                HStack(alignment: .top, spacing: 14) {
                    todayQueue(
                        summary: summary,
                        decks: decks,
                        continueReading: continueReading
                    )
                    .frame(minWidth: 360, maxWidth: .infinity)

                    VStack(alignment: .leading, spacing: 24) {
                        supplementaryTodayContent
                        activityCard(presentation: presentation)
                    }
                    .frame(minWidth: 260, idealWidth: 320, maxWidth: 360)
                }
            } else {
                VStack(alignment: .leading, spacing: 24) {
                    supplementaryTodayContent
                    activityCard(presentation: presentation)
                }
            }
        }
    }

    @ViewBuilder
    private var supplementaryTodayContent: some View {
        if !todayAttentionRows.isEmpty {
            attentionSection(title: "Needs attention", rows: todayAttentionRows)
        }
        if let workloadError {
            inlineError(workloadError)
        }
    }

    @ViewBuilder
    private func forecastCard(presentation: StudyDashboardPresentation) -> some View {
        if let forecast {
            StudyForecastCard(
                data: forecast,
                onSelectDay: onSelectOffset,
                presentation: presentation
            )
        }
    }

    private func hasTodayQueueContent(
        summary: StudySummaryData,
        decks: [StudyDeckRowData],
        continueReading: StudyReadingRecData?
    ) -> Bool {
        if summary.phase != .caughtUp {
            return !decks.isEmpty
        }
        if summary.learningReturning > 0, !choseToWait {
            return true
        }
        return showsContinueReading && continueReading != nil
    }

    private func historyLayout(layout: StudyContentLayout) -> some View {
        VStack(alignment: .leading, spacing: layout.columnSpacing) {
            spanControls
            if !spanHeadline.isEmpty {
                Text(spanHeadline)
                    .amgiFont(.sectionHeading)
                    .foregroundStyle(palette.textPrimary)
            }

            if layout == .wide {
                HStack(alignment: .top, spacing: 24) {
                    activityCard(presentation: .wide)
                        .frame(minWidth: 620, maxWidth: .infinity)
                    studyCutsContent
                        .frame(minWidth: 340, idealWidth: 400, maxWidth: 440)
                }
                if let spanRowsError {
                    inlineError(spanRowsError)
                }
                if showsRelevantDecks {
                    relevantDecksSection
                }
            } else {
                activityCard(presentation: layout.presentation)
                studyCutsContent
                if let spanRowsError {
                    inlineError(spanRowsError)
                }
                if showsRelevantDecks {
                    relevantDecksSection
                }
            }
        }
    }

    @ViewBuilder
    private var studyCutsContent: some View {
        if spanRowsLoading && spanRows.isEmpty {
            loadingCard(message: "Loading this period…")
        } else if !spanRows.isEmpty {
            VStack(alignment: .leading, spacing: AmgiSpacing.sm) {
                Text("Study cuts")
                    .amgiFont(.sectionHeading)
                    .foregroundStyle(palette.textPrimary)
                timeRowsSection
            }
        } else {
            VStack(alignment: .leading, spacing: AmgiSpacing.sm) {
                Text("Study cuts")
                    .amgiFont(.sectionHeading)
                    .foregroundStyle(palette.textPrimary)
                Text("No study cuts in this period.")
                    .amgiFont(.caption)
                    .foregroundStyle(palette.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(AmgiSpacing.lg)
                    .background(palette.surfaceElevated, in: RoundedRectangle(cornerRadius: AmgiRadius.inset, style: .continuous))
            }
        }
    }

    private func activityCard(presentation: StudyDashboardPresentation) -> some View {
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
                        .font(.title3)
                        .fontWeight(.semibold)
                        .foregroundStyle(palette.textPrimary)
                    Spacer()
                    if showsTodayDesk {
                        Button(action: onExploreHistory) {
                            Text("Explore history")
                                .font(.caption)
                                .foregroundStyle(palette.textPrimary)
                        }
                        .buttonStyle(.plain)
                        .frame(minWidth: 44, minHeight: 44)
                        .background(palette.surface)
                        .contentShape(Rectangle())
                        .accessibilityLabel("Explore history")
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
                    onSelectMonth: onSelectMonth,
                    presentation: presentation
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

    private func todayHero(
        _ summary: StudySummaryData,
        presentation: StudyDashboardPresentation
    ) -> some View {
        AmgiCard(
            background: .surfaceElevated,
            shadow: palette.shadows.md,
            cornerRadius: AmgiRadius.hero
        ) {
            Group {
                if presentation == .compact {
                    VStack(alignment: .leading, spacing: AmgiSpacing.lg) {
                        todayHeroCopy(summary, includesPrimary: false)
                        StudyDueRing(summary: summary, diameter: 156)
                            .frame(maxWidth: .infinity)
                        primary(summary)
                    }
                } else if presentation == .medium {
                    HStack(alignment: .center, spacing: AmgiSpacing.md) {
                        todayHeroCopy(
                            summary,
                            includesPrimary: true,
                            titleFont: .title
                        )
                        StudyDueRing(summary: summary, diameter: 120)
                    }
                } else {
                    HStack(alignment: .center, spacing: AmgiSpacing.xl) {
                        todayHeroCopy(summary, includesPrimary: true)
                        StudyDueRing(
                            summary: summary,
                            diameter: presentation == .wide ? 160 : 184
                        )
                    }
                }
            }
        }
    }

    private func todayHeroCopy(
        _ summary: StudySummaryData,
        includesPrimary: Bool,
        titleFont: Font = .largeTitle
    ) -> some View {
        VStack(alignment: .leading, spacing: AmgiSpacing.sm) {
            HStack(spacing: AmgiSpacing.sm) {
                Text(scopeLabel.map { "TODAY · \($0)" } ?? "TODAY")
                    .font(.footnote)
                    .fontWeight(.semibold)
                    .tracking(0.4)
                    .foregroundStyle(palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if scopeLabel != nil {
                    Button("All decks", action: onShowAllDecks)
                        .font(.caption)
                        .foregroundStyle(palette.accent)
                }
            }
            Text(summary.phase == .caughtUp ? summary.caughtUpTitle : "\(summary.totalDue) cards left")
                .font(titleFont)
                .fontWeight(.bold)
                .foregroundStyle(palette.textPrimary)
            if !summary.subtitleLabel.isEmpty {
                Text(summary.subtitleLabel)
                    .font(.subheadline)
                    .foregroundStyle(palette.textPrimary)
            }
            if let estimate = summary.estimateLabel {
                Text(estimate)
                    .font(.body)
                    .foregroundStyle(palette.textSecondary)
            } else if summary.phase == .caughtUp {
                Text("Your next review is scheduled by the deck limits.")
                    .font(.body)
                    .foregroundStyle(palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if includesPrimary {
                primary(summary)
            }
            categoryLegend(summary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func categoryLegend(_ summary: StudySummaryData) -> some View {
        VStack(alignment: .leading, spacing: AmgiSpacing.xs) {
            Text("Remaining mix")
                .font(.caption)
                .foregroundStyle(palette.textSecondary)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: AmgiSpacing.lg) {
                    categoryLegendItem("New", count: summary.newCount, color: palette.cardStateNew)
                    categoryLegendItem("Learn", count: summary.learnCount, color: palette.cardStateLearning)
                    categoryLegendItem("Review", count: summary.reviewCount, color: palette.cardStateReview)
                }
                VStack(alignment: .leading, spacing: AmgiSpacing.xs) {
                    categoryLegendItem("New", count: summary.newCount, color: palette.cardStateNew)
                    categoryLegendItem("Learn", count: summary.learnCount, color: palette.cardStateLearning)
                    categoryLegendItem("Review", count: summary.reviewCount, color: palette.cardStateReview)
                }
            }
        }
    }

    private func categoryLegendItem(_ title: String, count: Int, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(title)
                .font(.caption)
                .foregroundStyle(palette.textSecondary)
            Text("\(count)")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(palette.textPrimary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(count)")
        .accessibilityValue("\(count) cards")
    }

    private func legendKey(title: String, color: Color) -> some View {
        HStack(spacing: AmgiSpacing.xs) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(title)
                .font(.caption2)
                .foregroundStyle(palette.textSecondary)
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

    private func loadingCard(message: LocalizedStringKey) -> some View {
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

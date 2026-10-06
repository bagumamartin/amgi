import OSLog
import AmgiAppCore
import AmgiAppShared
import AmgiReader
import AmgiReviewCore
import AmgiUI
import AnkiClients
import AnkiKit
import Dependencies
import Foundation

/// Data loading for the study landing screen. Owns the deck + reader-book
/// clients, the progress coordinator, the mapped `StudyLandingContent.State`,
/// and the book-sheet selection so the Container carries no `@Dependency`;
/// the Container keeps only its navigation callback and load-task lifecycle.
@Observable
@MainActor
final class StudyLandingModel {
    var contentState: StudyLandingState = .loading
    var selectedBook: ReaderBook?
    var grain: StudyGrain = .day
    /// Days before the current Anki day. Positive is the past, negative the future.
    var dayOffset: Int = 0
    /// One-shot scope supplied by a configured widget deep link. Nil is the
    /// normal collection-wide Study desk.
    var landingDeckID: Int64?
    var landingDeckName: String?
    var spanRows: [StudyTimeRow] = []
    var spanRowsLoading = false
    var forecast: StudyForecastData?
    var todayAttentionRows: [StudyTimeRow] = []
    var spanDeckRows: [StudyTimeRow] = []
    var spanDeckRowsLoading = false
    var spanDeckTitle = L10n.text("Relevant decks")
    var spanRowsError: String?
    var spanDeckRowsError: String?
    var workloadError: String?

    let progressCoordinator = ReaderProgressCoordinator()

    /// Whole-collection counts captured when the active review session began.
    /// The live ring composition is derived from this anchor so the segments
    /// move as cards are answered without refetching the deck tree per answer.
    private var liveAnchorCounts: DeckCounts?
    private var liveSessionID: UUID?

    @ObservationIgnored @Dependency(\.readerBookClient) private var readerBookClient
    @ObservationIgnored @Dependency(\.epubLibraryClient) private var epubLibraryClient
    @ObservationIgnored @Dependency(\.collectionStore) private var store
    @ObservationIgnored @Dependency(\.statsClient) private var statsClient
    @ObservationIgnored @Dependency(\.deckClient) private var deckClient
    @ObservationIgnored @Dependency(\.cardClient) private var cardClient

    private var loadToken = 0
    private var spanToken = 0
    private var bookToken = 0
    private var rolloverHour = 4
    private var hasActivitySnapshot = false
    private var activitySearch = ""
    private var topLevelStudyDecks: [DeckTreeNode] = []
    private var supportsStability = false
    private var relevantDeckCache: [Int: [StudyTimeRow]] = [:]
    /// Review counts keyed by days-before-today.
    private var reviewTotals: [Int: Int] = [:]
    private var reviewMillis: [Int: Int] = [:]
    /// Cards due on a future Anki day, keyed by days ahead (1 = tomorrow).
    private var futureDueCounts: [Int: Int] = [:]
    /// Review counts for each local hour, keyed by days-before-today.
    private var hoursByDay: [Int: [Int]] = [:]

    func load() async {
        loadToken += 1
        let token = loadToken
        let hadContent: Bool
        if case .loaded = contentState { hadContent = true } else { hadContent = false }
        if !hadContent {
            forecast = nil
            todayAttentionRows = []
            spanDeckRows = []
            spanDeckRowsLoading = false
            spanRowsError = nil
            spanDeckRowsError = nil
            workloadError = nil
        }
        relevantDeckCache = [:]
        do {
            // 1. Deck tree → top-level decks only. Parent counts already
            //    aggregate descendants, so a deck with due subdecks still
            //    surfaces. Subdeck names become a caption, not nested rows.
            let fullTree = try await store.tree()
            activitySearch = Self.searchScope(in: fullTree, deckID: landingDeckID)
            landingDeckName = landingDeckID.flatMap { id in
                Self.findNode(fullTree, id: id)?.fullName
            }
            let tree = Self.scopedTree(fullTree, deckID: landingDeckID)
            guard token == loadToken else { return }
            topLevelStudyDecks = tree.filter { !$0.isFiltered }
            guard !tree.isEmpty else {
                contentState = .empty
                return
            }

            let deckRows = tree
                .filter { $0.counts.total > 0 }
                .sorted { $0.counts.total > $1.counts.total }
                .map { Self.makeDeckRow(from: $0) }

            // 2. Answerable counts are the tree. Learning cards due later
            //    today sit outside the learn-ahead window, so they are a
            //    note — not part of the ring — or "due now" would include
            //    cards the reviewer will not show yet.
            let totalDue = tree.reduce(0) { $0 + $1.counts.total }
            let totalNew = tree.reduce(0) { $0 + $1.counts.newCount }
            let treeLearn = tree.reduce(0) { $0 + $1.counts.learnCount }
            let learningToday = (try? await statsClient.learningDueToday(search: activitySearch)) ?? treeLearn
            let learningReturning = max(0, learningToday - treeLearn)
            let totalReview = tree.reduce(0) { $0 + $1.counts.reviewCount }
            let deckCount = tree.filter { $0.counts.total > 0 }.count
            guard token == loadToken else { return }

            let weekday = Date().formatted(.dateTime.weekday(.wide).locale(AppLocale.current))
            let subtitleLabel = deckCount == 0
                ? weekday
                : "\(weekday) · \(deckCount == 1 ? L10n.format("%lld deck due", [deckCount]) : L10n.format("%lld decks due", [deckCount]))"
            let dayProgress = await resolveCollectionProgress(
                totalDue: totalDue,
                search: activitySearch
            )
            guard token == loadToken else { return }

            // Carry streak/forecast across a refresh so the second phase
            // doesn't flash back to a placeholder.
            let carried = carriedSummary
            let summary = StudySummaryData(
                totalDue: totalDue,
                newCount: totalNew,
                learnCount: treeLearn,
                reviewCount: totalReview,
                todayLabel: L10n.text("Today"),
                subtitleLabel: subtitleLabel,
                deckCount: deckCount,
                reviewedToday: dayProgress.reviewedToday,
                dueBaselineToday: dayProgress.dueBaselineToday,
                learningReturning: learningReturning,
                answerCount: carried?.answerCount ?? 0,
                answerMillis: carried?.answerMillis ?? 0,
                streak: carried?.streak ?? 0,
                streakPending: carried == nil,
                tomorrowDue: carried?.tomorrowDue,
                backlogNote: carried?.backlogNote,
                rolloverNote: carried?.rolloverNote
            )

            let continueReading = totalDue == 0 ? await loadContinueReading() : nil
            guard token == loadToken else { return }
            contentState = .loaded(summary: summary, decks: deckRows, continueReading: continueReading)

            await DeckIconLookup.refresh?()
            var iconRows = deckRows
            await Self.attachIconNames(to: &iconRows)
            guard token == loadToken else { return }
            if case .loaded(let refreshedSummary, _, let refreshedReading) = contentState {
                contentState = .loaded(
                    summary: refreshedSummary,
                    decks: iconRows,
                    continueReading: refreshedReading
                )
            }

            await loadActivity(token: token)
            await reloadSpanRows()
        } catch {
            Log.reader.error("Error loading: \(error)")
            guard token == loadToken, !hadContent else { return }
            contentState = .failed(error.localizedDescription)
        }
    }

    /// Opens a filtered deck for the row. The limit is the number on the
    /// detail screen, which starts at the whole match. Returns a message
    /// when the search is empty or the engine refuses; nil when review
    /// should open on `deckID`.
    func study(search: String, limit: Int, reschedule: Bool) async -> (deckID: DeckID?, message: String?) {
        do {
            let spec = FilteredDeckSpec(
                // A name, not copy: `StudyDeckNaming` matches it on later
                // launches to clean up. See that type for why it must not be
                // localized.
                name: StudyDeckNaming.sessionName(token: String(UUID().uuidString.prefix(8))),
                search: search,
                limit: UInt32(max(1, limit)),
                order: .due,
                reschedule: reschedule
            )
            let created = try await deckClient.createFilteredDeck(spec)
            let gathered = try await deckClient.rebuildFilteredDeck(created.id)
            guard gathered > 0 else {
                return (nil, L10n.text("No cards matched."))
            }
            store.invalidateAll(origin: .localUser)
            return (created.id, nil)
        } catch {
            Log.reader.error("Span study failed: \(error)")
            return (nil, error.localizedDescription)
        }
    }

    var showsTodayDesk: Bool { grain == .day && dayOffset == 0 }

    var canStepPast: Bool { dayOffset < StudySpan.pastLimit }

    var canStepFuture: Bool {
        switch grain {
        case .day:
            dayOffset > -StudySpan.futureLimit
        case .week, .month, .year:
            dayOffset > -StudySpan.calendarFutureLimit
        }
    }

    var spanTitle: String {
        StudySpan.title(grain: grain, todayStart: todayStart, anchor: dayOffset, locale: AppLocale.current)
    }

    var spanSubtitle: String {
        StudySpan.subtitle(grain: grain, todayStart: todayStart, anchor: dayOffset, locale: AppLocale.current)
    }

    var spanHeadline: String {
        guard !showsTodayDesk else { return "" }
        if grain == .day, dayOffset < 0 {
            let count = spanRows.first?.count ?? futureDueCounts[-dayOffset] ?? 0
            return L10n.format("%lld due", [count])
        }
        if !spanOffsets.isEmpty, spanOffsets.allSatisfy({ $0 < 0 }) {
            let count = spanOffsets.reduce(0) { $0 + activityCount($1) }
            return L10n.format("%lld scheduled", [count])
        }
        let count = spanRows.first { $0.id == "reviewed" }?.count ?? reviewedInSpan
        let minutes = reviewedMillisInSpan / 60_000
        if let duration = StudySpan.studiedDuration(minutes: minutes, locale: AppLocale.current) {
            return "\(L10n.format("%lld reviewed", [count])) · \(duration)"
        }
        return L10n.format("%lld reviewed", [count])
    }

    var showsJump: Bool {
        !StudySpan.isCurrent(grain: grain, todayStart: todayStart, anchor: dayOffset)
    }

    var jumpTitle: String { StudySpan.jumpTitle(grain: grain, locale: AppLocale.current) }

    var chart: StudyChartModel {
        let calendar = Calendar.current
        switch grain {
        case .day:
            if dayOffset < 0 {
                return .forecastDay(
                    title: spanTitle,
                    count: futureDueCounts[-dayOffset] ?? 0
                )
            }
            let twentyFour = StudySpan.uses24HourClock()
            let columns = (0..<24).map { slot in
                let clock = StudySpan.ankiDayClockHour(rolloverHour: rolloverHour, slot: slot)
                return StudyChartColumn(
                    offset: clock,
                    label: StudySpan.hourColumnLabel(clock, twentyFourHour: twentyFour),
                    value: hourCount(clock),
                    isSelected: false,
                    isToday: false,
                    isFuture: dayOffset < 0
                )
            }
            let axis = StudySpan.dayAxisMarks(rolloverHour: rolloverHour, locale: AppLocale.current)
            return .hours(columns: columns, axis: axis)
        case .week:
            let offsets = StudySpan.weekOffsets(todayStart: todayStart, anchor: dayOffset, calendar: calendar)
            let columns = offsets.map { offset in
                let day = StudySpan.date(todayStart: todayStart, offset: offset, calendar: calendar)
                let label = String(calendar.component(.day, from: day))
                let weekday = calendar.component(.weekday, from: day)
                let symbols = calendar.veryShortWeekdaySymbols
                let letter = symbols.indices.contains(weekday - 1) ? symbols[weekday - 1] : ""
                return StudyChartColumn(
                    offset: offset,
                    label: label,
                    value: activityCount(offset),
                    isSelected: offset == dayOffset,
                    isToday: offset == 0,
                    isFuture: offset < 0,
                    axis: letter
                )
            }
            return .bars(columns)
        case .month:
            let headers = StudySpan.weekdayHeaders(calendar: calendar, locale: AppLocale.current)
            let offsets = StudySpan.monthOffsets(todayStart: todayStart, anchor: dayOffset, calendar: calendar)
            let cells = offsets.enumerated().map { index, offset in
                let number: String
                if let offset {
                    let day = StudySpan.date(todayStart: todayStart, offset: offset, calendar: calendar)
                    number = String(calendar.component(.day, from: day))
                } else {
                    number = ""
                }
                return StudyMonthCell(
                    index: index,
                    offset: offset,
                    dayNumber: number,
                    value: offset.map(activityCount) ?? 0,
                    isSelected: offset == dayOffset,
                    isToday: offset == 0,
                    isFuture: (offset ?? 0) < 0
                )
            }
            return .month(headers: headers, cells: cells)
        case .year:
            let wall = StudySpan.yearChart(
                todayStart: todayStart,
                anchor: dayOffset,
                calendar: calendar,
                activity: { self.activityCount($0) }
            )
            return .year(months: wall.months)
        }
    }

    func step(towardsPast: Bool) {
        let sign = towardsPast ? 1 : -1
        switch grain {
        case .day:
            dayOffset = StudySpan.clamped(dayOffset + sign)
        case .week:
            dayOffset = StudySpan.calendarClamped(dayOffset + sign * 7)
        case .month:
            let calendar = Calendar.current
            let anchor = StudySpan.date(todayStart: todayStart, offset: dayOffset, calendar: calendar)
            let moved = calendar.date(byAdding: .month, value: towardsPast ? -1 : 1, to: anchor) ?? anchor
            dayOffset = StudySpan.calendarClamped(StudySpan.offset(todayStart: todayStart, dayStart: moved, calendar: calendar))
        case .year:
            let calendar = Calendar.current
            let anchor = StudySpan.date(todayStart: todayStart, offset: dayOffset, calendar: calendar)
            let moved = calendar.date(byAdding: .year, value: towardsPast ? -1 : 1, to: anchor) ?? anchor
            dayOffset = StudySpan.calendarClamped(StudySpan.offset(todayStart: todayStart, dayStart: moved, calendar: calendar))
        }
        Task { await reloadSpanRows() }
    }

    func selectGrain(_ grain: StudyGrain) {
        self.grain = grain
        Task { await reloadSpanRows() }
    }

    /// Year opens that month with the day marked. Month opens the week.
    /// Week opens the day.
    func focusDay(_ offset: Int) {
        let clamped = StudySpan.calendarClamped(offset)
        switch grain {
        case .year:
            grain = .month
            dayOffset = clamped
        case .month:
            grain = .week
            dayOffset = clamped
        case .week:
            grain = .day
            dayOffset = clamped
        case .day:
            guard dayOffset != clamped else { return }
            dayOffset = clamped
        }
        Task { await reloadSpanRows() }
    }

    /// The year wall's month name opens that month.
    func selectMonth(_ offset: Int) {
        grain = .month
        dayOffset = StudySpan.calendarClamped(offset)
        Task { await reloadSpanRows() }
    }

    /// Back to the current period, keeping the grain.
    func returnToNow() {
        dayOffset = 0
        Task { await reloadSpanRows() }
    }

    /// Explicit deep-link/widget destination. Unlike `returnToNow`, this
    /// always returns to the compact Today desk and discards a historical
    /// detail selection that may still be mounted in the navigation stack.
    func showToday(deckID: Int64? = nil) async {
        landingDeckID = deckID == 0 ? nil : deckID
        grain = .day
        dayOffset = 0
        spanRows = []
        spanDeckRows = []
        spanDeckRowsLoading = false
        forecast = nil
        todayAttentionRows = []
        workloadError = nil
        await load()
    }

    /// Opens the historical explorer on yesterday so the first result is a
    /// concrete day with a useful deck-relevance section.
    func showHistory() async {
        grain = .day
        dayOffset = 1
        spanRows = []
        spanDeckRows = []
        spanDeckRowsLoading = false
        await reloadSpanRows()
    }

    /// Keeps an open Study tab honest across the Anki day boundary. Scene
    /// activation handles foregrounding; this handles a tab left open overnight.
    func waitForNextRollover() async {
        if !hasActivitySnapshot {
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await waitForNextRollover()
            return
        }

        let calendar = Calendar.current
        let now = Date()
        let start = AnkiDay.start(of: now, rolloverHour: rolloverHour, calendar: calendar)
        guard let next = calendar.date(byAdding: .day, value: 1, to: start) else { return }
        let seconds = max(1, next.timeIntervalSince(now) + 1)
        do {
            try await Task.sleep(for: .seconds(seconds))
        } catch {
            return
        }
        guard !Task.isCancelled else { return }
        await load()
        await waitForNextRollover()
    }

    private var carriedSummary: StudySummaryData? {
        if case .loaded(let summary, _, _) = contentState { return summary }
        return nil
    }

    /// Streak, time studied, forecast, and actionable attention rows.
    /// Published onto whatever summary is current so a live review repaint in
    /// between isn't overwritten with the pre-session counts.
    private func loadActivity(token: Int) async {
        workloadError = nil
        let graphs: GraphsSnapshot?
        do {
            graphs = try await statsClient.fetchGraphs(activitySearch, StudySpan.pastLimit)
        } catch {
            graphs = nil
        }

        guard token == loadToken,
              case .loaded(let summary, let decks, let reading) = contentState else { return }

        if let graphs {
            rolloverHour = graphs.rolloverHour
            reviewTotals = Self.dayTotals(graphs.reviews.count)
            reviewMillis = Self.dayTotals(graphs.reviews.time)
            futureDueCounts = graphs.futureDue.futureDue
            hoursByDay = Dictionary(uniqueKeysWithValues: graphs.hoursByDay.map { key, hours in
                (-key, hours)
            })
            hasActivitySnapshot = true
            supportsStability = graphs.fsrs
        } else {
            supportsStability = false
            if forecast == nil {
                forecast = .empty
            }
        }

        let updated: StudySummaryData
        if let graphs {
            updated = summary.withActivity(
                answerCount: graphs.today.answerCount,
                answerMillis: graphs.today.answerMillis,
                streak: StreakCalculator.streak(reviews: graphs.reviews.count),
                tomorrowDue: graphs.futureDue.futureDue[1] ?? 0,
                backlogNote: StudySummaryData.backlogNote(haveBacklog: graphs.futureDue.haveBacklog),
                rolloverNote: AnkiDay.rolloverNote(now: Date(), rolloverHour: graphs.rolloverHour)
            )
        } else if summary.streakPending {
            updated = summary.withActivity(
                answerCount: summary.answerCount,
                answerMillis: summary.answerMillis,
                streak: summary.streak,
                tomorrowDue: summary.tomorrowDue ?? 0,
                backlogNote: summary.backlogNote,
                rolloverNote: summary.rolloverNote
            )
        } else {
            return
        }

        contentState = .loaded(summary: updated, decks: decks, continueReading: reading)

        guard token == loadToken, let graphs else { return }
        let workload = await makeWorkloadContext(
            graphs: graphs,
            currentDue: updated.totalDue
        )
        guard token == loadToken else { return }
        forecast = workload.forecast
        todayAttentionRows = workload.attentionRows
        workloadError = workload.error
    }

    private func scopedActivitySearch(_ base: String) -> String {
        guard !activitySearch.isEmpty else { return base }
        return "\(base) \(activitySearch)"
    }

    private func makeWorkloadContext(
        graphs: GraphsSnapshot,
        currentDue: Int
    ) async -> (forecast: StudyForecastData, attentionRows: [StudyTimeRow], error: String?) {
        let calendar = Calendar.current
        let start = AnkiDay.start(of: Date(), rolloverHour: graphs.rolloverHour, calendar: calendar)
        let days = (0..<7).map { offset -> StudyForecastDay in
            let date = StudySpan.date(todayStart: start, offset: -offset, calendar: calendar)
            let count = offset == 0 ? currentDue : graphs.futureDue.futureDue[offset] ?? 0
            let label: String
            if offset == 0 {
                label = L10n.text("Today")
            } else if offset == 1 {
                label = L10n.text("Tomorrow")
            } else {
                label = date.formatted(.dateTime.weekday(.abbreviated).locale(AppLocale.current))
            }
            let spokenDate = date.formatted(.dateTime.weekday(.wide).locale(AppLocale.current))
            return StudyForecastDay(
                offset: -offset,
                label: label,
                accessibilityLabel: L10n.format("%@, %lld cards", [spokenDate, count]),
                count: count
            )
        }

        let graphBacklogCount = graphs.futureDue.backlogCount
        let searchedBacklogCount: Int?
        do {
            searchedBacklogCount = try await cardClient.searchIds(
                scopedActivitySearch(StudySpan.backlogSearch),
                nil
            ).count
        } catch {
            searchedBacklogCount = nil
        }
        // The detail row uses the same search, so prefer its count when it is
        // available. Fall back to the graph only when the search itself fails.
        let backlogCount = searchedBacklogCount ?? graphBacklogCount
        var attentionRows: [StudyTimeRow] = []
        if backlogCount > 0 {
            attentionRows.append(StudySpan.backlogRow(
                count: backlogCount,
                search: scopedActivitySearch(StudySpan.backlogSearch),
                locale: AppLocale.current
            ))
        }

        var unstableCount: Int?
        var workloadErrorMessage: String?
        if graphs.fsrs, let search = StudySpan.unstableSearch(dayOffset: 0) {
            do {
                let count = try await cardClient.searchIds(
                    scopedActivitySearch(search),
                    nil
                ).count
                unstableCount = count
                attentionRows.append(StudySpan.unstableRow(
                    count: count,
                    dayOffset: 0,
                    spanName: L10n.text("Today"),
                    search: scopedActivitySearch(search),
                    locale: AppLocale.current
                ))
            } catch {
                workloadErrorMessage = L10n.text("The unstable-card count couldn't be loaded.")
            }
        }

        let forecast = StudyForecastData(
            days: days,
            tomorrowDue: graphs.futureDue.futureDue[1] ?? 0,
            dailyLoad: graphs.futureDue.dailyLoad,
            backlogCount: backlogCount,
            hasBacklog: graphs.futureDue.haveBacklog || backlogCount > 0,
            unstableDueCount: unstableCount,
            fsrsEnabled: graphs.fsrs
        )
        return (forecast, attentionRows, workloadErrorMessage)
    }

    func selectBook(_ bookID: String) {
        bookToken += 1
        let token = bookToken
        Task {
            if let configuration = ReaderConfigurationLoader.loadConfiguration(),
               let book = try? await readerBookClient.loadBook(bookID, configuration) {
                guard token == bookToken else { return }
                selectedBook = book
                return
            }
            if let book = await epubLibraryClient.listBooks().first(where: { $0.id == bookID }),
               token == bookToken {
                selectedBook = book
            }
        }
    }

    /// Repaints the ring's new/learning/review composition from the live
    /// session without a full deck-tree refetch. The ring always shows the
    /// whole collection: subtract the session's baseline from the pre-session
    /// anchor, then add the session's live counts. The day-progress arc,
    /// deck rows, and reading recommendations stay on the last full snapshot.
    func applyLiveCounts(_ snapshot: LiveReviewSnapshot) {
        guard case .loaded(let summary, let decks, let continueReading) = contentState else { return }
        if liveSessionID != snapshot.sessionID {
            liveAnchorCounts = DeckCounts(
                newCount: summary.newCount,
                learnCount: summary.learnCount,
                reviewCount: summary.reviewCount
            )
            liveSessionID = snapshot.sessionID
        }
        guard let anchor = liveAnchorCounts else { return }

        let whole = DeckCounts(
            newCount: max(0, anchor.newCount - snapshot.baseline.newCount) + snapshot.live.newCount,
            learnCount: max(0, anchor.learnCount - snapshot.baseline.learnCount) + snapshot.live.learnCount,
            reviewCount: max(0, anchor.reviewCount - snapshot.baseline.reviewCount) + snapshot.live.reviewCount
        )

        let answeredDelta =
            max(0, snapshot.baseline.newCount - snapshot.live.newCount)
            + max(0, snapshot.baseline.learnCount - snapshot.live.learnCount)
            + max(0, snapshot.baseline.reviewCount - snapshot.live.reviewCount)
        let liveReviewed = max(0, summary.reviewedToday + answeredDelta)
        let liveBaseline = max(summary.dueBaselineToday, liveReviewed + whole.total, 1)
        let updatedSummary = summary.withLiveCounts(
            totalDue: whole.total,
            newCount: whole.newCount,
            learnCount: whole.learnCount,
            reviewCount: whole.reviewCount,
            reviewedToday: liveReviewed,
            dueBaselineToday: liveBaseline
        )
        contentState = .loaded(
            summary: updatedSummary,
            decks: decks,
            continueReading: continueReading
        )
        forecast = forecast?.updatingTodayCount(whole.total)
    }

    /// Forgets the live-session anchor. The next full `load()` (triggered by
    /// the review-end generation bump) restores a fresh whole-collection
    /// snapshot, so the displayed ring keeps its last accurate state in the
    /// interim.
    func clearLiveCounts() {
        liveSessionID = nil
        liveAnchorCounts = nil
    }

    private static func findNode(_ nodes: [DeckTreeNode], id: Int64) -> DeckTreeNode? {
        for node in nodes {
            if node.id.rawValue == id { return node }
            if let match = findNode(node.children, id: id) { return match }
        }
        return nil
    }

    private static func scopedTree(_ tree: [DeckTreeNode], deckID: Int64?) -> [DeckTreeNode] {
        guard let deckID, deckID != 0 else { return tree }
        return findNode(tree, id: deckID).map { [$0] } ?? []
    }

    private static func searchScope(in tree: [DeckTreeNode], deckID: Int64?) -> String {
        guard let deckID, deckID != 0,
              let node = findNode(tree, id: deckID) else { return "" }
        return StudySpan.deckScopeSearch(node.fullName)
    }

    /// Maps a top-level deck. Due children are a caption, not rows.
    private static func makeDeckRow(from node: DeckTreeNode) -> StudyDeckRowData {
        StudyDeckRowData(
            id: node.id.rawValue,
            name: node.name,
            totalDue: node.counts.total,
            newCount: node.counts.newCount,
            learnCount: node.counts.learnCount,
            reviewCount: node.counts.reviewCount,
            isFiltered: node.isFiltered,
            includesLabel: includesLabel(for: node),
            iconName: DeckIconLookup.initialIcon?(node.id.rawValue, node.name)
        )
    }

    private static func includesLabel(for node: DeckTreeNode) -> String? {
        let names = node.children
            .filter { $0.counts.total > 0 }
            .sorted { $0.counts.total > $1.counts.total }
            .map(\.name)
        guard !names.isEmpty else { return nil }
        let shown = names.prefix(3).joined(separator: ", ")
        if names.count > 3 {
            return "\(L10n.format("Includes %@", [shown]))…"
        }
        return L10n.format("Includes %@", [shown])
    }

    /// Recursively resolves icons for every row (top-level decks and nested
    /// subdecks alike). Study rows carry only the leaf name — suggestions
    /// derive from it; manual overrides are id-keyed and unaffected.
    private static func attachIconNames(to rows: inout [StudyDeckRowData]) async {
        for index in rows.indices {
            let row = rows[index]
            let iconName = await DeckIconLookup.resolvedIcon?(
                row.id,
                row.name,
                row.name
            )
            var subdecks = row.subdecks
            await attachIconNames(to: &subdecks)
            if iconName != row.iconName || subdecks != row.subdecks {
                rows[index] = StudyDeckRowData(
                    id: row.id,
                    name: row.name,
                    totalDue: row.totalDue,
                    newCount: row.newCount,
                    learnCount: row.learnCount,
                    reviewCount: row.reviewCount,
                    isFiltered: row.isFiltered,
                    subdecks: subdecks,
                    includesLabel: row.includesLabel,
                    iconName: iconName
                )
            }
        }
    }

    private func resolveCollectionProgress(
        totalDue: Int,
        search: String
    ) async -> (reviewedToday: Int, dueBaselineToday: Int) {
        do {
            let completedToday = try await statsClient.graduatedToday(search: search)
            // Live denominator (completed + remaining) rather than a frozen
            // baseline, so the ring can't read 100% while cards are still due.
            let baseline = max(completedToday + totalDue, 1)
            return (completedToday, baseline)
        } catch {
            return (0, max(totalDue, 1))
        }
    }

    /// The most recently updated book with unfinished progress, across both
    /// reader sources. The Study recommendation should not silently omit an
    /// EPUB library or offer a book the user already finished.
    private func loadContinueReading() async -> StudyReadingRecData? {
        async let epubBooks = epubLibraryClient.listBooks()

        var ankiBooks: [ReaderBook] = []
        if let configuration = ReaderConfigurationLoader.loadConfiguration() {
            ankiBooks = (try? await readerBookClient.loadBooks(configuration)) ?? []
        }
        let epub = await epubBooks
        let books = ankiBooks + epub
        guard !books.isEmpty else { return nil }

        var best: (book: ReaderBook, at: Date)?
        for book in books {
            guard let progress = await progressCoordinator.resolved(bookID: book.id),
                  hasUnfinishedReading(book: book, progress: progress) else { continue }
            if let current = best {
                if progress.updatedAt > current.at {
                    best = (book, progress.updatedAt)
                }
            } else {
                best = (book, progress.updatedAt)
            }
        }
        guard let best else { return nil }
        return StudyReadingRecData(
            id: best.book.id,
            title: best.book.title,
            coverImagePath: best.book.coverImagePath,
            authorLabel: best.book.author ?? ""
        )
    }

    private func hasUnfinishedReading(
        book: ReaderBook,
        progress: ReaderSavedProgress
    ) -> Bool {
        guard let chapterIndex = book.chapters.firstIndex(where: { $0.id == progress.chapterID }) else {
            // A progress record from an older library can outlive a removed
            // chapter. Keep it actionable only when the saved position is
            // demonstrably inside the book rather than at a completed end.
            return progress.progress > 0 && progress.progress < 1
        }
        if chapterIndex < book.chapters.count - 1 {
            return true
        }
        return progress.progress < 1
    }

    private var todayStart: Date {
        AnkiDay.start(of: Date(), rolloverHour: rolloverHour)
    }

    private var spanOffsets: [Int] {
        let calendar = Calendar.current
        switch grain {
        case .day:
            return [dayOffset]
        case .week:
            return StudySpan.weekOffsets(todayStart: todayStart, anchor: dayOffset, calendar: calendar)
        case .month:
            return StudySpan.monthOffsets(todayStart: todayStart, anchor: dayOffset, calendar: calendar).compactMap { $0 }
        case .year:
            return StudySpan.yearDayOffsets(todayStart: todayStart, anchor: dayOffset, calendar: calendar)
        }
    }

    private var reviewedInSpan: Int {
        spanOffsets.filter { $0 >= 0 }.reduce(0) { $0 + (reviewTotals[$1] ?? 0) }
    }

    private var reviewedMillisInSpan: Int {
        spanOffsets.filter { $0 >= 0 }.reduce(0) { $0 + (reviewMillis[$1] ?? 0) }
    }

    private func activityCount(_ offset: Int) -> Int {
        if offset >= 0 { return reviewTotals[offset] ?? 0 }
        return futureDueCounts[-offset] ?? 0
    }

    private func hourCount(_ hour: Int) -> Int {
        guard dayOffset >= 0, let counts = hoursByDay[dayOffset], hour < counts.count else { return 0 }
        return counts[hour]
    }

    private func reloadSpanRows() async {
        spanToken += 1
        let token = spanToken
        spanRows = []
        spanDeckRows = []
        spanDeckRowsLoading = false
        spanRowsError = nil
        spanDeckRowsError = nil
        guard !showsTodayDesk else {
            spanRowsLoading = false
            return
        }
        spanRowsLoading = true
        defer { if token == spanToken { spanRowsLoading = false } }

        let spanName = spanTitle
        if grain == .day, dayOffset < 0 {
            let ahead = -dayOffset
            let search = scopedActivitySearch(StudySpan.dueSearch(daysAhead: ahead))
            // The graph is the scheduler's authoritative future-due set. A
            // direct search is only a fallback when the graph has not filled
            // this day yet; never overwrite the graph with a review-only
            // count because that would drop learning cards.
            let count: Int
            if let graphCount = futureDueCounts[ahead] {
                count = graphCount
            } else {
                count = (try? await cardClient.searchIds(search, nil).count) ?? 0
            }
            guard token == spanToken else { return }
            var rows = [StudySpan.dueRow(
                count: count,
                daysAhead: ahead,
                spanName: spanName,
                search: search,
                locale: AppLocale.current
            )]
            if supportsStability, let unstableSearch = StudySpan.unstableSearch(dayOffset: dayOffset) {
                do {
                    let unstableCount = try await cardClient.searchIds(unstableSearch, nil).count
                    rows.append(StudySpan.unstableRow(
                        count: unstableCount,
                        dayOffset: dayOffset,
                        spanName: spanName,
                        locale: AppLocale.current
                    ))
                } catch {
                    if token == spanToken {
                        spanRowsError = L10n.text("The unstable-card count couldn't be loaded.")
                    }
                }
            }
            spanRows = rows
            spanRowsLoading = false
            await loadRelevantDecks(token: token)
            return
        }

        guard let window = StudySpan.ratingWindow(offsets: spanOffsets) else {
            guard token == spanToken else { return }
            // An all-future period has no rating window. The chart remains the
            // source of truth for that forecast; avoid manufacturing empty
            // "reviewed" rows that look like real zeroes.
            spanRows = []
            spanRowsLoading = false
            await loadRelevantDecks(token: token)
            return
        }

        let counts = await countCriteria(window: window, token: token)
        guard token == spanToken else { return }
        var rows = StudySpan.ratingRows(
            counts: counts,
            oldest: window.oldest,
            newest: window.newest,
            spanName: spanName,
            additionalSearch: activitySearch.isEmpty ? nil : activitySearch,
            locale: AppLocale.current
        )
        if supportsStability {
            let unstableSearch = scopedActivitySearch(
                StudySpan.criterionSearch(
                    ease: nil,
                    extra: "prop:s<\(StudySpan.unstableStabilityDays)",
                    oldest: window.oldest,
                    newest: window.newest
                )
            )
            do {
                let unstableCount = try await cardClient.searchIds(unstableSearch, nil).count
                rows.insert(
                    StudySpan.unstableRow(
                        count: unstableCount,
                        dayOffset: dayOffset,
                        spanName: spanName,
                        search: unstableSearch,
                        locale: AppLocale.current
                    ),
                    at: 0
                )
            } catch {
                if token == spanToken {
                    spanRowsError = L10n.text("The unstable-card count couldn't be loaded.")
                }
            }
        }
        spanRows = rows
        spanRowsLoading = false
        await loadRelevantDecks(token: token)
    }

    /// Finds the top-level decks that contributed answers or scheduled work
    /// on an exact historical day. Deck terms include descendants, so a
    /// parent row is a useful session target without double-counting nested
    /// rows. Results are cached because the engine serializes searches.
    /// The engine's revlog does not retain a card's deck at answer time, so
    /// a historical row means "cards currently in this deck that were
    /// reviewed/due then", not a perfect reconstruction of deck membership.
    private func loadRelevantDecks(token: Int) async {
        guard grain == .day, dayOffset != 0,
              let baseSearch = StudySpan.relevanceSearch(dayOffset: dayOffset) else {
            if token == spanToken {
                spanDeckTitle = L10n.text("Relevant decks")
                spanDeckRows = []
                spanDeckRowsLoading = false
                spanDeckRowsError = nil
            }
            return
        }

        spanDeckTitle = dayOffset > 0 ? L10n.text("Decks with cards reviewed") : L10n.text("Decks with cards due")
        if let cached = relevantDeckCache[dayOffset] {
            spanDeckRows = cached
            spanDeckRowsLoading = false
            return
        }

        spanDeckRowsLoading = true
        var rows: [StudyTimeRow] = []
        var hadFailure = false
        let isFuture = dayOffset < 0
        let futureDaysAhead = isFuture ? -dayOffset : 0
        let scopedBaseSearch = scopedActivitySearch(baseSearch)
        for node in topLevelStudyDecks {
            if Task.isCancelled || token != spanToken { return }
            let count: Int
            do {
                if isFuture {
                    if activitySearch.isEmpty {
                        // Use the same graph producer as the aggregate
                        // forecast so learning cards and buried future cards
                        // are not lost in a review-only card search.
                        let deckScope = StudySpan.deckScopeSearch(node.fullName)
                        let deckGraph = try await statsClient.fetchGraphs(deckScope, 1)
                        count = deckGraph.futureDue.futureDue[futureDaysAhead] ?? 0
                    } else {
                        // A configured widget is already scoped to its one
                        // deck; reuse the aggregate graph instead of issuing a
                        // second identical graph request.
                        count = futureDueCounts[futureDaysAhead] ?? 0
                    }
                } else {
                    let scoped = activitySearch.isEmpty
                        ? StudySpan.scopedSearch(
                            baseSearch,
                            deckFullName: node.fullName,
                            includeSubdecks: true
                        )
                        : scopedBaseSearch
                    count = try await cardClient.searchIds(scoped, nil).count
                }
            } catch {
                hadFailure = true
                continue
            }
            guard count > 0 else { continue }
            rows.append(StudyTimeRow(
                id: "day-deck-\(node.id.rawValue)",
                title: node.name,
                count: count,
                search: baseSearch,
                detailTitle: "\(node.name) · \(spanTitle)",
                emptyMessage: "No matching cards in \(node.name)",
                reschedulesByDefault: true,
                subtitle: node.children.isEmpty ? nil : L10n.text("Includes subdecks"),
                initialDeckID: node.id.rawValue,
                deckFullName: node.fullName
            ))
        }
        guard token == spanToken, !Task.isCancelled else { return }
        rows.sort {
            if $0.count != $1.count { return $0.count > $1.count }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
        let capped = Array(rows.prefix(12))
        if !hadFailure {
            relevantDeckCache[dayOffset] = capped
        }
        spanDeckRows = capped
        spanDeckRowsLoading = false
        if hadFailure {
            spanDeckRowsError = L10n.text("Some deck counts couldn't be loaded. Pull to refresh to try again.")
        }
    }

    private func countCriteria(
        window: (oldest: Int, newest: Int),
        token: Int
    ) async -> [String: Int] {
        let client = cardClient
        let result = await withTaskGroup(of: (String, Int, Bool).self) { group in
            for criterion in StudySpan.criteria {
                let search = scopedActivitySearch(
                    StudySpan.criterionSearch(
                        ease: criterion.ease,
                        extra: criterion.extra,
                        oldest: window.oldest,
                        newest: window.newest
                    )
                )
                group.addTask {
                    do {
                        let count = try await client.searchIds(search, nil).count
                        return (criterion.id, count, false)
                    } catch {
                        return (criterion.id, 0, true)
                    }
                }
            }
            var counts: [String: Int] = [:]
            var hadFailure = false
            for await (id, count, failed) in group {
                counts[id] = count
                hadFailure = hadFailure || failed
            }
            return (counts, hadFailure)
        }
        if result.1, token == spanToken {
            spanRowsError = L10n.text("Some study filters couldn't be loaded. Pull to refresh to try again.")
        }
        return result.0
    }

    func matchCount(_ search: String) async -> Int? {
        try? await cardClient.searchIds(search, nil).count
    }

    func deckChoices() async -> [StudyDeckChoice] {
        let tree = (try? await deckClient.fetchTree()) ?? []
        var choices = [StudyDeckChoice.all]
        func walk(_ nodes: [DeckTreeNode]) {
            for node in nodes where !node.isFiltered {
                choices.append(
                    StudyDeckChoice(
                        id: node.id.rawValue,
                        title: node.fullName.replacingOccurrences(of: "::", with: " · "),
                        fullName: node.fullName
                    )
                )
                walk(node.children)
            }
        }
        walk(tree)
        return choices
    }

    private static func dayTotals(_ reviews: [Int: ReviewCountsAndTimes.Reviews]) -> [Int: Int] {
        reviews.reduce(into: [:]) { result, entry in
            let total = entry.value.learn + entry.value.relearn + entry.value.young
                + entry.value.mature + entry.value.filtered
            result[-entry.key] = total
        }
    }
}

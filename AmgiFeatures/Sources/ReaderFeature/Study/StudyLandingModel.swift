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
    var spanRows: [StudyTimeRow] = []
    var spanRowsLoading = false

    let progressCoordinator = ReaderProgressCoordinator()

    /// Whole-collection counts captured when the active review session began.
    /// The live ring composition is derived from this anchor so the segments
    /// move as cards are answered without refetching the deck tree per answer.
    private var liveAnchorCounts: DeckCounts?
    private var liveSessionID: UUID?

    @ObservationIgnored @Dependency(\.readerBookClient) private var readerBookClient
    @ObservationIgnored @Dependency(\.collectionStore) private var store
    @ObservationIgnored @Dependency(\.statsClient) private var statsClient
    @ObservationIgnored @Dependency(\.deckClient) private var deckClient
    @ObservationIgnored @Dependency(\.cardClient) private var cardClient

    private var loadToken = 0
    private var spanToken = 0
    private var rolloverHour = 4
    /// Review counts keyed by days-before-today.
    private var reviewTotals: [Int: Int] = [:]
    private var reviewMillis: [Int: Int] = [:]
    /// Cards due on a future Anki day, keyed by days ahead (1 = tomorrow).
    private var futureDueCounts: [Int: Int] = [:]

    func load() async {
        loadToken += 1
        let token = loadToken
        let hadContent: Bool
        if case .loaded = contentState { hadContent = true } else { hadContent = false }
        do {
            // 1. Deck tree → top-level decks only. Parent counts already
            //    aggregate descendants, so a deck with due subdecks still
            //    surfaces. Subdeck names become a caption, not nested rows.
            let tree = try await store.tree()
            guard token == loadToken else { return }
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
            let learningToday = (try? await statsClient.learningDueToday(search: "")) ?? treeLearn
            let learningReturning = max(0, learningToday - treeLearn)
            let totalReview = tree.reduce(0) { $0 + $1.counts.reviewCount }
            let deckCount = tree.filter { $0.counts.total > 0 }.count
            guard token == loadToken else { return }

            let weekday = Date().formatted(.dateTime.weekday(.wide))
            let subtitleLabel = deckCount == 0
                ? weekday
                : "\(weekday) · \(deckCount) deck\(deckCount == 1 ? "" : "s") due"
            let dayProgress = await resolveCollectionProgress(totalDue: totalDue)
            guard token == loadToken else { return }

            // Carry streak/forecast across a refresh so the second phase
            // doesn't flash back to a placeholder.
            let carried = carriedSummary
            let summary = StudySummaryData(
                totalDue: totalDue,
                newCount: totalNew,
                learnCount: treeLearn,
                reviewCount: totalReview,
                todayLabel: "Today",
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
                name: "Study · Selection",
                search: search,
                limit: UInt32(max(1, limit)),
                order: .due,
                reschedule: reschedule
            )
            let created = try await deckClient.createFilteredDeck(spec)
            let gathered = try await deckClient.rebuildFilteredDeck(created.id)
            guard gathered > 0 else {
                return (nil, "No cards matched.")
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

    var canStepFuture: Bool { dayOffset > -StudySpan.futureLimit }

    var spanTitle: String {
        StudySpan.title(grain: grain, todayStart: todayStart, anchor: dayOffset)
    }

    var spanHeadline: String {
        guard !showsTodayDesk else { return "" }
        if grain == .day, dayOffset < 0 {
            let count = spanRows.first?.count ?? futureDueCounts[-dayOffset] ?? 0
            return "\(count) due"
        }
        let count = spanRows.first { $0.id == "reviewed" }?.count ?? reviewedInSpan
        let minutes = reviewedMillisInSpan / 60_000
        if minutes > 0 {
            return "\(count) reviewed · \(minutes) min"
        }
        return "\(count) reviewed"
    }

    var chart: StudyChartModel {
        let calendar = Calendar.current
        switch grain {
        case .day, .week:
            let offsets = StudySpan.weekOffsets(todayStart: todayStart, anchor: dayOffset, calendar: calendar)
            let columns = offsets.map { offset in
                let day = StudySpan.date(todayStart: todayStart, offset: offset, calendar: calendar)
                let weekday = calendar.component(.weekday, from: day)
                let symbols = calendar.veryShortWeekdaySymbols
                let label = symbols.indices.contains(weekday - 1) ? symbols[weekday - 1] : ""
                return StudyChartColumn(
                    offset: offset,
                    label: label,
                    value: activityCount(offset),
                    isSelected: grain == .day && offset == dayOffset,
                    isToday: offset == 0,
                    isFuture: offset < 0
                )
            }
            return .bars(columns)
        case .month:
            let headers = StudySpan.weekdayHeaders(calendar: calendar)
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
                    isSelected: false,
                    isToday: offset == 0,
                    isFuture: (offset ?? 0) < 0
                )
            }
            return .month(headers: headers, cells: cells)
        }
    }

    func step(towardsPast: Bool) {
        let sign = towardsPast ? 1 : -1
        switch grain {
        case .day:
            dayOffset = StudySpan.clamped(dayOffset + sign)
        case .week:
            dayOffset = StudySpan.clamped(dayOffset + sign * 7)
        case .month:
            let calendar = Calendar.current
            let anchor = StudySpan.date(todayStart: todayStart, offset: dayOffset, calendar: calendar)
            let moved = calendar.date(byAdding: .month, value: towardsPast ? -1 : 1, to: anchor) ?? anchor
            dayOffset = StudySpan.clamped(StudySpan.offset(todayStart: todayStart, dayStart: moved, calendar: calendar))
        }
        Task { await reloadSpanRows() }
    }

    func selectGrain(_ grain: StudyGrain) {
        self.grain = grain
        Task { await reloadSpanRows() }
    }

    /// A bar or month cell drops the page onto that day.
    func selectDay(_ offset: Int) {
        grain = .day
        dayOffset = StudySpan.clamped(offset)
        Task { await reloadSpanRows() }
    }

    private var carriedSummary: StudySummaryData? {
        if case .loaded(let summary, _, _) = contentState { return summary }
        return nil
    }

    /// Streak, time studied, tomorrow, and the rollover note. Published
    /// onto whatever summary is current so a live review repaint in
    /// between isn't overwritten with the pre-session counts.
    private func loadActivity(token: Int) async {
        let graphs = try? await statsClient.fetchGraphs("", 400)
        guard token == loadToken, case .loaded(let summary, let decks, let reading) = contentState else { return }
        if let graphs {
            rolloverHour = graphs.rolloverHour
            reviewTotals = Self.dayTotals(graphs.reviews.count)
            reviewMillis = Self.dayTotals(graphs.reviews.time)
            futureDueCounts = graphs.futureDue.futureDue
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
    }

    func selectBook(_ bookID: String) {
        guard let configuration = ReaderConfigurationLoader.loadConfiguration() else { return }
        Task {
            if let book = try? await readerBookClient.loadBook(bookID, configuration) {
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

        contentState = .loaded(
            summary: summary.withLiveCounts(
                totalDue: whole.total,
                newCount: whole.newCount,
                learnCount: whole.learnCount,
                reviewCount: whole.reviewCount
            ),
            decks: decks,
            continueReading: continueReading
        )
    }

    /// Forgets the live-session anchor. The next full `load()` (triggered by
    /// the review-end generation bump) restores a fresh whole-collection
    /// snapshot, so the displayed ring keeps its last accurate state in the
    /// interim.
    func clearLiveCounts() {
        liveSessionID = nil
        liveAnchorCounts = nil
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
            return "Includes \(shown)…"
        }
        return "Includes \(shown)"
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

    private func resolveCollectionProgress(totalDue: Int) async -> (reviewedToday: Int, dueBaselineToday: Int) {
        do {
            let completedToday = try await statsClient.graduatedToday(search: "")
            // Live denominator (completed + remaining) rather than a frozen
            // baseline, so the ring can't read 100% while cards are still due.
            let baseline = max(completedToday + totalDue, 1)
            return (completedToday, baseline)
        } catch {
            return (0, max(totalDue, 1))
        }
    }

    /// The book opened most recently, only when it has saved progress.
    private func loadContinueReading() async -> StudyReadingRecData? {
        guard let configuration = ReaderConfigurationLoader.loadConfiguration(),
              let books = try? await readerBookClient.loadBooks(configuration) else {
            return nil
        }

        var best: (book: ReaderBook, at: Date)?
        for book in books {
            guard let at = await progressCoordinator.resolved(bookID: book.id)?.updatedAt else { continue }
            if let current = best {
                if at > current.at { best = (book, at) }
            } else {
                best = (book, at)
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

    private func reloadSpanRows() async {
        spanToken += 1
        let token = spanToken
        guard !showsTodayDesk else {
            spanRows = []
            spanRowsLoading = false
            return
        }
        spanRows = []
        spanRowsLoading = true
        defer { if token == spanToken { spanRowsLoading = false } }

        let spanName = spanTitle
        if grain == .day, dayOffset < 0 {
            let ahead = -dayOffset
            let search = StudySpan.dueSearch(daysAhead: ahead)
            let count = (try? await cardClient.searchIds(search, nil).count) ?? (futureDueCounts[ahead] ?? 0)
            guard token == spanToken else { return }
            spanRows = [StudySpan.dueRow(count: count, daysAhead: ahead, spanName: spanName)]
            return
        }

        guard let window = StudySpan.ratingWindow(offsets: spanOffsets) else {
            guard token == spanToken else { return }
            spanRows = StudySpan.ratingRows(counts: [:], oldest: 0, newest: 0, spanName: spanName)
            return
        }

        let counts = await countCriteria(window: window)
        guard token == spanToken else { return }
        spanRows = StudySpan.ratingRows(
            counts: counts,
            oldest: window.oldest,
            newest: window.newest,
            spanName: spanName
        )
    }

    private func countCriteria(window: (oldest: Int, newest: Int)) async -> [String: Int] {
        let client = cardClient
        return await withTaskGroup(of: (String, Int).self) { group in
            for criterion in StudySpan.criteria {
                let search = StudySpan.criterionSearch(
                    ease: criterion.ease,
                    extra: criterion.extra,
                    oldest: window.oldest,
                    newest: window.newest
                )
                group.addTask {
                    let count = (try? await client.searchIds(search, nil).count) ?? 0
                    return (criterion.id, count)
                }
            }
            var counts: [String: Int] = [:]
            for await pair in group {
                counts[pair.0] = pair.1
            }
            return counts
        }
    }

    func matchCount(_ search: String) async -> Int {
        (try? await cardClient.searchIds(search, nil).count) ?? 0
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

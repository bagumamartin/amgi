public import Foundation

/// How wide a span the Study page is standing on.
public enum StudyGrain: String, CaseIterable, Identifiable, Sendable {
    case day
    case week
    case month

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .day: "Day"
        case .week: "Week"
        case .month: "Month"
        }
    }
}

/// One bar in the day or week chart. `offset` is days before today
/// (0 = today, 1 = yesterday, −1 = tomorrow).
public struct StudyChartColumn: Identifiable, Equatable, Sendable {
    public let offset: Int
    public let label: String
    public let value: Int
    public let isSelected: Bool
    public let isToday: Bool
    public let isFuture: Bool

    public var id: Int { offset }

    public init(
        offset: Int,
        label: String,
        value: Int,
        isSelected: Bool,
        isToday: Bool,
        isFuture: Bool
    ) {
        self.offset = offset
        self.label = label
        self.value = value
        self.isSelected = isSelected
        self.isToday = isToday
        self.isFuture = isFuture
    }
}

/// One cell in the month grid. A nil offset is the blank before the 1st.
public struct StudyMonthCell: Identifiable, Equatable, Sendable {
    public let index: Int
    public let offset: Int?
    public let dayNumber: String
    public let value: Int
    public let isSelected: Bool
    public let isToday: Bool
    public let isFuture: Bool

    public var id: Int { index }

    public init(
        index: Int,
        offset: Int?,
        dayNumber: String,
        value: Int,
        isSelected: Bool,
        isToday: Bool,
        isFuture: Bool
    ) {
        self.index = index
        self.offset = offset
        self.dayNumber = dayNumber
        self.value = value
        self.isSelected = isSelected
        self.isToday = isToday
        self.isFuture = isFuture
    }
}

public enum StudyChartModel: Equatable, Sendable {
    case bars([StudyChartColumn])
    case month(headers: [String], cells: [StudyMonthCell])
}

/// A row under the chart: a rating total, or the cards due on a future day.
public struct StudyTimeRow: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let count: Int
    public let search: String
    public let detailTitle: String
    public let emptyMessage: String
    public let reschedulesByDefault: Bool

    public init(
        id: String,
        title: String,
        count: Int,
        search: String,
        detailTitle: String,
        emptyMessage: String,
        reschedulesByDefault: Bool
    ) {
        self.id = id
        self.title = title
        self.count = count
        self.search = search
        self.detailTitle = detailTitle
        self.emptyMessage = emptyMessage
        self.reschedulesByDefault = reschedulesByDefault
    }
}

/// A deck the row screen can narrow to. `id` 0 is the whole collection.
public struct StudyDeckChoice: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let title: String
    public let fullName: String

    public init(id: Int64, title: String, fullName: String) {
        self.id = id
        self.title = title
        self.fullName = fullName
    }

    public static let all = StudyDeckChoice(id: 0, title: "All decks", fullName: "")
}

/// Day-offset and search math for the Study page.
///
/// Offsets are days before the current Anki day: 0 is today, positive is
/// the past, negative is the future. `rated:` counts backward from the
/// next rollover, so one day is the difference of two windows.
public enum StudySpan {
    public static let pastLimit = 370
    public static let futureLimit = 60

    public static func date(todayStart: Date, offset: Int, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: -offset, to: todayStart) ?? todayStart
    }

    public static func offset(todayStart: Date, dayStart: Date, calendar: Calendar = .current) -> Int {
        let days = calendar.dateComponents([.day], from: todayStart, to: dayStart).day ?? 0
        return -days
    }

    public static func clamped(_ offset: Int) -> Int {
        min(pastLimit, max(-futureLimit, offset))
    }

    /// Seven Anki-day offsets for the week that contains `anchor`, ordered
    /// from the locale's first weekday.
    public static func weekOffsets(
        todayStart: Date,
        anchor: Int,
        calendar: Calendar = .current
    ) -> [Int] {
        let day = date(todayStart: todayStart, offset: anchor, calendar: calendar)
        let weekday = calendar.component(.weekday, from: day)
        let delta = (weekday - calendar.firstWeekday + 7) % 7
        let start = calendar.date(byAdding: .day, value: -delta, to: day) ?? day
        return (0..<7).map { step in
            let date = calendar.date(byAdding: .day, value: step, to: start) ?? start
            return offset(todayStart: todayStart, dayStart: date, calendar: calendar)
        }
    }

    /// Month grid, Sunday-or-locale aligned, with nils in the leading blanks.
    public static func monthOffsets(
        todayStart: Date,
        anchor: Int,
        calendar: Calendar = .current
    ) -> [Int?] {
        let day = date(todayStart: todayStart, offset: anchor, calendar: calendar)
        let parts = calendar.dateComponents([.year, .month], from: day)
        guard let first = calendar.date(from: parts),
              let range = calendar.range(of: .day, in: .month, for: first) else {
            return []
        }
        let weekday = calendar.component(.weekday, from: first)
        let lead = (weekday - calendar.firstWeekday + 7) % 7
        var cells: [Int?] = Array(repeating: nil, count: lead)
        for dayNumber in range {
            var parts = parts
            parts.day = dayNumber
            let date = calendar.date(from: parts) ?? first
            cells.append(offset(todayStart: todayStart, dayStart: date, calendar: calendar))
        }
        while cells.count % 7 != 0 {
            cells.append(nil)
        }
        return cells
    }

    public static func weekdayHeaders(calendar: Calendar = .current) -> [String] {
        let symbols = calendar.veryShortWeekdaySymbols
        let start = calendar.firstWeekday - 1
        guard symbols.count == 7, start >= 0, start < 7 else { return symbols }
        return Array(symbols[start...] + symbols[..<start])
    }

    /// Inclusive window of days-before-today. Nil when every offset is in the future.
    public static func ratingWindow(offsets: [Int]) -> (oldest: Int, newest: Int)? {
        let past = offsets.filter { $0 >= 0 }
        guard let oldest = past.max(), let newest = past.min() else { return nil }
        return (oldest, newest)
    }

    /// `ease` is 1...4. Nil matches every answer button.
    public static func ratedSearch(ease: Int?, oldest: Int, newest: Int) -> String {
        let oldest = max(oldest, newest, 0)
        let newest = max(min(newest, oldest), 0)
        let easeSuffix = ease.map { ":\($0)" } ?? ""
        if newest == 0 {
            return "rated:\(oldest + 1)\(easeSuffix)"
        }
        return "rated:\(oldest + 1)\(easeSuffix) -rated:\(newest)\(easeSuffix)"
    }

    public static func dueSearch(daysAhead: Int) -> String {
        "is:review prop:due=\(max(1, daysAhead))"
    }

    public static func dayTitle(offset: Int, day: Date, calendar: Calendar = .current) -> String {
        switch offset {
        case 0: return "Today"
        case 1: return "Yesterday"
        case -1: return "Tomorrow"
        default:
            let weekday = day.formatted(dateFormat(calendar: calendar).weekday(.abbreviated))
            let dayNumber = calendar.component(.day, from: day)
            let month = day.formatted(dateFormat(calendar: calendar).month(.abbreviated))
            return "\(weekday) \(dayNumber) \(month)"
        }
    }

    public static func weekTitle(
        todayStart: Date,
        anchor: Int,
        calendar: Calendar = .current
    ) -> String {
        let offsets = weekOffsets(todayStart: todayStart, anchor: anchor, calendar: calendar)
        guard let first = offsets.first, let last = offsets.last else { return "This week" }
        if offsets.contains(0) { return "This week" }
        let start = date(todayStart: todayStart, offset: first, calendar: calendar)
        let end = date(todayStart: todayStart, offset: last, calendar: calendar)
        return "\(dayMonth(start, calendar: calendar)) – \(dayMonth(end, calendar: calendar))"
    }

    public static func monthTitle(
        todayStart: Date,
        anchor: Int,
        calendar: Calendar = .current
    ) -> String {
        let day = date(todayStart: todayStart, offset: anchor, calendar: calendar)
        let sameYear = calendar.component(.year, from: day) == calendar.component(.year, from: todayStart)
        let format = dateFormat(calendar: calendar)
        if sameYear {
            return day.formatted(format.month(.wide))
        }
        return day.formatted(format.month(.wide).year())
    }

    public static func title(
        grain: StudyGrain,
        todayStart: Date,
        anchor: Int,
        calendar: Calendar = .current
    ) -> String {
        switch grain {
        case .day:
            dayTitle(
                offset: anchor,
                day: date(todayStart: todayStart, offset: anchor, calendar: calendar),
                calendar: calendar
            )
        case .week:
            weekTitle(todayStart: todayStart, anchor: anchor, calendar: calendar)
        case .month:
            monthTitle(todayStart: todayStart, anchor: anchor, calendar: calendar)
        }
    }

    /// One restudy cut for a span. The search is the span's `rated:` window
    /// plus `extra`. Easy and Solid default to leaving the schedule alone.
    public struct Criterion: Sendable, Equatable {
        public let id: String
        public let title: String
        public let ease: Int?
        public let extra: String
        public let reschedulesByDefault: Bool
        public let emptyNoun: String

        public init(
            id: String,
            title: String,
            ease: Int?,
            extra: String,
            reschedulesByDefault: Bool,
            emptyNoun: String
        ) {
            self.id = id
            self.title = title
            self.ease = ease
            self.extra = extra
            self.reschedulesByDefault = reschedulesByDefault
            self.emptyNoun = emptyNoun
        }
    }

    public static let criteria: [Criterion] = [
        Criterion(id: "leeches", title: "Leeches", ease: nil, extra: "tag:leech", reschedulesByDefault: true, emptyNoun: "leeches"),
        Criterion(id: "relapsed", title: "Relapsed", ease: 1, extra: "prop:lapses>=1", reschedulesByDefault: true, emptyNoun: "relapses"),
        Criterion(id: "hard", title: "Hard", ease: 2, extra: "", reschedulesByDefault: true, emptyNoun: "Hard ratings"),
        Criterion(id: "solid", title: "Solid", ease: 3, extra: "prop:lapses=0", reschedulesByDefault: false, emptyNoun: "solid cards"),
        Criterion(id: "easy", title: "Easy", ease: 4, extra: "", reschedulesByDefault: false, emptyNoun: "Easy ratings"),
        Criterion(id: "reviewed", title: "All reviewed", ease: nil, extra: "", reschedulesByDefault: true, emptyNoun: "reviews"),
    ]

    public static func criterionSearch(ease: Int?, extra: String, oldest: Int, newest: Int) -> String {
        let base = ratedSearch(ease: ease, oldest: oldest, newest: newest)
        let extra = extra.trimmingCharacters(in: .whitespaces)
        guard !extra.isEmpty else { return base }
        return "\(base) \(extra)"
    }

    /// `deck:"Name"` includes subdecks. Turning that off excludes `Name::*`.
    public static func scopedSearch(_ base: String, deckFullName: String, includeSubdecks: Bool) -> String {
        guard !deckFullName.isEmpty else { return base }
        let term = quotedDeck(deckFullName)
        if includeSubdecks { return "\(base) \(term)" }
        return "\(base) \(term) -\(quotedDeck(deckFullName + "::*"))"
    }

    public static func ratingRows(
        counts: [String: Int],
        oldest: Int,
        newest: Int,
        spanName: String
    ) -> [StudyTimeRow] {
        criteria.map { criterion in
            StudyTimeRow(
                id: criterion.id,
                title: criterion.title,
                count: counts[criterion.id] ?? 0,
                search: criterionSearch(
                    ease: criterion.ease,
                    extra: criterion.extra,
                    oldest: oldest,
                    newest: newest
                ),
                detailTitle: "\(criterion.title) · \(spanName)",
                emptyMessage: emptyCriterionMessage(noun: criterion.emptyNoun, spanName: spanName),
                reschedulesByDefault: criterion.reschedulesByDefault
            )
        }
    }

    private static func quotedDeck(_ name: String) -> String {
        let escaped = name
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "deck:\"\(escaped)\""
    }

    public static func dueRow(count: Int, daysAhead: Int, spanName: String) -> StudyTimeRow {
        StudyTimeRow(
            id: "due",
            title: "Due this day",
            count: count,
            search: dueSearch(daysAhead: daysAhead),
            detailTitle: "Due · \(spanName)",
            emptyMessage: dueEmptyMessage(spanName: spanName),
            reschedulesByDefault: true
        )
    }

    public static func emptyCriterionMessage(noun: String, spanName: String) -> String {
        "No \(noun) \(spanPhrase(spanName))"
    }

    public static func dueEmptyMessage(spanName: String) -> String {
        if spanName == "Tomorrow" { return "Nothing due tomorrow" }
        return "Nothing due on \(spanName)"
    }

    private static func dayMonth(_ day: Date, calendar: Calendar) -> String {
        let dayNumber = calendar.component(.day, from: day)
        let month = day.formatted(dateFormat(calendar: calendar).month(.abbreviated))
        return "\(dayNumber) \(month)"
    }

    /// "yesterday", "this week", "in September", "in 12–18 Sep".
    public static func spanPhrase(_ spanName: String) -> String {
        switch spanName.lowercased() {
        case "today", "yesterday", "tomorrow", "this week":
            spanName.lowercased()
        default:
            "in \(spanName)"
        }
    }

    private static func dateFormat(calendar: Calendar) -> Date.FormatStyle {
        var format = Date.FormatStyle()
        format.calendar = calendar
        format.locale = calendar.locale ?? .autoupdatingCurrent
        return format
    }
}

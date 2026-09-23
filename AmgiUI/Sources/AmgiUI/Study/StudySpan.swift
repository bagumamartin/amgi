public import Foundation

/// How wide a span the Study page is standing on.
public enum StudyGrain: String, CaseIterable, Identifiable, Sendable {
    case day
    case week
    case month
    case year

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .day: "Day"
        case .week: "Week"
        case .month: "Month"
        case .year: "Year"
        }
    }
}

/// One bar in the day or week chart. `offset` is days before today
/// (0 = today, 1 = yesterday, −1 = tomorrow).
public struct StudyChartColumn: Identifiable, Equatable, Sendable {
    public let offset: Int
    /// Date or hour, drawn above the bar.
    public let label: String
    /// Weekday letter under a week bar. Empty on the day chart.
    public let axis: String
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
        isFuture: Bool,
        axis: String = ""
    ) {
        self.offset = offset
        self.label = label
        self.axis = axis
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

/// One month inside the year wall. `monthOffset` is the Anki-day offset of
/// the 1st, which is what tapping the month name opens.
public struct StudyYearMonth: Identifiable, Equatable, Sendable {
    public let month: Int
    public let name: String
    public let monthOffset: Int
    public let isCurrent: Bool
    public let cells: [StudyMonthCell]

    public var id: Int { month }

    public init(month: Int, name: String, monthOffset: Int, isCurrent: Bool, cells: [StudyMonthCell]) {
        self.month = month
        self.name = name
        self.monthOffset = monthOffset
        self.isCurrent = isCurrent
        self.cells = cells
    }
}

/// One word on the day-chart axis. `slot` is the hour column it is
/// centered on, so Morning sits on 6, Noon on 12, Evening on 18,
/// Midnight on 0.
public struct StudyAxisLabel: Equatable, Sendable, Identifiable {
    public let title: String
    public let slot: Int

    public var id: String { "\(slot)-\(title)" }

    public init(title: String, slot: Int) {
        self.title = title
        self.slot = slot
    }
}

public enum StudyChartModel: Equatable, Sendable {
    case bars([StudyChartColumn])
    /// Twenty-four hour bars for one Anki day, starting at the rollover hour.
    /// Hour numbers sit above the bars. The axis is morning, noon, evening,
    /// and midnight, each centered on its hour.
    case hours(columns: [StudyChartColumn], axis: [StudyAxisLabel])
    case month(headers: [String], cells: [StudyMonthCell])
    case year(months: [StudyYearMonth])
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
    /// Five years of Anki days, shared with the graphs fetch.
    public static let pastLimit = 365 * 5
    public static let futureLimit = 60

    public static func date(todayStart: Date, offset: Int, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: -offset, to: todayStart) ?? todayStart
    }

    public static func offset(todayStart: Date, dayStart: Date, calendar: Calendar = .current) -> Int {
        // Compare calendar dates, not the raw interval. An Anki day starts at
        // the rollover hour, so a 4am start is only 20 hours from the next
        // midnight and a raw day-count collapses two dates onto one.
        let from = calendar.dateComponents([.year, .month, .day], from: todayStart)
        let to = calendar.dateComponents([.year, .month, .day], from: dayStart)
        let start = calendar.date(from: from) ?? todayStart
        let end = calendar.date(from: to) ?? dayStart
        let days = calendar.dateComponents([.day], from: start, to: end).day ?? 0
        return -days
    }

    /// Clock hour for one slot of an Anki day. Slot 0 is the rollover hour.
    public static func ankiDayClockHour(rolloverHour: Int, slot: Int) -> Int {
        let start = ((rolloverHour % 24) + 24) % 24
        return (start + slot) % 24
    }

    /// True when the locale's hour cycle is 24-hour. Anything else,
    /// including an unknown cycle, stays 12-hour.
    public static func uses24HourClock(locale: Locale = .current) -> Bool {
        let format = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: locale) ?? ""
        return format.contains("H")
    }

    /// Axis bookend. 12-hour keeps the meridiem (`4am`); 24-hour is the hour (`16`).
    public static func hourLabel(_ clockHour: Int, twentyFourHour: Bool = false) -> String {
        let hour = ((clockHour % 24) + 24) % 24
        if twentyFourHour { return String(hour) }
        switch hour {
        case 0: return "12am"
        case 12: return "12pm"
        default: return hour < 12 ? "\(hour)am" : "\(hour - 12)pm"
        }
    }

    /// Short label under one hour bar. 12-hour is the number plus `a`/`p`.
    public static func hourColumnLabel(_ clockHour: Int, twentyFourHour: Bool = false) -> String {
        let hour = ((clockHour % 24) + 24) % 24
        if twentyFourHour { return String(hour) }
        switch hour {
        case 0: return "12a"
        case 12: return "12p"
        default: return hour < 12 ? "\(hour)a" : "\(hour - 12)p"
        }
    }

    /// Morning (6), noon (12), evening (18), and midnight (0), each centered
    /// on that hour's column of the Anki day.
    public static func dayAxisMarks(rolloverHour: Int) -> [StudyAxisLabel] {
        let start = ((rolloverHour % 24) + 24) % 24
        let periods = [("Morning", 6), ("Noon", 12), ("Evening", 18), ("Midnight", 0)]
        return periods.map { name, clock in
            StudyAxisLabel(title: name, slot: (clock - start + 24) % 24)
        }
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
            let dayNumber = calendar.component(.day, from: day)
            let month = day.formatted(dateFormat(calendar: calendar).month(.abbreviated))
            return "\(dayNumber) \(month)"
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

    public static func yearTitle(
        todayStart: Date,
        anchor: Int,
        calendar: Calendar = .current
    ) -> String {
        let day = date(todayStart: todayStart, offset: anchor, calendar: calendar)
        return String(calendar.component(.year, from: day))
    }

    /// Line under the large title. Day is the full weekday. Week is the
    /// week-of-year. Month is the season, flipped south of the equator.
    /// Year is leap or common.
    public static func subtitle(
        grain: StudyGrain,
        todayStart: Date,
        anchor: Int,
        calendar: Calendar = .current
    ) -> String {
        switch grain {
        case .day:
            let day = date(todayStart: todayStart, offset: anchor, calendar: calendar)
            return day.formatted(dateFormat(calendar: calendar).weekday(.wide))
        case .week:
            let offsets = weekOffsets(todayStart: todayStart, anchor: anchor, calendar: calendar)
            let probe = offsets.first ?? anchor
            let day = date(todayStart: todayStart, offset: probe, calendar: calendar)
            let week = calendar.component(.weekOfYear, from: day)
            return "Week \(week)"
        case .month:
            let day = date(todayStart: todayStart, offset: anchor, calendar: calendar)
            let month = calendar.component(.month, from: day)
            return seasonName(month: month, calendar: calendar)
        case .year:
            let day = date(todayStart: todayStart, offset: anchor, calendar: calendar)
            let year = calendar.component(.year, from: day)
            return isLeapYear(year) ? "Leap year" : "Common year"
        }
    }

    public static func isLeapYear(_ year: Int) -> Bool {
        (year % 4 == 0 && year % 100 != 0) || (year % 400 == 0)
    }

    /// Meteorological season. Southern regions and time zones swap the
    /// northern names, because September is spring there.
    public static func seasonName(month: Int, calendar: Calendar = .current) -> String {
        let southern = isSouthernHemisphere(
            locale: calendar.locale ?? .current,
            timeZone: calendar.timeZone
        )
        switch month {
        case 3, 4, 5: return southern ? autumnName(locale: calendar.locale) : "Spring"
        case 6, 7, 8: return southern ? "Winter" : "Summer"
        case 9, 10, 11: return southern ? "Spring" : autumnName(locale: calendar.locale)
        default: return southern ? "Summer" : "Winter"
        }
    }

    public static func isSouthernHemisphere(locale: Locale, timeZone: TimeZone) -> Bool {
        if let region = locale.region?.identifier.uppercased(), southernRegions.contains(region) {
            return true
        }
        let zone = timeZone.identifier
        return southernTimeZones.contains { zone == $0 || zone.hasPrefix($0) }
    }

    private static func autumnName(locale: Locale?) -> String {
        locale?.region?.identifier == "US" ? "Fall" : "Autumn"
    }

    /// Countries whose population lives mostly south of the equator.
    private static let southernRegions: Set<String> = [
        "AO", "AR", "AU", "BO", "BR", "BW", "CL", "FJ", "LS", "MG", "MW", "MZ",
        "NA", "NC", "NZ", "PE", "PG", "PY", "RE", "SB", "SC", "SZ", "TL", "TO",
        "UY", "VU", "WS", "ZA", "ZM", "ZW",
    ]

    private static let southernTimeZones: [String] = [
        "Australia/", "Antarctica/",
        "Pacific/Auckland", "Pacific/Chatham", "Pacific/Fiji", "Pacific/Apia",
        "Pacific/Tongatapu", "Pacific/Port_Moresby", "Pacific/Guadalcanal",
        "America/Argentina", "America/Buenos_Aires", "America/Santiago",
        "America/Asuncion", "America/Montevideo", "America/Sao_Paulo",
        "America/La_Paz", "America/Lima",
        "Africa/Johannesburg", "Africa/Maputo", "Africa/Harare",
        "Africa/Lusaka", "Africa/Windhoek", "Africa/Gaborone",
    ]

    public static func title(
        grain: StudyGrain,
        todayStart: Date,
        anchor: Int,
        calendar: Calendar = .current
    ) -> String {
        switch grain {
        case .day:
            return dayTitle(
                offset: anchor,
                day: date(todayStart: todayStart, offset: anchor, calendar: calendar),
                calendar: calendar
            )
        case .week:
            return weekTitle(todayStart: todayStart, anchor: anchor, calendar: calendar)
        case .month:
            return monthTitle(todayStart: todayStart, anchor: anchor, calendar: calendar)
        case .year:
            return yearTitle(todayStart: todayStart, anchor: anchor, calendar: calendar)
        }
    }

    /// True when the span still contains the current Anki day.
    public static func isCurrent(
        grain: StudyGrain,
        todayStart: Date,
        anchor: Int,
        calendar: Calendar = .current
    ) -> Bool {
        switch grain {
        case .day:
            return anchor == 0
        case .week:
            return weekOffsets(todayStart: todayStart, anchor: anchor, calendar: calendar).contains(0)
        case .month:
            let day = date(todayStart: todayStart, offset: anchor, calendar: calendar)
            return calendar.isDate(day, equalTo: todayStart, toGranularity: .month)
        case .year:
            let day = date(todayStart: todayStart, offset: anchor, calendar: calendar)
            return calendar.isDate(day, equalTo: todayStart, toGranularity: .year)
        }
    }

    public static func jumpTitle(grain: StudyGrain) -> String {
        switch grain {
        case .day: "Today"
        case .week, .month, .year: "Present"
        }
    }

    /// Under an hour stays `N min`. At an hour, minutes are spelled out,
    /// and a zero remainder drops them (`2 hours`).
    public static func studiedDuration(minutes: Int) -> String? {
        guard minutes > 0 else { return nil }
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let remainder = minutes % 60
        let hourWord = hours == 1 ? "hour" : "hours"
        if remainder == 0 { return "\(hours) \(hourWord)" }
        let minuteWord = remainder == 1 ? "minute" : "minutes"
        return "\(hours) \(hourWord) \(remainder) \(minuteWord)"
    }

    /// Twelve mini months for the calendar year that contains `anchor`.
    /// `activity` receives an Anki-day offset and returns that day's count
    /// (reviews in the past, cards scheduled in the future).
    public static func yearChart(
        todayStart: Date,
        anchor: Int,
        calendar: Calendar = .current,
        activity: (Int) -> Int
    ) -> (year: Int, isCurrentYear: Bool, months: [StudyYearMonth]) {
        let anchorDate = date(todayStart: todayStart, offset: anchor, calendar: calendar)
        let year = calendar.component(.year, from: anchorDate)
        let currentYear = calendar.component(.year, from: todayStart)
        let currentMonth = calendar.component(.month, from: todayStart)
        let months: [StudyYearMonth] = (1...12).compactMap { month in
            var parts = DateComponents()
            parts.year = year
            parts.month = month
            parts.day = 1
            guard let first = calendar.date(from: parts) else { return nil }
            let monthOffset = offset(todayStart: todayStart, dayStart: first, calendar: calendar)
            let offsets = monthOffsets(todayStart: todayStart, anchor: monthOffset, calendar: calendar)
            let cells = offsets.enumerated().map { index, dayOffset in
                let number: String
                if let dayOffset {
                    let day = date(todayStart: todayStart, offset: dayOffset, calendar: calendar)
                    number = String(calendar.component(.day, from: day))
                } else {
                    number = ""
                }
                return StudyMonthCell(
                    index: index,
                    offset: dayOffset,
                    dayNumber: number,
                    value: dayOffset.map(activity) ?? 0,
                    isSelected: false,
                    isToday: dayOffset == 0,
                    isFuture: (dayOffset ?? 0) < 0
                )
            }
            let name = first.formatted(dateFormat(calendar: calendar).month(.abbreviated))
            return StudyYearMonth(
                month: month,
                name: name,
                monthOffset: monthOffset,
                isCurrent: year == currentYear && month == currentMonth,
                cells: cells
            )
        }
        return (year, year == currentYear, months)
    }

    /// Every Anki-day offset in the calendar year that contains `anchor`.
    public static func yearDayOffsets(
        todayStart: Date,
        anchor: Int,
        calendar: Calendar = .current
    ) -> [Int] {
        yearChart(todayStart: todayStart, anchor: anchor, calendar: calendar, activity: { _ in 0 })
            .months
            .flatMap(\.cells)
            .compactMap(\.offset)
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

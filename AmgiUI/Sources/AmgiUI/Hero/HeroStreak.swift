public import SwiftUI
import AmgiTheme

// MARK: - Model

/// Everything the streak indicator says, derived from the hero's existing
/// payload: the engine's streak count plus the per-day totals the sparkline
/// already carries. No extra fetch.
///
/// `streak` follows `DayStreak.count` — it counts from yesterday when today
/// has no reviews, so a non-zero streak with an empty today is "at risk",
/// not broken.
struct HeroStreakSummary: Equatable {
    enum State: Equatable {
        /// Never studied inside the loaded window.
        case fresh
        /// No current streak; last study was this many days ago.
        case lapsed(daysAgo: Int)
        /// Streak alive through yesterday, nothing studied yet today.
        case atRisk
        /// Studied today.
        case active
        /// Studied today and the streak just landed on a milestone.
        case milestone
    }

    static let milestones = [3, 7, 14, 30, 50, 100, 150, 200, 365, 500, 730, 1000]
    static let weekLength = 7

    let streak: Int
    let state: State
    /// Longest run inside the loaded window, never less than `streak`.
    let best: Int
    /// Oldest → today, `weekLength` entries.
    let week: [Bool]
    /// Days with any review in the last 30 (or fewer if less is loaded).
    let activeDays: Int
    let activeWindow: Int
    /// The next milestone above `streak`, if any.
    let nextMilestone: Int?

    /// - Parameter dayTotals: oldest → newest, last entry is today.
    init(streak: Int, dayTotals: [Int]) {
        let studied = dayTotals.map { $0 > 0 }
        let studiedToday = studied.last ?? false

        var longest = 0
        var run = 0
        for day in studied {
            run = day ? run + 1 : 0
            longest = max(longest, run)
        }

        let week = Array(studied.suffix(Self.weekLength))
        self.week = Array(repeating: false, count: Self.weekLength - week.count) + week

        let recent = studied.suffix(30)
        self.activeWindow = max(recent.count, 1)
        self.activeDays = recent.filter { $0 }.count

        self.streak = streak
        self.best = max(longest, streak)
        self.nextMilestone = Self.milestones.first { $0 > streak }

        if studiedToday {
            self.state = Self.milestones.contains(streak) ? .milestone : .active
        } else if streak > 0 {
            self.state = .atRisk
        } else if let last = studied.lastIndex(of: true) {
            self.state = .lapsed(daysAgo: studied.count - 1 - last)
        } else {
            self.state = .fresh
        }
    }

    /// Progress from the previous milestone (or zero) to the next one.
    var milestoneProgress: Double {
        guard let next = nextMilestone else { return 1 }
        let previous = Self.milestones.last { $0 <= streak } ?? 0
        return Double(streak - previous) / Double(max(next - previous, 1))
    }
}

// MARK: - Compact indicator (hero card)

/// The hero's streak chip: emblem + headline over a 7-day strip, today last,
/// on a living background (`HeroStreakAmbience`) — fire while the streak is
/// alive, drifting snow once it lapses. Tapping stirs it, plays a haptic,
/// and opens `HeroStreakDetails`. A broken or never-started streak still
/// shows the week and says
/// how to (re)start it.
struct HeroStreakIndicator: View {
    let summary: HeroStreakSummary
    /// Fixed animation time for previews and snapshots; nil runs live.
    var stillTime: Double?

    @State private var showsDetails = false
    @State private var tap: Date?
    @State private var fire: HeroFireSimulation

    init(summary: HeroStreakSummary, stillTime: Double? = nil) {
        self.summary = summary
        self.stillTime = stillTime
        let fire = HeroFireSimulation(seed: stillTime == nil ? nil : 7)
        if let stillTime { fire.prewarm(stillTime) }
        _fire = State(initialValue: fire)
    }

    @Environment(\.palette) private var palette
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: AmgiRadius.inset, style: .continuous)
        Button {
            tap = .now
            if summary.isLive && !reduceMotion { fire.flare() }
            showsDetails = true
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 4) {
                    HeroStreakEmblem(state: summary.state, size: 15, fire: fire, tap: tap, stillTime: stillTime)
                        .padding(.vertical, -3)
                    Text(summary.headline(locale: locale))
                        .amgiFont(size: 14, weight: .semibold, relativeTo: .footnote)
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(summary.streak)))
                        .foregroundStyle(headlineColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Spacer(minLength: 2)
                    statusGlyph
                }
                HeroStreakWeek(summary: summary, dotSize: 7)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background {
                ZStack {
                    palette.surface
                    HeroStreakAmbience(mood: mood, fire: fire, milestone: summary.state == .milestone, tap: tap, stillTime: stillTime)
                        .id(mood)
                        .transition(.opacity)
                }
                .clipShape(shape)
            }
            .overlay(shape.strokeBorder(border, lineWidth: summary.state == .milestone ? 1 : 0.5))
            .contentShape(shape)
            .animation(AmgiMotion.standard, value: mood)
            .animation(AmgiMotion.standard, value: summary.streak)
        }
        .buttonStyle(.pressScale)
        .sensoryFeedback(
            mood == .frost ? .impact(weight: .light) : .impact(flexibility: .soft, intensity: 0.9),
            trigger: tap
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(AmgiL10n.text("Streak", locale: locale)), \(summary.headline(locale: locale)). \(summary.status(locale: locale))"
        )
        .accessibilityAddTraits(.isButton)
        #if os(watchOS)
        // AmgiUI is compiled for the watch, which has no popover.
        .sheet(isPresented: $showsDetails) {
            HeroStreakDetails(summary: summary)
        }
        #else
        .popover(isPresented: $showsDetails) {
            HeroStreakDetails(summary: summary)
                .presentationCompactAdaptation(.popover)
        }
        #endif
    }

    @ViewBuilder
    private var statusGlyph: some View {
        switch summary.state {
        case .active:
            Image(systemName: "checkmark.circle.fill")
                .amgiFont(size: 11, weight: .semibold, relativeTo: .caption)
                .foregroundStyle(palette.positive)
        case .milestone:
            Image(systemName: "sparkles")
                .amgiFont(size: 11, weight: .semibold, relativeTo: .caption)
                .foregroundStyle(palette.warning)
        case .atRisk:
            Image(systemName: "exclamationmark.circle.fill")
                .amgiFont(size: 11, weight: .semibold, relativeTo: .caption)
                .foregroundStyle(palette.warning)
        case .lapsed, .fresh:
            Image(systemName: "chevron.right")
                .amgiFont(size: 9, weight: .bold, relativeTo: .caption2)
                .foregroundStyle(palette.info.opacity(0.8))
        }
    }

    private var mood: HeroStreakMood { HeroStreakMood(summary.state) }

    /// Dormant streaks take a quiet, cool tint.
    private var headlineColor: Color {
        summary.isLive ? palette.textPrimary : palette.info.mix(with: palette.textPrimary, by: 0.45)
    }

    private var border: Color {
        switch summary.state {
        case .milestone: palette.warning.opacity(0.7)
        case .active: palette.warning.opacity(0.4)
        case .atRisk: palette.warning.opacity(0.3)
        case .lapsed, .fresh: palette.info.opacity(0.22)
        }
    }
}

// MARK: - Details popover

struct HeroStreakDetails: View {
    let summary: HeroStreakSummary

    @State private var tap: Date?
    @State private var fire = HeroFireSimulation()

    @Environment(\.palette) private var palette
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                // Tap for a flame flare or a passing gust of snow.
                HeroStreakEmblem(state: summary.state, size: 20, fire: fire, tap: tap)
                    .frame(width: 48, height: 48)
                    .background {
                        ZStack {
                            palette.surface
                            HeroStreakAmbience(
                                mood: HeroStreakMood(summary.state),
                                fire: fire,
                                milestone: summary.state == .milestone,
                                tap: tap,
                                source: .center
                            )
                        }
                        .clipShape(Circle())
                    }
                    .contentShape(Circle())
                    .onTapGesture {
                        tap = .now
                        if summary.isLive && !reduceMotion { fire.flare() }
                    }
                    .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.8), trigger: tap)
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.title(locale: locale))
                        .amgiFont(size: 17, weight: .bold, relativeTo: .headline)
                        .foregroundStyle(palette.textPrimary)
                    Text(summary.status(locale: locale))
                        .amgiFont(size: 13, weight: .regular, relativeTo: .subheadline)
                        .foregroundStyle(summary.state == .atRisk ? palette.warning : palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HeroStreakWeek(summary: summary, dotSize: 14, showsWeekdays: true)

            HStack(spacing: 8) {
                stat(
                    eyebrow: AmgiL10n.text("Best", locale: locale),
                    value: summary.dayCount(summary.best, locale: locale),
                    caption: AmgiL10n.text("Last 90 days", locale: locale)
                )
                stat(
                    eyebrow: AmgiL10n.text("Active days", locale: locale),
                    value: AmgiL10n.format("%lld of %lld", [summary.activeDays, summary.activeWindow], locale: locale),
                    caption: AmgiL10n.text("Last 30 days", locale: locale)
                )
            }

            if let next = summary.nextMilestone {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(AmgiL10n.text("Next milestone", locale: locale))
                            .amgiFont(size: 13, weight: .semibold, relativeTo: .footnote)
                            .foregroundStyle(palette.textPrimary)
                        Spacer()
                        Text(summary.dayCount(next, locale: locale))
                            .amgiFont(size: 13, weight: .semibold, relativeTo: .footnote)
                            .monospacedDigit()
                            .foregroundStyle(palette.textSecondary)
                    }
                    ProgressView(value: summary.milestoneProgress)
                        .tint(summary.isLive ? palette.warning : palette.info)
                    Text(AmgiL10n.format("%lld to go", [next - summary.streak], locale: locale))
                        .amgiFont(size: 11, weight: .regular, relativeTo: .caption)
                        .foregroundStyle(palette.textTertiary)
                }
            }
        }
        .padding(16)
        .frame(width: 280, alignment: .leading)
        .background(palette.surfaceElevated)
    }

    private func stat(eyebrow: String, value: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(eyebrow.uppercased(with: locale))
                .amgiFont(size: 10, weight: .semibold, tracking: 0.4, relativeTo: .caption)
                .foregroundStyle(palette.textTertiary)
            Text(value)
                .amgiFont(size: 15, weight: .semibold, relativeTo: .body)
                .monospacedDigit()
                .foregroundStyle(palette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(caption)
                .amgiFont(size: 11, weight: .regular, relativeTo: .caption)
                .foregroundStyle(palette.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: AmgiRadius.inset, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AmgiRadius.inset, style: .continuous)
                .strokeBorder(palette.border, lineWidth: 0.5)
        )
    }
}

// MARK: - Shared pieces

/// Seven dots, oldest → today. Studied days are filled; today is ringed, and
/// ringed in the warning colour while the streak is at risk.
private struct HeroStreakWeek: View {
    let summary: HeroStreakSummary
    let dotSize: CGFloat
    var showsWeekdays = false

    @Environment(\.palette) private var palette
    @Environment(\.locale) private var locale

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(summary.week.enumerated()), id: \.offset) { index, studied in
                let isToday = index == summary.week.count - 1
                VStack(spacing: 4) {
                    if showsWeekdays {
                        Text(weekdayLetter(daysAgo: summary.week.count - 1 - index))
                            .amgiFont(size: 10, weight: isToday ? .bold : .semibold, relativeTo: .caption2)
                            .foregroundStyle(isToday ? palette.textPrimary : palette.textTertiary)
                    }
                    dot(studied: studied, isToday: isToday)
                }
                if index < summary.week.count - 1 {
                    Spacer(minLength: dotSize * 0.4)
                }
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func dot(studied: Bool, isToday: Bool) -> some View {
        if studied {
            Circle()
                .fill(palette.warning.opacity(isToday ? 1 : 0.7))
                .frame(width: dotSize, height: dotSize)
        } else if isToday {
            Circle()
                .strokeBorder(
                    summary.state == .atRisk ? palette.warning : palette.textTertiary,
                    style: StrokeStyle(lineWidth: max(1, dotSize / 7), dash: summary.state == .atRisk ? [2, 1.5] : [])
                )
                .frame(width: dotSize, height: dotSize)
        } else {
            Circle()
                .fill(palette.separator)
                .frame(width: dotSize, height: dotSize)
        }
    }

    private func weekdayLetter(daysAgo: Int) -> String {
        var calendar = Calendar.current
        calendar.locale = locale
        let date = calendar.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
        let weekday = calendar.component(.weekday, from: date)
        return calendar.veryShortWeekdaySymbols[weekday - 1]
    }
}

// MARK: - Copy

extension HeroStreakSummary {
    /// Live streaks are coloured; broken or unstarted ones are muted.
    var isLive: Bool {
        switch state {
        case .active, .milestone, .atRisk: true
        case .lapsed, .fresh: false
        }
    }

    func dayCount(_ days: Int, locale: Locale) -> String {
        days == 1
            ? AmgiL10n.text("1 day", locale: locale)
            : AmgiL10n.format("%lld days", [days], locale: locale)
    }

    /// Chip headline.
    func headline(locale: Locale) -> String {
        switch state {
        case .fresh: AmgiL10n.text("Start a streak", locale: locale)
        case .lapsed: AmgiL10n.text("No streak", locale: locale)
        case .active, .milestone, .atRisk: dayCount(streak, locale: locale)
        }
    }

    /// Popover title.
    func title(locale: Locale) -> String {
        switch state {
        case .fresh: AmgiL10n.text("Start a streak", locale: locale)
        case .lapsed: AmgiL10n.text("No streak", locale: locale)
        case .active, .milestone, .atRisk: AmgiL10n.format("%lld-day streak", [streak], locale: locale)
        }
    }

    /// One sentence on what the state means and what to do next.
    func status(locale: Locale) -> String {
        switch state {
        case .fresh:
            AmgiL10n.text("Review one card to start one", locale: locale)
        case .lapsed(let daysAgo):
            AmgiL10n.format("Last studied %lld days ago", [daysAgo], locale: locale)
        case .atRisk:
            AmgiL10n.text("Study today to keep it", locale: locale)
        case .active:
            AmgiL10n.text("Done today", locale: locale)
        case .milestone:
            AmgiL10n.text("Milestone reached", locale: locale)
        }
    }
}

// MARK: - Previews

#if DEBUG
private extension HeroStreakSummary {
    static func preview(streak: Int, tail: [Int]) -> HeroStreakSummary {
        HeroStreakSummary(streak: streak, dayTotals: Array(repeating: 4, count: 60) + tail)
    }
}

#Preview("Indicator — every state") {
    VStack(alignment: .leading, spacing: 10) {
        ForEach(
            [
                ("Active", HeroStreakSummary.preview(streak: 36, tail: Array(repeating: 5, count: 30))),
                ("Milestone", HeroStreakSummary.preview(streak: 30, tail: [0] + Array(repeating: 5, count: 29) + [6])),
                ("At risk", HeroStreakSummary.preview(streak: 12, tail: [0] + Array(repeating: 5, count: 12) + [0])),
                ("Lapsed", HeroStreakSummary.preview(streak: 0, tail: [3, 2, 0, 0, 0, 0, 0])),
                ("Fresh", HeroStreakSummary(streak: 0, dayTotals: Array(repeating: 0, count: 90))),
            ],
            id: \.0
        ) { name, summary in
            HStack {
                Text(name).amgiFont(size: 12, weight: .regular, relativeTo: .caption).frame(width: 70, alignment: .leading)
                HeroStreakIndicator(summary: summary).frame(width: 120)
            }
        }
    }
    .padding(16)
    .background(Color.gray.opacity(0.12))
    .environment(\.palette, .vividLight)
}

#Preview("Indicator — light and dark snapshots") {
    HStack(spacing: 20) {
        ForEach([false, true], id: \.self) { dark in
            VStack(spacing: 10) {
                HeroStreakIndicator(summary: .preview(streak: 36, tail: [5]), stillTime: 2)
                HeroStreakIndicator(summary: .preview(streak: 30, tail: [5]), stillTime: 2)
                HeroStreakIndicator(summary: .preview(streak: 12, tail: [5, 0]), stillTime: 2)
                HeroStreakIndicator(summary: .preview(streak: 0, tail: [5, 0, 0]), stillTime: 2)
                HeroStreakIndicator(summary: HeroStreakSummary(streak: 0, dayTotals: []), stillTime: 2)
            }
            .frame(width: 130)
            .padding(16)
            .background(dark ? Palette.vividDark.background : Palette.vividLight.background)
            .environment(\.palette, dark ? .vividDark : .vividLight)
            .environment(\.colorScheme, dark ? .dark : .light)
        }
    }
}

#Preview("Details — active") {
    HeroStreakDetails(summary: .preview(streak: 36, tail: Array(repeating: 5, count: 30)))
        .environment(\.palette, .vividLight)
}

#Preview("Details — at risk") {
    HeroStreakDetails(summary: .preview(streak: 12, tail: [0] + Array(repeating: 5, count: 12) + [0]))
        .environment(\.palette, .vividLight)
}

#Preview("Details — lapsed") {
    HeroStreakDetails(summary: .preview(streak: 0, tail: [3, 2, 0, 0, 0, 0, 0]))
        .environment(\.palette, .vividDark)
        .preferredColorScheme(.dark)
}
#endif

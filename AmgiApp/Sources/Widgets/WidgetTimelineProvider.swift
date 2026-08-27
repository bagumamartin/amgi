// AmgiApp/Sources/Widgets/WidgetTimelineProvider.swift
import WidgetKit
import Foundation
import AmgiTheme

struct WidgetEntry: TimelineEntry {
    var date: Date
    var snapshot: WidgetSnapshot
}

struct WidgetTimelineProvider: AppIntentTimelineProvider {
    typealias Intent = AmgiWidgetIntent
    typealias Entry = WidgetEntry

    func placeholder(in context: Context) -> WidgetEntry {
        WidgetEntry(date: Date(), snapshot: .placeholder)
    }

    func snapshot(for configuration: AmgiWidgetIntent, in context: Context) async -> WidgetEntry {
        // The widget process can outlive a theme change made in the app —
        // re-read the shared defaults before rendering (theme-awareness).
        ThemeManager.shared.refreshFromDefaults()
        let deckId = Int64(configuration.deck?.id ?? "0") ?? 0
        let snapshot = WidgetSnapshotStore.read(deckId: deckId) ?? .empty
        return WidgetEntry(date: Date(), snapshot: snapshot)
    }

    func timeline(for configuration: AmgiWidgetIntent, in context: Context) async -> Timeline<WidgetEntry> {
        ThemeManager.shared.refreshFromDefaults()
        let deckId = Int64(configuration.deck?.id ?? "0") ?? 0
        // Distinguish between "found a snapshot" and "fell back to placeholder".
        // Freshness / reload policy must be based on the real snapshot date, not
        // the placeholder's Date() which would always look like "today".
        let maybeSnapshot = WidgetSnapshotStore.read(deckId: deckId)
        let snapshot = maybeSnapshot ?? .empty
        let cal = Calendar.current
        let now = Date()

        var entries: [WidgetEntry] = [WidgetEntry(date: now, snapshot: snapshot)]

        // Generate a rollover entry so completedToday corrects to 0 when the
        // Anki day rolls over (rollover hour from settings — NOT calendar
        // midnight; the snapshot carries the exact next-day-start the app
        // computed from the engine), and the bar chart shifts forward by one
        // day without requiring an app open. Only add this entry when we have
        // a real, fresh snapshot — not for the placeholder.
        let rollover = maybeSnapshot.flatMap(\.nextDayStart)
            .flatMap { $0 > now ? $0 : nil }
            ?? cal.startOfDay(for: cal.date(byAdding: .day, value: 1, to: now) ?? now)
        if let real = maybeSnapshot, cal.isDateInToday(real.snapshotDate) || rollover > now {
            let shiftedDays = Array(real.lastSevenDays.dropFirst()) + [0]
            let midnightSnapshot = WidgetSnapshot(
                deckId: real.deckId,
                deckName: real.deckName,
                newCount: real.newCount,
                learnCount: real.learnCount,
                reviewCount: real.reviewCount,
                reviewedToday: 0,
                completedToday: 0,
                streak: real.streak,
                lastSevenDays: shiftedDays,
                snapshotDate: rollover,
                nextDayStart: rollover.addingTimeInterval(86_400)
            )
            entries.append(WidgetEntry(date: rollover, snapshot: midnightSnapshot))
        }

        // Request a full reload shortly after the Anki-day rollover when we
        // have a fresh snapshot (the rollover entry already corrects the
        // counters; the reload picks up any scheduling changes). Poll every
        // 5 minutes if there is no snapshot yet or the snapshot is stale, so
        // the widget self-corrects quickly once the app writes fresh data.
        let reloadAfter: Date
        if let real = maybeSnapshot, cal.isDateInToday(real.snapshotDate) || rollover > now {
            reloadAfter = rollover.addingTimeInterval(15 * 60)
        } else {
            reloadAfter = cal.date(byAdding: .minute, value: 5, to: now) ?? now
        }

        return Timeline(entries: entries, policy: .after(reloadAfter))
    }
}

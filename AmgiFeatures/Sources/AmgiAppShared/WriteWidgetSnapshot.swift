import OSLog
import AmgiAppCore
import AnkiClients
import AnkiKit
import Dependencies
import Foundation
import WidgetKit

/// Fetches current deck data + streak, writes per-deck snapshot files to the
/// App Group container, then signals WidgetKit to reload all timelines.
/// Safe to call from any async context.
public func writeWidgetSnapshot() async {
    // Skip during XCTest runs — the lifecycle hooks that call this run inside
    // the host app's scene phase / didFinishLaunching, which fire even when
    // the app is hosting a test bundle. Calling unimplemented dependency stubs
    // there registers as a test failure even though the caller catches the
    // error. Tests that genuinely need widget-snapshot behavior can call this
    // directly inside their own withDependencies overrides.
    if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
        return
    }

    @Dependency(\.collectionStore) var collectionStore
    @Dependency(\.statsClient) var statsClient

    do {
        // Match the Library hero: top-level nodes already include their
        // descendants' due counts, so summing a flat deck list would count
        // parent/subdeck cards more than once.
        let tree = try await collectionStore.tree()
        let libraryDecks = tree.map(\.asDeckInfo)
        let individualDecks = tree.flattened()

        var keptIds: Set<Int64> = [0]
        defer {
            WidgetSnapshotStore.removeSnapshots(notIn: keptIds)
            WidgetCenter.shared.reloadAllTimelines()
        }

        // 28-day stats graph for streak + daily counts. The rollover hour
        // rides along — the widget's day boundary comes from here, never
        // from calendar midnight.
        let graphs = try await statsClient.fetchGraphs("", 28)

        let streak = StreakCalculator.streak(reviews: graphs.reviews.count)
        let lastSevenDays = StreakCalculator.lastNDaysTotals(
            reviews: graphs.reviews.count, days: 7
        )

        let reviewedToday = graphs.today.answerCount
        let now = Date()
        let rolloverHour = graphs.rolloverHour
        let dayZero = AnkiDay.start(of: now, rolloverHour: rolloverHour)

        // "Completed" = graduated past today's Anki-day scope — the exact
        // quantity the reviewer's daily progress bar counts. Answer counts
        // would diverge (Again / mid-step learning re-answers inflate them).
        let allDecksCompleted = try await statsClient.graduatedToday(search: "")

        // Learning remaining must include intraday cards due later today —
        // tree counts drop them beyond the learn-ahead window, which would
        // make the widget's denominator (and bar) drift from the reviewer's.
        let allDecksLearning = (try? await statsClient.learningDueToday(search: ""))
            ?? libraryDecks.reduce(0) { $0 + $1.counts.learnCount }

        let aggregateBase = WidgetSnapshot.DayCounts(
            newCount: libraryDecks.reduce(0) { $0 + $1.counts.newCount },
            learnCount: allDecksLearning,
            reviewCount: libraryDecks.reduce(0) { $0 + $1.counts.reviewCount }
        )
        let allDecksSnapshot = WidgetSnapshot(
            deckId: 0,
            deckName: "All Decks",
            newCount: aggregateBase.newCount,
            learnCount: aggregateBase.learnCount,
            reviewCount: aggregateBase.reviewCount,
            reviewedToday: reviewedToday,
            completedToday: allDecksCompleted,
            streak: streak,
            lastSevenDays: lastSevenDays,
            snapshotDate: now,
            forecast: WidgetSnapshot.Forecast(
                rolloverHour: rolloverHour,
                dayZero: dayZero,
                days: forecastDays(base: aggregateBase, futureDue: graphs.futureDue.futureDue),
                futureDue: graphs.futureDue.futureDue
            )
        )
        try WidgetSnapshotStore.write(allDecksSnapshot)

        // Graduated counts are scoped searches, so compute them only where
        // a widget can actually be watching: decks with due cards now, or
        // decks that already have a snapshot file. Bounds the N+1 searches
        // to real consumers.
        for deck in individualDecks {
            let hasWidget = WidgetSnapshotStore.read(deckId: deck.id.rawValue) != nil
            guard deck.counts.total > 0 || hasWidget else { continue }
            keptIds.insert(deck.id.rawValue)
            let completed = try await statsClient.graduatedToday(
                search: DeckSearch.term(deck.name)
            )
            let learning = (try? await statsClient.learningDueToday(
                search: DeckSearch.term(deck.name)
            )) ?? deck.counts.learnCount
            let base = WidgetSnapshot.DayCounts(
                newCount: deck.counts.newCount,
                learnCount: learning,
                reviewCount: deck.counts.reviewCount
            )
            let storedForecast = WidgetSnapshotStore.read(deckId: deck.id.rawValue)?.forecast
            let forecastIsCurrent = storedForecast.map {
                $0.rolloverHour == rolloverHour && $0.dayZero == dayZero
            } ?? false
            let deckFutureDue: [Int: Int]?
            if forecastIsCurrent, let reusable = storedForecast?.futureDue {
                deckFutureDue = reusable
            } else {
                deckFutureDue = (try? await statsClient.fetchGraphs(DeckSearch.term(deck.name), 1))?
                    .futureDue.futureDue
            }
            let snapshot = WidgetSnapshot(
                deckId: deck.id.rawValue,
                deckName: deck.name,
                newCount: base.newCount,
                learnCount: base.learnCount,
                reviewCount: base.reviewCount,
                reviewedToday: reviewedToday,
                completedToday: completed,
                streak: streak,
                lastSevenDays: lastSevenDays,
                snapshotDate: now,
                forecast: deckFutureDue.map { futureDue in
                    WidgetSnapshot.Forecast(
                        rolloverHour: rolloverHour,
                        dayZero: dayZero,
                        days: forecastDays(base: base, futureDue: futureDue),
                        futureDue: futureDue
                    )
                }
            )
            try WidgetSnapshotStore.write(snapshot)
        }
    } catch {
        Log.widget.error("Failed: \(error)")
    }
}

/// Due counts for the write day plus the next `horizon` Anki-days, assuming
/// no reviews happen in between: unfinished learn/review cards carry over,
/// and each day adds its future-due bucket.
private func forecastDays(
    base: WidgetSnapshot.DayCounts,
    futureDue: [Int: Int],
    horizon: Int = 7
) -> [WidgetSnapshot.DayCounts] {
    var days = [base]
    var carriedReviews = base.learnCount + base.reviewCount
    for day in 1...horizon {
        carriedReviews += futureDue[day] ?? 0
        // ponytail: future newCount = today's remaining new; ignores the
        // daily new-limit reset. Upgrade path: surface the deck's new/day
        // limit through DeckInfo if the approximation ever bothers anyone.
        days.append(WidgetSnapshot.DayCounts(
            newCount: base.newCount,
            learnCount: 0,
            reviewCount: carriedReviews
        ))
    }
    return days
}

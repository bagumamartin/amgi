// AmgiApp/Sources/WriteWidgetSnapshot.swift
import Foundation
#if os(iOS) || os(macOS)
import AnkiClients
import AnkiKit
import Dependencies
import WidgetKit
#endif

/// Fetches current deck data + streak, writes per-deck snapshot files to the
/// App Group container, then signals WidgetKit to reload all timelines.
/// Safe to call from any async context.
///
/// Cross-platform (iOS + macOS): `AmgiWidget` builds for both destinations
/// (see project.yml) and both apps share the same App Group container. iOS
/// uses `group.com.bagumamartin.AmgiApp`; macOS uses the Team-ID-prefixed
/// `39557WW39R.group.com.bagumamartin.AmgiApp` (see `AppGroup.identifier` and
/// the `[sdk=macosx*]` override of `APP_GROUP_IDENTIFIER` in project.yml).
/// macOS requires the Team-ID prefix: containermanagerd rejects unprefixed
/// `group.` IDs for sandboxed processes whose provisioning profile doesn't
/// list them explicitly — the widget extension's profile only carries the
/// `39557WW39R.*` wildcard, so with the unprefixed ID its container reads were
/// denied and it fell back to the empty snapshot ("Open Amgi to refresh").
/// macOS App Groups also require the App Sandbox capability (unlike iOS,
/// where apps are always sandboxed), so the macOS app target uses
/// `AmgiApp-macOS.entitlements` with `app-sandbox` enabled; without it
/// `containerURL(forSecurityApplicationGroupIdentifier:)` returns nil and the
/// widget never sees a snapshot.
func writeWidgetSnapshot() async {
    #if os(iOS) || os(macOS)
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

        // 2. Fetch 28-day stats graph for streak + daily counts
        let graphs = try await statsClient.fetchGraphs("", 28)

        // 3+4. Compute streak and last-7-days totals via shared helper.
        let streak = StreakCalculator.streak(reviews: graphs.reviews.count)
        let lastSevenDays = StreakCalculator.lastNDaysTotals(
            reviews: graphs.reviews.count, days: 7
        )

        let reviewedToday = graphs.today.answerCount
        let now = Date()
        let calendar = Calendar.current

        func dueBaseline(deckId: Int64, totalDue: Int) -> Int {
            let currentSum = max(reviewedToday + totalDue, 1)
            guard let existing = WidgetSnapshotStore.read(deckId: deckId),
                  calendar.isDate(existing.snapshotDate, inSameDayAs: now) else {
                return currentSum
            }
            return max(existing.dueBaselineToday, 1)
        }

        let allDecksTotalDue = libraryDecks.reduce(0) { $0 + $1.counts.total }

        // 5. Write all-decks aggregate snapshot (deckId = 0)
        let allDecksSnapshot = WidgetSnapshot(
            deckId: 0,
            deckName: "All Decks",
            newCount: libraryDecks.reduce(0) { $0 + $1.counts.newCount },
            learnCount: libraryDecks.reduce(0) { $0 + $1.counts.learnCount },
            reviewCount: libraryDecks.reduce(0) { $0 + $1.counts.reviewCount },
            reviewedToday: reviewedToday,
            dueBaselineToday: dueBaseline(deckId: 0, totalDue: allDecksTotalDue),
            streak: streak,
            lastSevenDays: lastSevenDays,
            snapshotDate: now
        )
        try WidgetSnapshotStore.write(allDecksSnapshot)

        // 6. Write per-deck snapshots
        for deck in individualDecks {
            let snapshot = WidgetSnapshot(
                deckId: deck.id.rawValue,
                deckName: deck.name,
                newCount: deck.counts.newCount,
                learnCount: deck.counts.learnCount,
                reviewCount: deck.counts.reviewCount,
                reviewedToday: reviewedToday,
                dueBaselineToday: dueBaseline(deckId: deck.id.rawValue, totalDue: deck.counts.total),
                streak: streak,
                lastSevenDays: lastSevenDays,
                snapshotDate: now
            )
            try WidgetSnapshotStore.write(snapshot)
        }

        // 7. Tell WidgetKit to reload all widget timelines
        WidgetCenter.shared.reloadAllTimelines()
    } catch {
        print("[writeWidgetSnapshot] Failed: \(error)")
    }
    #endif
}

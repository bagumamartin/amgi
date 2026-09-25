import Foundation
import Testing
import AnkiKit
@testable import StatsFeature

@Suite("Stats dashboard responsive layout")
struct StatsDashboardLayoutTests {
    @Test("compact keeps the established single-column stack")
    func compactLayout() {
        #expect(StatsDashboardLayout.resolve(isRegularWidth: false) == .compact)
    }

    @Test("regular width uses the two-column dashboard")
    func regularLayout() {
        #expect(StatsDashboardLayout.resolve(isRegularWidth: true) == .regular)
    }

    @Test("actual narrow regular width falls back to one chart column")
    func narrowRegularUsesSingleColumn() {
        #expect(
            StatsDashboardLayout.resolve(
                availableWidth: StatsDashboardLayout.minimumRegularWidth - 1
            ) == .compact
        )
        #expect(
            StatsDashboardLayout.resolve(
                availableWidth: StatsDashboardLayout.minimumRegularWidth
            ) == .regular
        )
    }

    @Test("accessibility Dynamic Type keeps the chart stack single-column")
    func accessibilityUsesSingleColumn() {
        #expect(
            StatsDashboardLayout.resolve(
                availableWidth: 1_200,
                isAccessibilitySize: true
            ) == .compact
        )
    }
}

@Suite("Stats deck scope catalog")
struct StatsDeckScopeCatalogTests {
    private func deck(_ id: Int64, _ name: String, due: Int = 0) -> DeckInfo {
        DeckInfo(
            id: DeckID(id),
            name: name,
            counts: DeckCounts(newCount: due, learnCount: 0, reviewCount: 0)
        )
    }

    @Test("all decks, including subdecks, are available in tree order")
    func includesHierarchy() {
        let items = StatsDeckScopeCatalog.items(from: [
            deck(3, "Languages::Korean::Grammar"),
            deck(1, "Languages"),
            deck(4, "Math"),
            deck(2, "Languages::Korean"),
        ])

        #expect(items.map(\.deck.name) == [
            "Languages",
            "Languages::Korean",
            "Languages::Korean::Grammar",
            "Math",
        ])
        #expect(items.map(\.depth) == [0, 1, 2, 0])
    }

    @Test("search matches the full deck path, not only the leaf")
    func searchesFullPath() {
        let items = StatsDeckScopeCatalog.items(from: [
            deck(1, "Languages::Korean"),
            deck(2, "Languages::Japanese"),
            deck(3, "Mathematics"),
        ])

        #expect(
            StatsDeckScopeCatalog.filter(items, query: "korean").map(\.deck.name)
                == ["Languages::Korean"]
        )
        #expect(StatsDeckScopeCatalog.filter(items, query: "  ").count == 3)
    }
}

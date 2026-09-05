import Testing
import PhosphorSwift
import AmgiEmbeddings
@testable import AmgiIcons

/// Engine tests need the e5 weights: either the CDN download (run the app
/// once) or a locally compiled bundle copy. CI without the model records a
/// known issue instead of failing; catalog/fallback tests below stay green
/// regardless since they never touch CoreML.
@Suite("IconSuggester", .serialized)
struct IconSuggesterTests {
    private let suggester = IconSuggester.shared

    @Test("Ph index round-trips every catalog name")
    func phIndex() {
        #expect(Ph.allCases.count == 1512)
        for icon in Ph.allCases {
            #expect(Ph.amgi(named: icon.amgiCaseName) == icon)
        }
        // Swift keyword case survives the round-trip.
        #expect(Ph.amgi(named: "repeat") == Ph.`repeat`)
        // Kebab raw values also resolve.
        #expect(Ph.amgi(named: "air-traffic-control") == .airTrafficControl)
    }

    @Test(
        "Semantic best match hits the expected icons",
        .enabled(if: ModelAssetManager.isModelInstalled, "e5 model not installed — run the app once to download it")
    )
    func bestMatch() async {
        await #expect(suggester.bestMatch(for: "Python Programming") == "filePy")
        await #expect(suggester.bestMatch(for: "Organic Chemistry") == "testTube")
        await #expect(suggester.bestMatch(for: "World History") == "globe")
        await #expect(suggester.bestMatch(for: "Piano Chords") == "pianoKeys")
        await #expect(suggester.bestMatch(for: "Bird watching") == "bird")
    }

    @Test("Empty and whitespace names fall back to the default icon")
    func emptyInput() async {
        await #expect(suggester.bestMatch(for: "") == IconSuggester.defaultIconName)
        await #expect(suggester.bestMatch(for: "   ") == IconSuggester.defaultIconName)
    }

    @Test(
        "Search ranks chemistry icons first",
        .enabled(if: ModelAssetManager.isModelInstalled, "e5 model not installed — run the app once to download it")
    )
    func searchRanking() async {
        let results = await suggester.search("chemistry experiment", topK: 10)
        #expect(!results.isEmpty)
        let top3 = Set(results.prefix(3))
        #expect(top3.isSubset(of: ["flask", "testTube", "testTubeVertical", "microscope"]))
    }

    @Test("Empty search returns the full catalog")
    func browseMode() async {
        let results = await suggester.search("", topK: 20)
        #expect(results.count == Ph.allCases.count)
    }

    @Test(
        "Repeated queries are served from the vector cache",
        .enabled(if: ModelAssetManager.isModelInstalled, "e5 model not installed — run the app once to download it")
    )
    func cacheStability() async {
        let first = await suggester.bestMatch(for: "Linear Algebra")
        let second = await suggester.bestMatch(for: "Linear Algebra")
        #expect(first == second)
    }
}

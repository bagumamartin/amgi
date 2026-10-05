import Testing
import Foundation
import AnkiKit
@testable import AmgiAppCore
@testable import DecksFeature

/// Step-field parsing. The regression these guard is silent data loss: the
/// old parser `compactMap`ped tokens it could not read, so a schedule typed
/// in a comma-decimal locale came out shorter and was written to the
/// collection as if the user had asked for it.
///
/// `@MainActor` because `DeckConfigModel` is. These tests touch no engine and
/// no I/O — parsing is pure — but they go through the model because that is
/// where the behavior lives.
@Suite(.serialized) @MainActor struct DeckConfigStepParsingTests {
    private func model() -> DeckConfigModel {
        DeckConfigModel(deckId: DeckID(1), deckName: "Test")
    }

    @Test func readsTheCanonicalShorthand() {
        let model = model()
        #expect(model.parseSteps("1m 10m") == [1, 10])
        #expect(model.parseSteps("1m 10m 1h 1d") == [1, 10, 60, 1440])
        #expect(model.parseSteps("10M 1H") == [10, 60], "suffixes are case-insensitive")
        #expect(model.parseSteps("15") == [15], "a bare number is minutes")
    }

    @Test func readsCommaSeparatedSteps() {
        let model = model()
        #expect(model.parseSteps("1m, 10m, 1h") == [1, 10, 60])
    }

    @Test func keepsEveryTokenInACommaDecimalLocale() {
        // The bug: "1,5h" split on the comma into "1" and "5h", giving
        // [1, 300] — the user asked for one 90-minute step and got two
        // intervals, one an hour long.
        defer { AppLocale.setOverride(nil) }
        AppLocale.setOverride("de-DE")
        let model = model()
        #expect(model.parseSteps("1,5h") == [90])
        #expect(model.parseSteps("1,5h 2h") == [90, 120])
        #expect(model.stepsParseError == nil)
    }

    @Test func stillReadsAPeriodWhenTheLocaleUsesAComma() {
        // A field typed before the device changed language must not silently
        // reinterpret "1.5h" as 15 hours.
        defer { AppLocale.setOverride(nil) }
        AppLocale.setOverride("de-DE")
        let model = model()
        #expect(model.parseSteps("1.5h") == [90])
    }

    @Test func reportsTokensItCannotRead() {
        let model = model()
        #expect(model.parseSteps("10m tomorrow") == [10])
        #expect(model.stepsParseError == "tomorrow")
    }

    @Test func aGoodScheduleReportsNoError() {
        let model = model()
        _ = model.parseSteps("1m 10m")
        #expect(model.stepsParseError == nil)
        _ = model.parseSteps("")
        #expect(model.stepsParseError == nil, "an empty field is empty, not invalid")
    }

    @Test func formattingRoundTripsThroughParsing() {
        let model = model()
        let text = model.formatSteps([1, 10, 60, 1440])
        #expect(model.parseSteps(text) == [1, 10, 60, 1440])
        #expect(model.formatSteps([]) == "")
    }

    @Test func weightsAreReadInEitherNotation() {
        defer { AppLocale.setOverride(nil) }
        AppLocale.setOverride("de-DE")
        let model = model()
        #expect(model.parseFloats("0.4, 1.2") == [0.4, 1.2])
        #expect(model.parseFloats("0,4 1,2") == [0.4, 1.2])
    }

    @Test func weightsAreWrittenInAFixedNotation() {
        // Weights round-trip through this field into the engine, so their
        // written form must not shift with the device's locale.
        defer { AppLocale.setOverride(nil) }
        AppLocale.setOverride("de-DE")
        let model = model()
        #expect(model.formatWeights([0.4, 1.2]) == "0.4000, 1.2000")
        #expect(model.parseFloats(model.formatWeights([0.4, 1.2])) == [0.4, 1.2])
    }
}

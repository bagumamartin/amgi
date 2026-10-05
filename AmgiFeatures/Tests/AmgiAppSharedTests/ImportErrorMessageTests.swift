import Foundation
import Testing
@testable import AmgiAppShared

/// Import failure classification.
///
/// The previous implementation matched English words in the engine's message
/// ("zip", "archive", "mnemosyne") to decide which explanation to show. Those
/// sentinels stop matching as soon as the engine is constructed with the
/// user's own languages — the same German user whose Anki reports
/// "unleserliches Archiv" would fall through to the raw engine string. The
/// decision is now made from what the app already knows: the file's format
/// and where the import died.
@Suite @MainActor struct ImportErrorMessageTests {
    private struct EngineComplaint: LocalizedError {
        var errorDescription: String? { "Die Datei ist kein gültiges Archiv." }
    }

    @Test func aStagingFailureIsExplainedInTermsOfTheFile() {
        let message = ImportReviewModel.message(
            for: EngineComplaint(),
            format: .deckPackage,
            at: .staging
        )
        #expect(message.contains("Anki package"))
    }

    @Test func classificationDoesNotDependOnTheEnginesLanguage() {
        // The same failure, engine text in German and in English, has to
        // produce the same explanation.
        struct EnglishComplaint: LocalizedError {
            var errorDescription: String? { "not a valid zip archive" }
        }
        #expect(
            ImportReviewModel.message(for: EngineComplaint(), format: .text, at: .staging)
                == ImportReviewModel.message(for: EnglishComplaint(), format: .text, at: .staging)
        )
        #expect(
            ImportReviewModel.message(for: EngineComplaint(), format: .mnemosyne, at: .staging)
                == ImportReviewModel.message(for: EnglishComplaint(), format: .mnemosyne, at: .staging)
        )
    }

    @Test func anEngineFailurePassesTheEngineMessageThrough() {
        // Past staging the engine owns the file, and its message is already
        // localized — replacing it with a generic string would lose detail.
        let message = ImportReviewModel.message(
            for: EngineComplaint(),
            format: .deckPackage,
            at: .engine
        )
        #expect(message == "Die Datei ist kein gültiges Archiv.")
    }

    @Test func aFailureWithNoKnownFormatIsNotGuessedAt() {
        let message = ImportReviewModel.message(for: EngineComplaint(), format: nil, at: .staging)
        #expect(message == "Die Datei ist kein gültiges Archiv.")
    }
}

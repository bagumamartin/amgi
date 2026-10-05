import Testing
import Foundation
@testable import AnkiKit

@Suite("Language preferences")
struct LanguagePreferencesTests {

    @Test func underscoreTagsBecomeWhatTheEngineParserAccepts() {
        // `unic_langid::LanguageIdentifier` — what `I18n::new` parses each
        // requested tag with — wants hyphens. Users and stored settings
        // write underscores.
        #expect(LanguagePreferences.normalizedTags(["ko_KR"]) == ["ko-KR"])
        #expect(LanguagePreferences.normalizedTags(["pt_BR", "pt-PT"]) == ["pt-BR", "pt-PT"])
    }

    @Test func blanksAreDroppedAndOrderIsPreserved() {
        // Order *is* the preference order; it must survive normalization.
        #expect(LanguagePreferences.normalizedTags(["fr-FR", "", "  ", "de-DE"])
            == ["fr-FR", "de-DE"])
    }

    @Test func duplicatesKeepFirstPosition() {
        #expect(LanguagePreferences.normalizedTags(["fr-FR", "fr_FR", "de-DE"])
            == ["fr-FR", "de-DE"])
    }

    @Test func nothingUsableFallsBackToEnglish() {
        #expect(LanguagePreferences.normalizedTags([]) == ["en"])
        #expect(LanguagePreferences.normalizedTags(["", "   "]) == ["en"])
    }

    @Test func englishIsNeverAppended() {
        // `I18n::new` stops walking the list the moment it sees an `en` tag,
        // because the bundled en-US template is 100% covered and is appended
        // as the final fallback anyway. Appending it here would pin the whole
        // engine to English for every non-English user.
        #expect(!LanguagePreferences.normalizedTags(["fr-FR"]).contains("en"))
        #expect(LanguagePreferences.systemTags == LanguagePreferences.normalizedTags(
            Locale.preferredLanguages
        ))
    }
}

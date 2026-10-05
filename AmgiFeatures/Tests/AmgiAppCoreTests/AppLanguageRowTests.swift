import Testing
import Foundation
@testable import AmgiAppCore

/// The language picker's contents. It offers only languages the bundle
/// actually carries, because a row for a language with no catalog entries is
/// an app that looks English with translated chrome — and it hides the gap
/// from whoever is doing the translation.
@Suite(.serialized) struct AppLanguageRowTests {

    @Test func theShippedLanguagesAreWhatTheBundleCarries() {
        let shipped = AppLocale.resourceBundle.localizations
            .compactMap(Locale.Language.init(identifier:))
            .filter { $0.languageCode != nil }
        #expect(!shipped.isEmpty, "the catalog has to be in the bundle at all")
        // English is the source language, so it is always present.
        #expect(shipped.contains { $0.languageCode?.identifier == "en" })
    }

    @Test func everyCommittedLanguageReachesTheBuiltBundle() {
        // This is the test that would have caught shipping a language as
        // catalog JSON with nothing to compile it into: the picker reads
        // `Bundle.localizations`, so a language the build dropped is
        // invisible to the user and invisible to the catalog tests.
        let shipped = Set(
            AppLocale.resourceBundle.localizations
                .compactMap(Locale.Language.init(identifier:))
                .compactMap(\.languageCode?.identifier)
        )
        for language in LocalizationTests.shippedLanguages {
            #expect(
                shipped.contains(language),
                "\(language) is in the catalog but not in the built bundle"
            )
        }
    }

    @Test func noUnparseableEntryIsOffered() {
        // "Base" is a real entry in `Bundle.localizations` for some bundles
        // and not for others. Either way it must not reach the picker:
        // `Locale.Language(identifier:)` has nothing to call "Base".
        let offered = AppLocale.availableLanguageTags
        #expect(!offered.contains("Base"))
        for tag in offered {
            let language = Locale.Language(identifier: tag)
            #expect(language.languageCode != nil, "\(language.minimalIdentifier) is not a language")
        }
    }

    @Test func metadataAndResourceLanguagesOnlyAppearOnce() {
        #expect(AppLocale.languageOptions(from: ["en", "es", "fr", "hu", "vi", "en", "es", "fr", "hu", "vi", "Base"])
            == ["en", "es", "fr", "hu", "vi"])
    }

    @Test func equivalentTagsUseOnePickerIdentity() {
        #expect(AppLocale.languageOptions(from: ["hu", "hu-HU", "hu_Latn_HU", "en", "en-US"])
            == ["en", "hu"])
    }

    @Test func builtPickerTagsAreUnique() {
        let offered = AppLocale.availableLanguageTags
        #expect(offered.count == Set(offered).count)
        #expect(offered == ["en", "es", "fr", "hu", "vi"])
    }

    @Test func languageNamesUseTheirOwnLanguageWithoutScriptAndRegion() {
        #expect(AppLocale.languageName(for: "en") == "English")
        #expect(AppLocale.languageName(for: "hu").lowercased() == "magyar")
        #expect(AppLocale.languageName(for: "vi").lowercased() == "tiếng việt")
        #expect(AppLocale.languageName(for: "fr").lowercased() == "français")
        #expect(AppLocale.languageName(for: "es").lowercased() == "español")
    }
}

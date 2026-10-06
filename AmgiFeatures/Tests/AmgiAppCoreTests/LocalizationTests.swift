import Testing
import Foundation
import Synchronization
import AnkiKit
@testable import AmgiAppCore

/// The locale owner, the catalog lookup, and the catalog itself.
///
/// The catalog is English-only today, so these tests mostly pin the
/// *mechanism*: that the override round-trips, that the engine gets the
/// user's languages, that a lookup resolves against a bundle that really has
/// the catalog, and that the catalog stays valid JSON carrying the sentinel
/// key. The placeholder checks matter the day a second language lands.
/// Serialized: every test here reads or writes the same App Group key, and
/// swift-testing runs the cases in a suite in parallel by default.
@Suite(.serialized) struct LocalizationTests {

    // MARK: - Override

    @Test func overrideRoundTripsAndClears() {
        defer { AppLocale.setOverride(nil) }
        AppLocale.setOverride(nil)
        #expect(AppLocale.overrideTag == nil)

        AppLocale.setOverride("ko-KR")
        #expect(AppLocale.overrideTag == "ko-KR")

        // Whitespace is a cleared override, not a language named " ".
        AppLocale.setOverride("  ")
        #expect(AppLocale.overrideTag == nil)
    }

    @Test func systemIsFollowedWhenNothingIsOverridden() {
        defer { AppLocale.setOverride(nil) }
        AppLocale.setOverride(nil)
        #expect(AppLocale.languageTags == LanguagePreferences.systemTags)
        #expect(AppLocale.current == Locale.current)
    }

    @Test func overrideReplacesTheSystemOrderEntirely() {
        defer { AppLocale.setOverride(nil) }
        AppLocale.setOverride("ko_KR")
        // Normalized for the engine's parser...
        #expect(AppLocale.languageTags == ["ko-KR"])
        // ...and never padded with English, which would short-circuit I18n.
        #expect(!AppLocale.languageTags.contains("en"))
        #expect(AppLocale.current.language.languageCode?.identifier == "ko")
    }

    // MARK: - Catalog lookup

    @Test func resourceBundleActuallyCarriesTheCatalog() {
        // `resourceBundle` falls back to `Bundle.main` when nothing answers
        // the probe, and a missing catalog is otherwise invisible: every
        // lookup would silently return its own key.
        #expect(AppLocale.ownsCatalog(AppLocale.resourceBundle))
        #expect(
            AppLocale.resourceBundle.localizedString(
                forKey: AppLocale.probeKey,
                value: AppLocale.probeKey,
                table: AppLocale.tableName
            ) != AppLocale.probeKey
        )
    }

    @Test func anEmptyBundleDoesNotClaimTheCatalog() {
        #expect(!AppLocale.ownsCatalog(Bundle(for: CatalogProbeToken.self)))
    }

    // MARK: - L10n

    @Test func englishLiteralsResolveToThemselves() {
        // The source language *is* the English string, so an untranslated
        // catalog must not change a single word of the English UI.
        #expect(L10n.text("Undo") == "Undo")
        #expect(L10n.text("Resume session") == "Resume session")
    }

    @Test func dynamicKeyFallsBackToTheKeyItself() {
        // Never empty: a missing translation has to be visible.
        #expect(L10n.key("ijuka.not.in.the.catalog") == "ijuka.not.in.the.catalog")
    }

    @Test func formatSubstitutesThroughTheLocalizedTemplate() {
        #expect(L10n.format("Undo %@", ["Add Cards"]) == "Undo Add Cards")
    }

    /// Guards the claim in `L10n.resolve`'s doc comment: the
    /// `LocalizationValue` overload of `String(localized:locale:)` ignores the
    /// locale when choosing a `.lproj`, and `LocalizedStringResource` does
    /// not. If Apple ever converges the two, this fails and the comment can go.
    @Test func theLocalizationValueOverloadReallyDoesIgnoreTheLocale() {
        defer { AppLocale.setOverride(nil) }
        AppLocale.setOverride("hu")
        let resource = LocalizedStringResource(
            "Undo",
            table: AppLocale.tableName,
            locale: AppLocale.current,
            bundle: AppLocale.resourceBundle
        )
        #expect(String(localized: resource) == "Visszavonás")
        // The trap: same key, same locale, same bundle — but the overload that
        // takes a `LocalizationValue` resolves through the bundle instead.
        #expect(
            String(
                localized: String.LocalizationValue("Undo"),
                table: AppLocale.tableName,
                bundle: AppLocale.resourceBundle,
                locale: AppLocale.current
            ) == "Undo",
            "expected the LocalizationValue overload to still ignore the locale"
        )
    }

    @Test func localeFollowsTheOverride() {
        defer { AppLocale.setOverride(nil) }
        AppLocale.setOverride("fr-CA")
        #expect(L10n.locale.language.languageCode?.identifier == "fr")
        #expect(L10n.locale == AppLocale.current)
    }

    // MARK: - The override actually changes the output
    //
    // This is the test that catches the trap the lookup API sets. Both
    // `String(localized:locale:)` taking a `LocalizationValue` and
    // `Bundle.localizedString(forKey:value:table:)` resolve through the
    // *bundle's* preferred localizations and ignore an explicit locale, so
    // the override silently reads as English — the app looks like it has a
    // language picker that does nothing. Asserted against the real catalog,
    // not a stub, so a wrong API choice cannot pass.

    @Test(arguments: [("hu", "Visszavonás"), ("vi", "Hoàn tác")])
    func anOverrideChangesWhatTheUserReads(language: String, expected: String) {
        defer { AppLocale.setOverride(nil) }
        AppLocale.setOverride(language)
        #expect(L10n.text("Undo") == expected)
    }

    @Test(arguments: [("hu", "Visszavonás: %@"), ("vi", "Hoàn tác %@")])
    func anOverrideChangesTheFormatTemplateToo(language: String, expected: String) {
        defer { AppLocale.setOverride(nil) }
        AppLocale.setOverride(language)
        #expect(L10n.format("Undo %@", ["Kártyák hozzáadása"]) == expected.replacingOccurrences(of: "%@", with: "Kártyák hozzáadása"))
    }

    @Test func anOverrideReachesRuntimeKeysToo() {
        defer { AppLocale.setOverride(nil) }
        AppLocale.setOverride("vi")
        #expect(L10n.key("Undo") == "Hoàn tác")
    }

    // MARK: - The change has to reach the screen
    //
    // Every test above can pass while the app's language picker does nothing.
    // That is not a hypothetical: the original implementation stored the
    // override in `UserDefaults` and the root view read it through a static,
    // which SwiftUI does not observe. `UserDefaults` is not an observation
    // dependency, so the body holding `.environment(\.locale,)` never re-ran.
    // The key was written, `L10n` (which reads it live) returned Vietnamese,
    // and every `Text("…")` stayed English.
    //
    // So the thing under test here is the *observation graph*, not the value.

    /// Isolated in a nested suite: the store is `@MainActor` (it is UI state)
    /// and these tests mutate global App Group state, so they must not run
    /// concurrently with each other.
    @Suite(.serialized) @MainActor struct ObservationTests {

        @Test func theStoreNotifiesWhenTheLanguageChanges() {
            let model = AppLocaleModel.shared
            defer { model.setOverride(nil) }

            // The defect this guards: the root view reads the locale to apply
            // `.environment(\.locale,)`, so a change has to invalidate that
            // body. With the value behind a plain `UserDefaults` read it does
            // not — the picker writes the key, `L10n` starts returning the new
            // language, and every `Text("…")` stays in the old one.
            //
            // `withObservationTracking` is the same mechanism SwiftUI's
            // re-render depends on, so a non-observable store cannot pass.
            let changed = Counter()
            withObservationTracking {
                _ = model.locale
            } onChange: {
                changed.increment()
            }
            model.setOverride("vi")
            // Observation callbacks are delivered on the next runloop turn.
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            #expect(changed.value > 0, "the language store is not observable")
        }

        @Test func everyShippedChangeNotifies() {
            let model = AppLocaleModel.shared
            defer { model.setOverride(nil) }
            for tag in ["hu", "vi", nil] {
                let changed = Counter()
                withObservationTracking {
                    _ = model.overrideTag
                } onChange: {
                    changed.increment()
                }
                model.setOverride(tag)
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                #expect(changed.value > 0, "setting \(tag ?? "nil") did not notify")
            }
        }

        @Test func redundantWritesDoNotNotify() {
            // Not a correctness requirement — SwiftUI diffs anyway — but a
            // picker that re-renders the whole app when the user re-selects
            // the same row is a visible stutter.
            let model = AppLocaleModel.shared
            defer { model.setOverride(nil) }
            model.setOverride("vi")

            let changed = Counter()
            withObservationTracking {
                _ = model.overrideTag
            } onChange: {
                changed.increment()
            }
            model.setOverride("vi")
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            #expect(changed.value == 0, "re-selecting the same language notified")
        }

        @Test func theStoreSurvivesRepeatedChanges() {
            let model = AppLocaleModel.shared
            defer { model.setOverride(nil) }
            for tag in ["hu", "fr", "es", "vi", nil] {
                model.setOverride(tag)
                #expect(model.overrideTag == tag)
            }
        }

        @Test func aChangeThroughTheStoreReachesUserDefaults() {
            // The widget and the watch read `AppLocale.overrideTag` straight
            // out of UserDefaults, with no observable object in the loop. If a
            // write stopped short of storage, the app would change language
            // and the widget would not.
            let model = AppLocaleModel.shared
            defer { AppLocale.setOverride(nil) }
            model.setOverride("vi")
            #expect(AppLocale.overrideTag == "vi")
            #expect(AppLocale.current.language.languageCode?.identifier == "vi")
            #expect(model.locale.language.languageCode?.identifier == "vi")

            model.setOverride(nil)
            #expect(AppLocale.overrideTag == nil)
            #expect(model.overrideTag == nil)
        }

        @Test func theStorePicksUpAValueWrittenWhileTheAppWasClosed() {
            // The widget runs in its own process and can write the key while
            // the app is not running. The store reads storage at init for
            // exactly that case.
            AppLocale.setOverride("hu")
            // A fresh instance is what the next launch builds.
            let fresh = MainActor.assumeIsolated { AppLocaleModel(readingStoredOverride: true) }
            #expect(fresh.overrideTag == "hu")
            AppLocale.setOverride(nil)
        }
    }

    @Test func aLanguageWithNoCatalogEntryFallsBackToEnglish() {
        // German is not shipped. The right behavior is the English string,
        // not a blank — and the picker never offers it, so this is only
        // reachable by writing the key by hand.
        defer { AppLocale.setOverride(nil) }
        AppLocale.setOverride("de-DE")
        #expect(L10n.text("Undo") == "Undo")
    }

    // MARK: - The catalog file itself

    @Test func catalogIsValidAndCarriesTheSentinel() throws {
        let catalog = try Self.catalog()
        #expect(catalog["sourceLanguage"] as? String == "en")
        let strings = try #require(catalog["strings"] as? [String: Any])
        #expect(strings[AppLocale.probeKey] != nil, "the probe key must exist in every language")
    }

    @Test func everyKeyIsTranslatedIntoEveryShippedLanguage() throws {
        // A key that exists in the catalog but is missing from a language
        // silently falls back to English for that one string — which is how a
        // screen ends up half Hungarian with a stray English label nobody can
        // explain. Every key must cover every language we ship.
        let catalog = try Self.catalog()
        let strings = try #require(catalog["strings"] as? [String: Any])
        for (key, rawEntry) in strings {
            let entry = try #require(rawEntry as? [String: Any])
            let languages = (entry["localizations"] as? [String: Any] ?? [:]).keys
            for language in Self.shippedLanguages where !languages.contains(language) {
                Issue.record("\(key) has no \(language) translation")
            }
        }
    }

    @Test func everyTranslationDiffersFromItsEnglishSource() throws {
        // A value identical to the key is either an untranslated placeholder or
        // a genuine coincidence. Both are worth seeing in review; the sentinel
        // is exempt because its whole job is to differ.
        //
        // Verified coincidences (correct in the target language despite
        // identical spelling) are exempt below — do not add to this set
        // without checking a dictionary first.
        let verifiedCoincidences: Set<String> = [
            "Total/es", "Total/fr", // total is "total" in Spanish and French
            "%lld min/es", "%lld min/fr", // the "min" abbreviation is shared
            "%.1f min/es", "%.1f min/fr", // same abbreviation with decimals
            "minute/fr", "minutes/fr", // French spelling matches English
            "Orange/fr", "Turquoise/fr", // French color names match
            "note/fr", "1 note/fr", "%lld notes/fr", // French "note"/"notes" match
            "Info/es", // Spanish short form is also "info"
            "Manual/es", // Spanish "manual" matches
            "type %lld/fr", // French "type" matches
        ]
        let catalog = try Self.catalog()
        let strings = try #require(catalog["strings"] as? [String: Any])
        for (key, rawEntry) in strings where key != AppLocale.probeKey {
            let entry = try #require(rawEntry as? [String: Any])
            let languages = entry["localizations"] as? [String: Any] ?? [:]
            for (language, rawUnit) in languages {
                let value = try Self.value(of: rawUnit)
                guard !verifiedCoincidences.contains("\(key)/\(language)") else { continue }
                #expect(
                    value != key,
                    "\(key)/\(language) is identical to the English source — untranslated?"
                )
            }
        }
    }

    @Test func shippedLanguagesAreTheOnesWeIntend() throws {
        // The catalog's languages, `project.yml`'s `knownRegions`, and the
        // `.lproj` folders on disk are three separate places that have to
        // agree. A language in one and not the others builds fine and is
        // missing at runtime, so the pairing is asserted here.
        let catalog = try Self.catalog()
        let strings = try #require(catalog["strings"] as? [String: Any])
        var inCatalog: Set<String> = []
        for rawEntry in strings.values {
            let languages = (rawEntry as? [String: Any])?["localizations"] as? [String: Any] ?? [:]
            inCatalog.formUnion(languages.keys)
        }
        // The source language has no entry to be missing from — its values are
        // the keys. (The probe is the one exception, because its English value
        // must differ from its key.)
        inCatalog.remove("en")
        #expect(inCatalog.subtracting(Self.shippedLanguages).isEmpty)
        for language in Self.shippedLanguages {
            #expect(
                inCatalog.contains(language),
                "\(language) is declared as shipped but nothing in the catalog carries it"
            )
        }
    }

    @Test func everyTranslationKeepsTheSourcePlaceholders() throws {
        let catalog = try Self.catalog()
        let strings = try #require(catalog["strings"] as? [String: Any])
        for (key, rawEntry) in strings {
            let entry = try #require(rawEntry as? [String: Any])
            let source = Self.placeholders(in: key)
            let languages = entry["localizations"] as? [String: Any] ?? [:]
            for (language, rawUnit) in languages {
                let unit = try #require(rawUnit as? [String: Any])
                let stringUnit = try #require(unit["stringUnit"] as? [String: Any])
                let value = try #require(stringUnit["value"] as? String)
                #expect(
                    Self.placeholders(in: value) == source,
                    Comment(
                        rawValue: "\(key)/\(language): placeholders "
                            + "\(Self.placeholders(in: value)) differ from the source \(source)"
                    )
                )
            }
        }
    }

    // MARK: - Helpers

    /// The languages this app commits to shipping, minus the source language
    /// (English values *are* the keys, so there is no `en` entry to check).
    /// Kept here as the list of record: `project.yml`'s `knownRegions` and the
    /// `.lproj` folders must both agree with it.
    static let shippedLanguages: Set<String> = ["es", "fr", "hu", "vi"]

    private static func value(of rawUnit: Any) throws -> String {
        let unit = try #require(rawUnit as? [String: Any])
        let stringUnit = try #require(unit["stringUnit"] as? [String: Any])
        return try #require(stringUnit["value"] as? String)
    }

    /// The catalog as it sits in the repo, not as the build compiled it — the
    /// compiled form cannot be read back for placeholder parity.
    private static func catalog() throws -> [String: Any] {
        try #require(
            FileManager.default.fileExists(atPath: catalogURL.path),
            "no catalog at \(catalogURL.path)"
        )
        let data = try Data(contentsOf: catalogURL)
        let object = try JSONSerialization.jsonObject(with: data)
        return try #require(object as? [String: Any])
    }

    private static var catalogURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // AmgiAppCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // AmgiFeatures
            .appendingPathComponent("Sources/AmgiAppCore/Resources/Localizable.xcstrings")
    }

    /// `printf` conversions, name and type, sorted so a reordering of the
    /// arguments in a translated format does not read as a mismatch.
    ///
    /// `%%` is dropped along with the rest of the punctuation: an escaped
    /// percent is literal text, not a placeholder.
    private static let placeholderPattern = try! NSRegularExpression(
        pattern: #"%(?:[0-9]+\$)?[-+ #0']*(?:[0-9]+|\*)?(?:\.(?:[0-9]+|\*))?(?:hh|h|ll|l|L|z|j|t|q)?[@dioufFeEgGxXoscpaAn%]"#
    )

    private static func placeholders(in text: String) -> [String] {
        placeholderPattern
            .matches(in: text, range: NSRange(text.startIndex..., in: text))
            .map { match in
                (text as NSString).substring(with: match.range)
                    .replacingOccurrences(of: "%%", with: "")
                    .replacingOccurrences(of: "%", with: "")
                    .filter { !$0.isNumber }
            }
            .sorted()
    }
}

/// `Bundle(for:)` needs a class; the test suite is a struct. The test
/// bundle carries no resources, which is exactly the point — it stands in
/// for any bundle that has no catalog in it.
private final class CatalogProbeToken {}

/// Observation callbacks are `@Sendable` and fire on an arbitrary turn, so
/// they cannot mutate a local `var`. A `Mutex` keeps the count safe and lets
/// the assertion read it after the runloop turn.
private final class Counter: @unchecked Sendable {
    private let storage = Mutex(0)
    var value: Int { storage.withLock { $0 } }
    func increment() { storage.withLock { $0 += 1 } }
}

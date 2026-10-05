import XCTest
import Foundation
import SwiftUI
import Synchronization
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
@testable import AmgiAppCore
@testable import SettingsFeature

/// Does a shipped language actually reach the user's screen?
///
/// The package tests prove the catalog *resolves* (`L10n`, `AppLocale` in
/// `AmgiAppCoreTests`). They cannot prove the app bundle carries it — the
/// catalog is compiled into three separate bundles (app, widget, watch), and
/// only the app target's copy is reachable from here. Both failure modes are
/// silent: a missing `.lproj` returns the key, which for the source language
/// is the correct English string.
///
/// These assertions run against the *hosted* app, so `Bundle.main` is the
/// real `AmgiApp.app` rather than a test bundle.
@MainActor
final class LocalizationCatalogTests: XCTestCase {
    private let app = Bundle.main

    // MARK: - What we ship

    /// Keep in step with `LocalizationTests.shippedLanguages` in
    /// `AmgiFeatures/Tests/AmgiAppCoreTests`. A language added to the catalog
    /// but not here would build and pass this file, so the pair is asserted
    /// from both sides.
    private static let shippedLanguages = ["es", "fr", "hu", "vi"]

    func testTheAppBundleCarriesEveryShippedLanguage() {
        let present = Set(app.localizations)
        for language in Self.shippedLanguages {
            XCTAssertTrue(
                present.contains(language),
                "\(language) is in the catalog but not in the app bundle. "
                    + "A language listed in `knownRegions` / Info.plist that the build "
                    + "dropped fails exactly like a missing translation. Present: \(present.sorted())"
            )
        }
    }

    func testTheSourceLanguageIsAlwaysShipped() {
        XCTAssertTrue(
            app.localizations.contains("en"),
            "the catalog's source language must be present or every key falls through"
        )
    }

    func testPickerOffersEachShippedLanguageOnce() {
        // CFBundleLocalizations and the real .lproj folders both contribute
        // to Bundle.localizations in the app that produced the screenshot.
        XCTAssertEqual(AppLocale.availableLanguageTags, ["en", "es", "fr", "hu", "vi"])
    }

    func testPickerDeduplicatesTheReportedMetadataAndResources() {
        XCTAssertEqual(
            AppLocale.languageOptions(from: ["en", "es", "fr", "hu", "vi", "en", "es", "fr", "hu", "vi", "Base"]),
            ["en", "es", "fr", "hu", "vi"]
        )
    }

    func testPickerNormalizesEquivalentLanguageTags() {
        XCTAssertEqual(
            AppLocale.languageOptions(from: ["en-US", "en", "es-ES", "es", "fr-FR", "fr", "hu-HU", "hu_Latn_HU", "hu"]),
            ["en", "es", "fr", "hu"]
        )
    }

    func testPickerUsesReadableNativeLanguageNames() {
        XCTAssertEqual(AppLocale.languageName(for: "en"), "English")
        XCTAssertEqual(AppLocale.languageName(for: "hu").lowercased(), "magyar")
        XCTAssertEqual(AppLocale.languageName(for: "vi").lowercased(), "tiếng việt")
    }

    // MARK: - Does it resolve

    func testHungarianCopyResolves() {
        XCTAssertEqual(Self.localized("Undo", language: "hu"), "Visszavonás")
    }

    func testVietnameseCopyResolves() {
        XCTAssertEqual(Self.localized("Undo", language: "vi"), "Hoàn tác")
    }

    func testTheSourceLanguageIsUnchanged() {
        // The source language *is* the English string, so shipping translated languages must
        // not have altered a single word of the English UI.
        XCTAssertEqual(Self.localized("Undo", language: "en"), "Undo")
        XCTAssertEqual(Self.localized("Resume session", language: "en"), "Resume session")
    }

    func testFormatTemplatesAreTranslated() {
        // The argument is the engine's operation name and is substituted at
        // runtime, so the template has to be localized or the menu reads
        // "Undo <Hungarian noun>" in a Hungarian app.
        XCTAssertEqual(Self.localized("Undo %@", language: "hu"), "Visszavonás: %@")
        XCTAssertEqual(Self.localized("Undo %@", language: "vi"), "Hoàn tác %@")
        XCTAssertEqual(Self.localized("Undo %@", language: "en"), "Undo %@")
    }

    func testAnUnshippedLanguageFallsBackToEnglish() {
        // German is not shipped. The correct result is the English string, not
        // a blank — the picker never offers German, so this is only reachable
        // by an override written by hand.
        XCTAssertEqual(Self.localized("Undo", language: "de"), "Undo")
    }

    // MARK: - InfoPlist.strings

    /// A separate mechanism from the catalog, and the one place a user is
    /// guaranteed to read translated copy before touching a deck.
    ///
    /// Read through `NSDictionary(contentsOf:)` rather than by decoding text:
    /// the build compiles these to binary plists, not UTF-16. A plain read
    /// returns an empty string and every key looks missing, which is how this
    /// test failed its first run while the translations were in fact correct.
    func testPermissionPromptsAreTranslated() throws {
        for language in Self.shippedLanguages {
            let path = try XCTUnwrap(
                app.path(
                    forResource: "InfoPlist", ofType: "strings", inDirectory: nil, forLocalization: language
                ),
                "no InfoPlist.strings for \(language) — the permission prompts are English-only"
            )
            let table = try XCTUnwrap(
                NSDictionary(contentsOfFile: path) as? [String: String],
                "\(language)/InfoPlist.strings is not a key/value table"
            )
            for key in [
                "NSCameraUsageDescription",
                "NSMicrophoneUsageDescription",
                "NSPhotoLibraryUsageDescription",
            ] {
                let value = table[key]
                XCTAssertNotNil(value, "\(language)/InfoPlist.strings is missing \(key)")
                // A present-but-empty prompt is worse than an absent one: the
                // OS shows a blank permission alert.
                XCTAssertFalse(
                    value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true,
                    "\(language)/\(key) is empty — the OS would show a blank prompt"
                )
            }
            // Prove the value is not the English text, or the folder is
            // present but the translation was never filled in. The baseline is
            // read from `en.lproj` on disk rather than from
            // `object(forInfoDictionaryKey:)` — that accessor already returns
            // the *localized* value, so under a Hungarian device it returns
            // the Hungarian string and the comparison is against itself.
            let englishPath = try XCTUnwrap(
                app.path(
                    forResource: "InfoPlist", ofType: "strings", inDirectory: nil, forLocalization: "en"
                ),
                "no en.lproj/InfoPlist.strings to compare against"
            )
            let english = try XCTUnwrap(
                NSDictionary(contentsOfFile: englishPath) as? [String: String]
            )
            for key in [
                "NSCameraUsageDescription",
                "NSMicrophoneUsageDescription",
                "NSPhotoLibraryUsageDescription",
            ] {
                XCTAssertNotEqual(
                    table[key],
                    english[key],
                    "\(language)/\(key) is byte-identical to the English prompt"
                )
            }
        }
    }

    // MARK: - Does the environment locale reach the screen
    //
    // The defect this guards: the language picker wrote the override and
    // nothing changed. `.environment(\.locale,)` is applied in the root
    // view's `body`, and a body re-runs only when a property it read through
    // observation changes. The value used to live in `UserDefaults`, which is
    // not observable, so the picker was decorative.
    //
    // There is a UI test for the full tap-through, but that target's runner
    // crashes before its first test on this machine, so it cannot be relied on
    // as a gate. These two assertions cover the same chain in-process: the
    // store notifies, and an environment locale of the store's value changes
    // what SwiftUI actually renders.

    @MainActor
    func testTheLanguageStoreIsObservable() {
        let model = AppLocaleModel.shared
        let previous = model.overrideTag
        defer { model.setOverride(previous) }
        model.setOverride("en")

        final class Flag: @unchecked Sendable {
            private let storage = Mutex(false)
            var fired: Bool { storage.withLock { $0 } }
            func set() { storage.withLock { $0 = true } }
        }
        let flag = Flag()
        withObservationTracking {
            _ = model.locale
        } onChange: {
            flag.set()
        }
        model.setOverride("vi")
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(
            flag.fired,
            "the language store does not notify — a picker change cannot re-render the app"
        )
    }

    func testAnEnvironmentLocaleChangesWhatSwiftUIRenders() throws {
        // Rendered bitmaps, not a lookup: this is the same path `Text("…")`
        // takes, so it would catch a `.lproj` that exists but is never used.
        let english = try Self.render(locale: Locale(identifier: "en"))
        let vietnamese = try Self.render(locale: Locale(identifier: "vi"))
        XCTAssertNotEqual(
            english, vietnamese,
            "the environment locale did not change what Text(\"…\") renders — "
                + "the root view's .environment(\\.locale,) is not reaching the UI"
        )
    }

    func testSettingsStringLabelsRespondToBothOfferedLanguages() throws {
        // Test the actual shared settings components, which previously used
        // Text(String). Testing only Text("Undo") missed this failure.
        let header = SettingsSectionHeader(title: "Language")
        let footnote = SettingsFootnote(
            "System follows your device language. Changing this also changes the language the Anki engine uses."
        )
        let row = SettingsToggleRow(
            title: "App Language", systemImage: "globe", tone: .info, isOn: .constant(false)
        )
        for tag in Self.shippedLanguages {
            let locale = Locale(identifier: tag)
            XCTAssertNotEqual(
                try Self.render(header, locale: Locale(identifier: "en")),
                try Self.render(header, locale: locale),
                "the section header stays English in \(tag)"
            )
            XCTAssertNotEqual(
                try Self.render(footnote, locale: Locale(identifier: "en")),
                try Self.render(footnote, locale: locale),
                "the explanatory text stays English in \(tag)"
            )
            XCTAssertNotEqual(
                try Self.render(row, locale: Locale(identifier: "en")),
                try Self.render(row, locale: locale),
                "the settings row title stays English in \(tag)"
            )
        }
    }

    func testAppearanceAndNavigationHaveTranslations() {
        for tag in Self.shippedLanguages {
            for key in [
                "Appearance", "Settings", "Theme", "Light", "Dark", "App Font", "Font", "Serif", "Preview",
                "Minimal", "Muted", "Sepia", "Vivid", "Positive", "Warning", "Primary action",
                "Library", "Read", "Study", "Stats", "Browse", "Theme & Appearance",
            ] {
                XCTAssertNotEqual(Self.localized(key, language: tag), key, "\(key) is missing in \(tag)")
            }
        }
    }

    /// Two catalog-backed `Text`s, rendered off-screen. `ImageRenderer` rather
    /// than `NSHostingView` because the latter is AppKit-only and this target
    /// runs on iOS too.
    @MainActor
    private static func render(locale: Locale) throws -> Data {
        struct Probe: View {
            var body: some View {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Undo")
                    Text("Resume session")
                }
                .padding(8)
            }
        }
        return try render(Probe(), locale: locale)
    }

    private static func render<Content: View>(_ content: Content, locale: Locale) throws -> Data {
        let renderer = ImageRenderer(content: content
            .frame(width: 480, alignment: .leading)
            .environment(\.locale, locale))
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage, "ImageRenderer produced no image")
        #if canImport(UIKit)
        let data = UIImage(cgImage: image).pngData()
        #else
        let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        #endif
        guard let data else {
            throw XCTSkip("could not encode the rendered image")
        }
        return data
    }

    // MARK: - Cold launch
    //
    // The widget runs in its own process and writes the App Group key while
    // the app is not running, so the store has to read storage at init rather
    // than trusting in-memory state. This goes through the real
    // `AppGroup.defaults` and the real store, not a test double.

    @MainActor
    func testAStoredOverrideIsPickedUpOnLaunch() throws {
        let group = try XCTUnwrap(
            UserDefaults(suiteName: "group.com.bagumamartin.ijuka"),
            "the App Group suite is unavailable — the override cannot cross processes"
        )
        let previous = group.string(forKey: AppLocale.overrideKey)
        defer {
            group.removeObject(forKey: AppLocale.overrideKey)
            if let previous { group.set(previous, forKey: AppLocale.overrideKey) }
        }

        group.set("vi", forKey: AppLocale.overrideKey)
        // What `AppLocaleModel.shared`'s initializer does.
        let onLaunch = AppLocaleModel(readingStoredOverride: true)
        XCTAssertEqual(onLaunch.overrideTag, "vi")
        XCTAssertEqual(onLaunch.locale.language.languageCode?.identifier, "vi")

        group.removeObject(forKey: AppLocale.overrideKey)
        let cleared = AppLocaleModel(readingStoredOverride: true)
        XCTAssertNil(cleared.overrideTag, "no stored override must mean the system language")
    }

    // MARK: - Helper

    /// The exact lookup `L10n` performs. `LocalizedStringResource` rather than
    /// `String(localized:locale:)` because the latter takes a
    /// `LocalizationValue` and ignores the locale when choosing a `.lproj` —
    /// which would make this whole file pass on a broken implementation.
    private static func localized(_ key: String, language: String) -> String {
        String(
            localized: LocalizedStringResource(
                String.LocalizationValue(key),
                table: "Localizable",
                locale: Locale(identifier: language),
                bundle: Bundle.main
            )
        )
    }
}

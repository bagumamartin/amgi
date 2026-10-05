public import Foundation
import Observation
import AnkiKit

/// Where the app's language choice is *stored*, and the nonisolated reads that
/// everything can use.
///
/// `UserDefaults` in the App Group, so the widget and the watch agree with the
/// app rather than each following the system. Deliberately free of
/// observation: `L10n` resolves strings from model and view code alike, and
/// `Bootstrap` reads it before the main actor is necessarily warm. SwiftUI's
/// re-render hook is `AppLocaleModel` below, which mirrors this value.
public enum AppLocale {
    /// App Group key holding the explicit language tag. Absent or empty means
    /// "follow the system".
    public static let overrideKey = "ijuka.appLanguageOverride"

    /// The String Catalog table every bundle ships. `AppLocale.resourceBundle`
    /// probes for this name, so renaming it here is the only edit needed.
    public static let tableName = "Localizable"

    /// A key that exists in the catalog in every language.
    ///
    /// `Bundle.localizedString(forKey:value:table:)` returns `value:` verbatim
    /// when the key is missing, which makes this the only reliable way to
    /// tell "this bundle has a catalog" from "this bundle has an empty
    /// localization directory" — `path(forResource:ofType:)` cannot see
    /// through `.lproj` nesting, and the generated symbols can't be
    /// referenced from a module that may not have been generated yet.
    static let probeKey = "ijuka.localization.probe"

    /// The explicit language tag, or nil when the app follows the system.
    public static var overrideTag: String? {
        get {
            let stored = AppGroup.defaults.string(forKey: overrideKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let stored, !stored.isEmpty else { return nil }
            return stored
        }
        set {
            let trimmed = (newValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                AppGroup.defaults.removeObject(forKey: overrideKey)
            } else {
                AppGroup.defaults.set(trimmed, forKey: overrideKey)
            }
        }
    }

    /// Convenience for settings rows: `nil` / `""` clears the override.
    public static func setOverride(_ tag: String?) {
        overrideTag = tag
    }

    /// Language tags in preference order. Pass this to
    /// `AnkiBackend(preferredLangs:)`.
    ///
    /// Deliberately never topped up with `"en"` — see
    /// `LanguagePreferences` for why that would defeat the whole mechanism.
    public static var languageTags: [String] {
        if let overrideTag {
            return LanguagePreferences.normalizedTags([overrideTag])
        }
        return LanguagePreferences.systemTags
    }

    /// The locale the whole app should render in: the system locale, or the
    /// override in full.
    public static var current: Locale {
        guard let overrideTag else { return .current }
        return Locale(identifier: overrideTag)
    }

    /// Bundle metadata and `.lproj` resources can report the same language
    /// twice. Picker identity and selection must use the same unique tag.
    public static var availableLanguageTags: [String] {
        languageOptions(from: resourceBundle.localizations)
    }

    static func languageOptions(from localizations: [String]) -> [String] {
        let tags = localizations.compactMap { identifier -> String? in
            guard identifier.caseInsensitiveCompare("Base") != .orderedSame else { return nil }
            let language = Locale.Language(identifier: identifier)
            guard language.languageCode != nil else { return nil }
            return language.minimalIdentifier
        }
        return Set(tags).sorted()
    }

    /// An autonym stays recognizable when the interface language changes.
    public static func languageName(for tag: String) -> String {
        Locale(identifier: tag).localizedString(forIdentifier: tag) ?? tag
    }

    /// The bundle that owns the app's String Catalog.
    ///
    /// Order matters. `Bundle.main` comes first because that is what SwiftUI
    /// resolves `Text("…")` against — a lookup that went to the module
    /// bundle would disagree with every literal in the app the moment the two
    /// catalogs drifted. The module bundle is the fallback for hosts that
    /// ship the catalog only inside the package (previews, unit tests, and
    /// the watch before its own copy is added).
    public static var resourceBundle: Bundle {
        for bundle in [Bundle.main, Bundle.module] where ownsCatalog(bundle) {
            return bundle
        }
        return Bundle.main
    }

    /// Whether `bundle` actually contains this app's catalog.
    static func ownsCatalog(_ bundle: Bundle) -> Bool {
        bundle.localizedString(forKey: probeKey, value: probeKey, table: tableName) != probeKey
    }
}

/// The app's language as something SwiftUI can observe.
///
/// ## Why this exists
///
/// `.environment(\.locale,)` is applied once, in the root view's `body`. For
/// a language change to reach the screen, that body has to run again — and
/// SwiftUI only re-runs it when a property it read through the observation
/// system changes. Neither of the obvious alternatives qualifies:
///
/// - reading `AppLocale.overrideTag` — a `UserDefaults` lookup, and
///   `UserDefaults` is not observable;
/// - a *computed* property here that forwards to `AppLocale` — `@Observable`
///   instruments stored properties only, so a computed pass-through is just
///   as unobservable as the static it replaced.
///
/// The symptom in both cases is a language picker that appears to work and
/// does nothing: the key is written, `L10n` (which reads `UserDefaults` live,
/// per lookup) starts returning the new language, and every `Text("…")` in the
/// app stays in the old one. Half-translated, which is the outcome the catalog
/// work exists to prevent.
///
/// So `overrideTag` is *stored* here and written through to the App Group on
/// change. Reading `locale` in a body registers a dependency; setting
/// `overrideTag` invalidates every body that has one, and the new locale
/// propagates down the tree.
///
/// ## One source of truth?
///
/// `UserDefaults` remains the cross-process store — the widget and the watch
/// read it without going through an observable object. Within one app run
/// this cannot drift, because the app is the only writer: the value is read
/// once at init (picking up anything the widget wrote while the app was
/// closed) and every later change goes through here.
@MainActor
@Observable
public final class AppLocaleModel {
    public static let shared = AppLocaleModel()

    /// The explicit language tag, or nil when following the system.
    /// Stored (not computed) so `@Observable` can see it — see the type doc.
    public private(set) var overrideTag: String?

    private init() {
        overrideTag = AppLocale.overrideTag
    }

    /// Test seam: builds a store seeded from storage, standing in for a launch
    /// that finds a value the widget wrote while the app was closed. Production
    /// always goes through `shared`.
    init(readingStoredOverride: Bool) {
        overrideTag = readingStoredOverride ? AppLocale.overrideTag : nil
    }

    /// `nil` / `""` clears the override. The single write path.
    public func setOverride(_ tag: String?) {
        let trimmed = (tag ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let next: String? = trimmed.isEmpty ? nil : trimmed
        guard next != overrideTag else { return }
        overrideTag = next
        AppLocale.overrideTag = next
    }

    /// The value to apply at `.environment(\.locale,)` on the root view.
    public var locale: Locale {
        guard let overrideTag else { return .current }
        return Locale(identifier: overrideTag)
    }
}

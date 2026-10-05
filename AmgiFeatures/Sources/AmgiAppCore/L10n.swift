public import Foundation

/// Localized-string lookup that always resolves against the app's String
/// Catalog, whichever bundle happens to be running.
///
/// SwiftUI's `Text("…")` resolves through `Bundle.main` on its own, which is
/// why the catalog has to ship in the app, widget, and watch bundles. But
/// most copy in this app is *not* a SwiftUI literal — it is a `String` on a
/// model, a `title` on a settings row, an accessibility label, a menu
/// action. Those call sites need something they can be handed, and the
/// default `Bundle.main` lookup gives them no way to say "and use *this*
/// locale" once an in-app override exists.
///
/// ## Naming
///
/// - `text(_:)` for literal keys. The parameter is
///   `String.LocalizationValue`, the type the String Catalog extractor
///   recognizes, so copy written this way lands in the catalog on the next
///   extraction. Use it everywhere the key is known at compile time.
/// - `key(_:)` for keys only known at runtime (an engine error identifier, a
///   deck type). These cannot be extracted and will show the raw key when
///   untranslated — a visible bug, not a silent one.
/// - `format(_:_:)` for a localized format string. Pass the format through
///   `String(format:locale:)` so the substitution rules are the target
///   locale's, not the process's.
public enum L10n {
    /// The locale all localization goes through: the system locale, or the
    /// app's in-app override when one is set. Format dates, numbers, and
    /// durations against this rather than `Locale.current`, which ignores
    /// the override.
    public static var locale: Locale { AppLocale.current }

    /// Looks up a literal key. The key doubles as the English source string.
    public static func text(_ key: String.LocalizationValue) -> String {
        resolve(key)
    }

    /// Looks up a key that is only known at runtime.
    ///
    /// - Returns: the localized string, or `key` itself when the catalog has
    ///   no entry — never an empty string, so a missing translation is
    ///   obvious rather than invisible.
    public static func key(_ key: String) -> String {
        resolve(String.LocalizationValue(key))
    }

    /// Resolves a localized format string and substitutes into it.
    ///
    /// The template is a catalog key, so a translator can reorder the
    /// arguments: `"Undo %@"` reads correctly in English and becomes
    /// `"Visszavonás: %@"` in Hungarian, where a colon introduces the object.
    public static func format(
        _ key: String.LocalizationValue,
        _ arguments: [any CVarArg] = []
    ) -> String {
        let template = resolve(key)
        guard !arguments.isEmpty else { return template }
        return String(format: template, locale: AppLocale.current, arguments: arguments)
    }

    /// The one lookup everything goes through.
    ///
    /// ## Why `LocalizedStringResource` and not `String(localized:locale:)`
    ///
    /// The two lookups look interchangeable and are not. Given a
    /// `String.LocalizationValue`, `String(localized:table:bundle:locale:)`
    /// uses `locale:` for *formatting* but still picks the `.lproj` from the
    /// bundle's own preferred localizations — so an in-app override is
    /// silently ignored and the caller gets English.
    ///
    /// Verified against the built app bundle, which ships `en`, `es`, `fr`, `hu`, and
    /// `vi`: with a `hu` locale, the `LocalizationValue` form returns `Undo`
    /// and this form returns `Visszavonás`. `LocalizedStringResource` is also
    /// one of the two types the String Catalog extractor recognizes, so the
    /// literals still get extracted.
    private static func resolve(_ key: String.LocalizationValue) -> String {
        String(
            localized: LocalizedStringResource(
                key,
                table: AppLocale.tableName,
                locale: AppLocale.current,
                bundle: AppLocale.resourceBundle
            )
        )
    }
}

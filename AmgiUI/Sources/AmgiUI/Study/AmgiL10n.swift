public import Foundation

/// Override-aware string lookup for AmgiUI.
///
/// AmgiUI cannot depend on AmgiAppCore (`L10n`/`AppLocale` live there, and
/// Features already depends on UI — the edge would be circular), so this
/// is the same lookup written against `Bundle.main`, which is where the app,
/// widget, and watch targets each ship their copy of the catalog.
///
/// Callers pass the locale explicitly: SwiftUI views read it from
/// `@Environment(\.locale)` (which the root sets from the in-app override),
/// and model helpers like `StudySpan` take it as a parameter from container
/// code that already knows `AppLocale.current`. Never fall back to
/// `Locale.current` here — that ignores the in-app override and is how
/// English leaked through Vietnamese mode.
public enum AmgiL10n {
    public static func text(_ key: String, locale: Locale) -> String {
        String(
            localized: LocalizedStringResource(
                String.LocalizationValue(key),
                table: "Localizable",
                locale: locale,
                bundle: .main
            )
        )
    }

    public static func format(_ key: String, _ arguments: [any CVarArg], locale: Locale) -> String {
        let template = text(key, locale: locale)
        guard !arguments.isEmpty else { return template }
        return String(format: template, locale: locale, arguments: arguments)
    }
}

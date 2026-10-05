public import Dependencies
import AnkiKit

private enum AnkiBackendKey: DependencyKey {
    // `LanguagePreferences.systemTags` rather than a hardcoded `["en"]`:
    // this is the fallback used by anything that does not construct its own
    // backend, and English is the engine's own final template fallback —
    // asking for it first would short-circuit every other language in
    // `I18n::new`.
    static let liveValue: AnkiBackend = {
        try! AnkiBackend(preferredLangs: LanguagePreferences.systemTags)
    }()

    static let testValue: AnkiBackend = {
        try! AnkiBackend(preferredLangs: LanguagePreferences.systemTags)
    }()
}

extension DependencyValues {
    public var ankiBackend: AnkiBackend {
        get { self[AnkiBackendKey.self] }
        set { self[AnkiBackendKey.self] = newValue }
    }
}

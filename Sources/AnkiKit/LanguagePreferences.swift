import Foundation

/// Language tags for the Anki engine's `preferred_langs`, and the rules for
/// turning "what the system says" into that list.
///
/// Lives in AnkiKit — not in the app layer — because three very different
/// callers need the same answer: the iOS/macOS app, the watch, and the MCP
/// helper. AnkiKit has no dependencies, so all three can reach it.
///
/// ## Why the list is never topped up with English
///
/// `I18n::new` walks the requested tags in order and **stops at the first
/// one whose language is `en`**, because the bundled `en-US` template is
/// 100% covered and is appended as the final fallback anyway
/// (`anki-upstream/rslib/i18n/src/lib.rs`). Appending `"en"` to a list that
/// already asked for, say, French would therefore pin the whole engine to
/// English. The list is passed through in the user's own order, and the
/// engine's own template fallback supplies English for keys nobody has
/// translated.
public enum LanguagePreferences: Sendable {
    /// Used only when nothing usable is left to send.
    public static let fallbackTag = "en"

    /// The system's preferred languages, normalized and de-duplicated.
    public static var systemTags: [String] {
        normalizedTags(Locale.preferredLanguages)
    }

    /// Normalizes raw language tags into what the engine's `LanguageIdentifier`
    /// parser accepts: `ko_KR` → `ko-KR`, blanks dropped, duplicates kept
    /// only in first-seen order (order *is* the preference order).
    ///
    /// - Parameter raw: tags as the user (or a stored override) wrote them.
    /// - Returns: a non-empty list; `["en"]` when `raw` holds nothing usable.
    public static func normalizedTags(_ raw: [String]) -> [String] {
        var seen: Set<String> = []
        let tags = raw.compactMap { value -> String? in
            let tag = value
                .replacingOccurrences(of: "_", with: "-")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tag.isEmpty, seen.insert(tag).inserted else { return nil }
            return tag
        }
        return tags.isEmpty ? [fallbackTag] : tags
    }
}

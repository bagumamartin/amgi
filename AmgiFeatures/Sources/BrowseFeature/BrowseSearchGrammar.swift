import Foundation
import AnkiKit

/// Canonical engine search-grammar helpers.
///
/// The bundled parser (rslib `search/parser.rs`) accepts only:
/// - numeric flags `flag:0…7` (`0` = no flag)
/// - comma-separated id lists `nid:1,2` / `cid:1,2` (digits and commas only)
/// - `tag:none` for untagged (`tag:*` matches *every* note, so `-tag:*` is wrong)
/// - `prop:due=0` for due-today (`due:` is not a scheduling operator)
/// - `resched:1` for rescheduled-today
/// - `is:due -prop:due=0` for overdue
///
/// All query construction in Browse must go through these builders so generated
/// fragments stay compatible with the parser we actually ship.
enum BrowseSearchGrammar {
    /// `nid:1,2,3` — nil when empty. Comma form per `check_id_list`.
    static func noteIDs(_ ids: [NoteID]) -> String? {
        guard !ids.isEmpty else { return nil }
        return "nid:" + ids.map { String($0.rawValue) }.joined(separator: ",")
    }

    static func noteIDs(_ raw: [Int64]) -> String? {
        guard !raw.isEmpty else { return nil }
        return "nid:" + raw.map(String.init).joined(separator: ",")
    }

    /// `cid:1,2,3` — nil when empty.
    static func cardIDs(_ ids: [CardID]) -> String? {
        guard !ids.isEmpty else { return nil }
        return "cid:" + ids.map { String($0.rawValue) }.joined(separator: ",")
    }

    static func cardIDs(_ raw: [Int64]) -> String? {
        guard !raw.isEmpty else { return nil }
        return "cid:" + raw.map(String.init).joined(separator: ",")
    }

    /// OR of per-id singletons — valid but verbose; prefer the comma form.
    /// Kept for callers that must stay under per-node id-count guidance.
    static func orJoinedNoteIDs(_ ids: [NoteID]) -> String? {
        guard !ids.isEmpty else { return nil }
        return ids.map { "nid:\($0.rawValue)" }.joined(separator: " OR ")
    }

    /// Grammar prefixes that mark a token as structural (not a deck/tag
    /// name filter). Kept in one place so the sidebar filter, the free-text
    /// gate, and deck-tree tokenization agree.
    static let structuralPrefixes = [
        "deck:", "tag:", "is:", "prop:", "added:", "edited:",
        "rated:", "resched:", "nid:", "cid:", "did:", "mid:", "note:",
        "card:", "flag:", "introduced:", "dupe:", "re:", "nc:", "sc:",
        "w:", "has-cd:", "preset:",
    ]

    static func isStructural(token: Substring) -> Bool {
        let lowered = token.lowercased()
        return structuralPrefixes.contains { lowered.hasPrefix($0) }
    }

    /// True when the text is pure free-text with no structural fragments.
    static func isPlainFreeText(_ text: String) -> Bool {
        for word in text.split(separator: " ") where !word.isEmpty {
            if isStructural(token: word) { return false }
        }
        return true
    }
}

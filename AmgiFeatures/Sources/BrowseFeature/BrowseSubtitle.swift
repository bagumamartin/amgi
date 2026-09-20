import Foundation
import AnkiKit

func composeNoteSubtitle(notetypeName: String?, tags: String) -> String? {
    let visibleTags = tags
        .split(whereSeparator: { $0.isWhitespace })
        .map(String.init)
        .filter { $0.caseInsensitiveCompare("marked") != .orderedSame }
        .map(displayTagName)
    let parts = [notetypeName].compactMap { name in
        guard let name, !name.isEmpty else { return nil }
        return name
    } + visibleTags
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
}

func displayTagName(_ tag: String) -> String {
    let leaf = tag.components(separatedBy: "::").last ?? tag
    return leaf.replacingOccurrences(of: "-", with: " ")
}

func browsePlainTextTitle(for note: NoteRecord, fallback: String? = nil) -> String {
    let candidates = [note.sfld] + note.flds.components(separatedBy: "\u{1f}")
    for candidate in candidates {
        let clean = candidate
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !clean.isEmpty { return clean }
    }
    if note.flds.contains("<img") { return "Image note" }
    if note.flds.contains("[sound:") { return "Audio note" }
    return fallback ?? "Untitled note"
}

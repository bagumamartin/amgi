import AnkiKit
import AmgiCardWeb
import AssistantFeature
import Foundation

extension BrowseModel {
    /// The search on screen as an assistant chip: what was asked and the
    /// first matches, in the order the list shows them. `nil` when Browse
    /// shows everything — there is no search to talk about.
    var assistantSearchContext: AssistantContext? {
        let typed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = typed.isEmpty ? buildQuery().trimmingCharacters(in: .whitespacesAndNewlines) : typed
        guard !query.isEmpty else { return nil }
        let records: [NoteRecord] = ids.prefix(windowEnd).prefix(20).compactMap { id in
            switch mode {
            case .notes: noteRecords[id]
            case .cards: cardRecords[id].flatMap { noteRecords[$0.nid.rawValue] }
            }
        }
        let lines = records.enumerated().map { index, note in
            "[\(index + 1)] " + String(CardText.plainText(note.sfld).prefix(140))
        }
        return .search(
            query: query, count: ids.count,
            results: lines.isEmpty ? "" : "First matches:\n" + lines.joined(separator: "\n")
        )
    }
}

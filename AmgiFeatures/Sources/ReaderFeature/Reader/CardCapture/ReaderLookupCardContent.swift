import AmgiReader
import AnkiClients
import Foundation

/// The two sides of a one-tap vocabulary card, for when the user has not
/// mapped a lookup template.
///
/// The term alone on the front; on the back, what you would want when you
/// miss it in review — the reading, the definitions (one per dictionary, at
/// most three, so a card stays a card), and the sentence you met it in.
struct ReaderLookupCardContent: Equatable {
    let front: String
    let back: String

    static let maximumDefinitions = 3

    init(term: String, reading: String?, definitions: [String], sentence: String?) {
        front = term.trimmingCharacters(in: .whitespacesAndNewlines)

        var sections: [String] = []
        if let reading = reading?.trimmingCharacters(in: .whitespacesAndNewlines),
           !reading.isEmpty, reading != front {
            sections.append(reading)
        }
        let cleaned = definitions
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(Self.maximumDefinitions)
        if !cleaned.isEmpty {
            sections.append(cleaned.joined(separator: "\n"))
        }
        if let sentence = sentence.map(ReaderSourceAnchor.normalize),
           !sentence.isEmpty, sentence != front {
            sections.append(sentence)
        }
        back = sections.joined(separator: "\n\n")
    }

    init(entry: DictionaryLookupEntry, sentence: String?) {
        self.init(
            term: entry.term,
            reading: entry.reading,
            definitions: entry.glossaries.isEmpty
                ? ReaderLookupNotePayload.definitionsByDictionary(from: entry.structuredGlossaries)
                : entry.glossaries,
            sentence: sentence
        )
    }
}

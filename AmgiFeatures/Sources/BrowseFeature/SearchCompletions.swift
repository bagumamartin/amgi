import AnkiKit
import Foundation

/// Google-style completions for the Browse search field, from the user's own
/// notes. The word being typed is completed from the collection's words,
/// ranked by how many notes hold each, then two-word phrases that start with
/// it ("liver cirrhosis").
///
/// For the word being typed this is the same order the current matches would
/// give: every note holding "liver" is already a match for "liv". Reading the
/// index instead of the results means completions appear with the first
/// keystroke and don't reshuffle when the results land.
enum SearchCompletions {
    /// Words this short complete to too much to be useful.
    static let minimumPrefix = 2
    private static let minimumWordLength = 3
    /// A phrase needs this many notes behind it, or it is one note's wording.
    private static let minimumPhraseNotes = 2
    private static let phrasesPerWord = 3

    /// Collection vocabulary: each word with the number of notes holding it,
    /// sorted for prefix lookup, and each word's commonest next words. Built
    /// once, off the main actor.
    struct Index: Sendable {
        fileprivate let words: [(word: String, notes: Int)]
        fileprivate let nextWords: [String: [String]]
        static let empty = Index(words: [], nextWords: [:])

        init(records: [NoteRecord]) {
            var wordNotes: [String: Int] = [:]
            var phraseNotes: [String: [String: Int]] = [:]
            for record in records {
                let tokens = SearchCompletions.words(inOrder: record)
                var seenWords = Set<String>(), seenPhrases = Set<String>()
                for (index, word) in tokens.enumerated() {
                    if seenWords.insert(word).inserted { wordNotes[word, default: 0] += 1 }
                    guard index + 1 < tokens.count else { continue }
                    let next = tokens[index + 1]
                    if seenPhrases.insert(word + " " + next).inserted {
                        phraseNotes[word, default: [:]][next, default: 0] += 1
                    }
                }
            }
            words = wordNotes.map { ($0.key, $0.value) }.sorted { $0.word < $1.word }
            nextWords = phraseNotes.compactMapValues { nexts in
                let top = nexts.filter { $0.value >= SearchCompletions.minimumPhraseNotes }
                    .sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
                    .prefix(SearchCompletions.phrasesPerWord)
                    .map(\.key)
                return top.isEmpty ? nil : Array(top)
            }
        }

        private init(words: [(word: String, notes: Int)], nextWords: [String: [String]]) {
            self.words = words
            self.nextWords = nextWords
        }

        var isEmpty: Bool { words.isEmpty }

        /// Words starting with `prefix` (the prefix itself included when it
        /// is a word), most common first.
        func words(withPrefix prefix: String, limit: Int) -> [String] {
            var low = 0, high = words.count
            while low < high {
                let mid = (low + high) / 2
                if words[mid].word < prefix { low = mid + 1 } else { high = mid }
            }
            var found: [(word: String, notes: Int)] = []
            var index = low
            while index < words.count, words[index].word.hasPrefix(prefix) {
                found.append(words[index])
                index += 1
            }
            return found.sorted { $0.notes > $1.notes || ($0.notes == $1.notes && $0.word < $1.word) }
                .prefix(limit).map(\.word)
        }
    }

    /// Completions for `text`, each a whole query ready to put in the field.
    static func complete(_ text: String, index: Index, limit: Int = 6) -> [String] {
        let start = text.lastIndex(where: \.isWhitespace).map { text.index(after: $0) } ?? text.startIndex
        let head = String(text[..<start])
        let prefix = String(text[start...]).lowercased()
        guard prefix.count >= minimumPrefix,
              prefix.allSatisfy({ $0.isLetter || $0.isNumber }) else { return [] }

        let words = index.words(withPrefix: prefix, limit: 4)
        var results: [String] = []
        func add(_ completion: String) {
            let query = head + completion
            if results.count < limit, query.lowercased() != text.lowercased(), !results.contains(query) {
                results.append(query)
            }
        }
        for word in words.prefix(3) { add(word) }
        // Phrases continue the likeliest words, in the same order.
        for word in words.prefix(2) {
            for next in index.nextWords[word] ?? [] { add(word + " " + next) }
        }
        return results
    }

    fileprivate static func words(inOrder record: NoteRecord) -> [String] {
        SemanticNoteIndex.corpusText(of: record)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= minimumWordLength && $0.contains(where: \.isLetter) }
    }
}

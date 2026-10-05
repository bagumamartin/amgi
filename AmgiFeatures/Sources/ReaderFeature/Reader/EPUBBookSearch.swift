import AmgiReader
import AmgiTheme
import AmgiUI
import Foundation
import Observation
import SwiftUI

struct EPUBBookSearchHit: Identifiable, Sendable {
    var id: String { "\(chapterIndex):\(matchOffset)" }
    let chapterIndex: Int
    let chapterTitle: String
    let snippet: String
    let anchor: ReaderSourceAnchor
    let matchOffset: Int
}

@Observable
@MainActor
final class EPUBBookSearchModel {
    private(set) var hits: [EPUBBookSearchHit] = []
    private(set) var isSearching = false
    private(set) var errorMessage: String?
    private var searchGeneration = 0

    func search(_ query: String, in book: ReaderBook, contents: [Int: EPUBChapterContent]) async {
        let needle = ReaderSourceAnchor.normalize(query)
        guard !needle.isEmpty else {
            hits = []
            errorMessage = nil
            return
        }

        searchGeneration += 1
        let generation = searchGeneration
        isSearching = true
        errorMessage = nil
        let sources = book.chapters.enumerated().compactMap { index, chapter -> SearchSource? in
            guard let content = contents[index] else { return nil }
            return SearchSource(
                chapterIndex: index,
                chapterID: chapter.id,
                chapterTitle: chapter.title,
                chapterHref: content.chapterHref,
                url: content.contentURL
            )
        }

        do {
            let found = try await Task.detached(priority: .userInitiated) {
                try Self.find(needle, in: sources, bookID: book.id)
            }.value
            guard generation == searchGeneration else { return }
            hits = found
            isSearching = false
        } catch {
            guard generation == searchGeneration else { return }
            hits = []
            errorMessage = error.localizedDescription
            isSearching = false
        }
    }

    func clear() {
        searchGeneration += 1
        hits = []
        errorMessage = nil
        isSearching = false
    }

    private struct SearchSource: Sendable {
        let chapterIndex: Int
        let chapterID: Int64
        let chapterTitle: String
        let chapterHref: String?
        let url: URL
    }

    nonisolated private static func find(
        _ query: String,
        in sources: [SearchSource],
        bookID: String
    ) throws -> [EPUBBookSearchHit] {
        var results: [EPUBBookSearchHit] = []
        for source in sources {
            let html = try String(contentsOf: source.url, encoding: .utf8)
            let text = plainText(from: html)
            let body = text as NSString
            var searchRange = NSRange(location: 0, length: body.length)

            while searchRange.length > 0, results.count < 500 {
                let match = body.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange)
                guard match.location != NSNotFound else { break }
                let start = max(0, match.location - 72)
                let end = min(body.length, NSMaxRange(match) + 96)
                let snippet = ReaderSourceAnchor.normalize(body.substring(with: NSRange(location: start, length: end - start)))
                let before = body.substring(with: NSRange(location: max(0, match.location - 32), length: min(32, match.location)))
                let afterStart = NSMaxRange(match)
                let after = body.substring(with: NSRange(location: afterStart, length: min(32, max(0, body.length - afterStart))))
                let quote = body.substring(with: match)
                let anchor = ReaderSourceAnchor(
                    bookID: bookID,
                    chapterID: source.chapterID,
                    chapterHref: source.chapterHref,
                    quote: quote,
                    contextBefore: before,
                    contextAfter: after
                )
                results.append(EPUBBookSearchHit(
                    chapterIndex: source.chapterIndex,
                    chapterTitle: source.chapterTitle,
                    snippet: snippet,
                    anchor: anchor,
                    matchOffset: match.location
                ))
                let next = NSMaxRange(match)
                guard next < body.length else { break }
                searchRange = NSRange(location: next, length: body.length - next)
            }
            if results.count >= 500 { break }
        }
        return results
    }

    nonisolated private static func plainText(from html: String) -> String {
        var value = html
        for pattern in ["(?is)<!--.*?-->", "(?is)<(script|style|svg|head)\\b[^>]*>.*?</\\1>"] {
            value = value.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        value = value.replacingOccurrences(
            of: "(?i)</?(?:p|div|br|li|h[1-6]|section|article|tr|blockquote|title)[^>]*>",
            with: " ",
            options: .regularExpression
        )
        value = value.replacingOccurrences(of: "(?s)<[^>]+>", with: " ", options: .regularExpression)
        value = decodeNumericEntities(value)
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'"]
        for (entity, decoded) in entities {
            value = value.replacingOccurrences(of: entity, with: decoded, options: .caseInsensitive)
        }
        return ReaderSourceAnchor.normalize(value)
    }

    nonisolated private static func decodeNumericEntities(_ source: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: "&#(?:x([0-9a-fA-F]+)|([0-9]+));") else {
            return source
        }
        let result = NSMutableString(string: source)
        let matches = expression.matches(in: source, range: NSRange(location: 0, length: (source as NSString).length))
        for match in matches.reversed() {
            let hexRange = match.range(at: 1)
            let decimalRange = match.range(at: 2)
            let scalarValue: UInt32?
            if hexRange.location != NSNotFound {
                scalarValue = UInt32((source as NSString).substring(with: hexRange), radix: 16)
            } else if decimalRange.location != NSNotFound {
                scalarValue = UInt32((source as NSString).substring(with: decimalRange))
            } else {
                scalarValue = nil
            }
            let replacement: String
            if let scalarValue, let scalar = UnicodeScalar(scalarValue) {
                replacement = String(scalar)
            } else {
                replacement = " "
            }
            result.replaceCharacters(in: match.range, with: replacement)
        }
        return result as String
    }
}

struct EPUBBookSearchPanel: View {
    let bookTitle: String
    let model: EPUBBookSearchModel
    let onSearch: (String) async -> Void
    let onSelect: (EPUBBookSearchHit) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    @State private var query = ""

    var body: some View {
        NavigationStack {
            Group {
                if model.isSearching {
                    ProgressView("Searching book…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = model.errorMessage {
                    ContentUnavailableView("Search Unavailable", systemImage: "magnifyingglass", description: Text(error))
                } else if model.hits.isEmpty {
                    ContentUnavailableView(
                        query.isEmpty ? "Search Book" : "No Results",
                        systemImage: "magnifyingglass",
                        description: Text(query.isEmpty ? "Find a word or phrase in this book." : "No matches found in this book.")
                    )
                } else {
                    List(model.hits) { hit in
                        Button { onSelect(hit) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(hit.chapterTitle)
                                    .font(.headline)
                                    .foregroundStyle(palette.textPrimary)
                                Text(hit.snippet)
                                    .font(.subheadline)
                                    .foregroundStyle(palette.textSecondary)
                                    .lineLimit(3)
                            }
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle(bookTitle)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Search Book")
            .onSubmit(of: .search) { Task { await onSearch(query) } }
            .onChange(of: query) { _, value in
                if value.isEmpty { model.clear() }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Search") { Task { await onSearch(query) } }
                        .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

import AmgiReader
import AnkiBackend
import AnkiKit
import AnkiProtoBridge
public import Dependencies
import DependenciesMacros
import Foundation

private struct ReaderChapterRecord {
    let chapter: ReaderChapter
    let coverImagePath: String?
}

/// Reader books are derived from notes in a configurable deck. Each note
/// becomes a chapter; chapters with the same `bookIDField` value collapse
/// into a single `ReaderBook`. Field mapping is supplied per-call via
/// `ReaderLibraryConfiguration` so users can target their own notetype
/// schema without forking the client.
///
/// Both reads go through the bridge's `readerNotes` aux method, which reads
/// the notes table in one pass instead of one `GetNote` per chapter. The
/// shelf asks for every field *except* the chapter text; the text is read
/// for one book at a time, when it is opened.
extension ReaderBookClient: DependencyKey {
    public static let liveValue: Self = {
        @Dependency(\.ankiBackend) var backend

        @Sendable func shelf(_ configuration: ReaderLibraryConfiguration) async throws -> [ReaderBook] {
            let query = try validatedDeckQuery(configuration.deckName)
            let mapping = configuration.fieldMapping
            let fields = [
                mapping.bookIDField,
                mapping.bookTitleField,
                mapping.chapterTitleField,
                mapping.chapterOrderField,
                mapping.bookCoverField,
                mapping.languageField,
            ].compactMap(\.self)
            let rows = try await backendOffload {
                try backend.invoke(.readerNotes(
                    search: query,
                    fields: fields,
                    requireNonempty: [mapping.contentField]
                ))
            }.notes
            return buildBooks(from: rows, configuration: configuration)
        }

        @Sendable func content(
            of book: ReaderBook,
            _ configuration: ReaderLibraryConfiguration
        ) async throws -> ReaderBook {
            guard !book.chapters.isEmpty else { return book }
            let ids = book.chapters.map { String($0.id) }.joined(separator: ",")
            let rows = try await backendOffload {
                try backend.invoke(.readerNotes(
                    search: "nid:\(ids)",
                    fields: nil,
                    requireNonempty: [configuration.fieldMapping.contentField]
                ))
            }.notes
            return buildBooks(from: rows, configuration: configuration)
                .first { $0.id == book.id } ?? book
        }

        return Self(
            loadBooks: { configuration in
                try await shelf(configuration)
            },
            loadBook: { bookID, configuration in
                guard let outline = try await shelf(configuration).first(where: { $0.id == bookID }) else {
                    return nil
                }
                return try await content(of: outline, configuration)
            },
            loadContent: { book, configuration in
                try await content(of: book, configuration)
            }
        )
    }()
}

private func validatedDeckQuery(_ deckName: String) throws -> String {
    let trimmed = deckName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        throw BackendError(kind: .invalidInput, message: "Reader deck name can't be empty")
    }
    return DeckSearch.term(trimmed)
}

// MARK: - Book assembly

/// Rows without the content field build an outline: every chapter is there
/// with an empty `content`, ready for `loadContent`.
private func buildBooks(
    from rows: [ReaderNoteRow],
    configuration: ReaderLibraryConfiguration
) -> [ReaderBook] {
    var chaptersByBookID: [String: [ReaderChapter]] = [:]
    var coverImagePathByBookID: [String: String] = [:]

    for row in rows {
        if let notetypeID = configuration.notetypeID, row.notetypeId != notetypeID { continue }
        guard let record = makeChapterRecord(row: row, configuration: configuration) else { continue }

        chaptersByBookID[record.chapter.bookID, default: []].append(record.chapter)
        if let cover = record.coverImagePath,
           coverImagePathByBookID[record.chapter.bookID] == nil {
            coverImagePathByBookID[record.chapter.bookID] = cover
        }
    }

    return chaptersByBookID.values
        .map { chapters in
            let sorted = chapters.sorted(by: chapterSort)
            return ReaderBook(
                id: sorted[0].bookID,
                title: sorted[0].bookTitle,
                coverImagePath: coverImagePathByBookID[sorted[0].bookID],
                language: sorted.compactMap(\.language).first,
                chapters: sorted
            )
        }
        .sorted { lhs, rhs in
            let cmp = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
            if cmp != .orderedSame { return cmp == .orderedAscending }
            return lhs.id < rhs.id
        }
}

private func makeChapterRecord(
    row: ReaderNoteRow,
    configuration: ReaderLibraryConfiguration
) -> ReaderChapterRecord? {
    let fieldMap = row.fields
    let mapping = configuration.fieldMapping

    // The aux method already dropped notes with no content, so a missing
    // content field means it was not asked for — an outline row.
    guard let bookID = trimmedFieldValue(mapping.bookIDField, in: fieldMap) else { return nil }
    let content = fieldMap[mapping.contentField] ?? ""

    let bookTitle = trimmedFieldValue(mapping.bookTitleField, in: fieldMap) ?? bookID
    let chapterTitle = trimmedFieldValue(mapping.chapterTitleField, in: fieldMap) ?? bookTitle
    let chapterOrder = trimmedFieldValue(mapping.chapterOrderField, in: fieldMap)
    let language = mapping.languageField.flatMap { trimmedFieldValue($0, in: fieldMap) }
    let coverImagePath = coverFieldValue(mapping.bookCoverField, in: fieldMap)

    return ReaderChapterRecord(
        chapter: ReaderChapter(
            id: row.id,
            bookID: bookID,
            bookTitle: bookTitle,
            title: chapterTitle,
            order: chapterOrder,
            content: content,
            language: language
        ),
        coverImagePath: coverImagePath
    )
}

// MARK: - Field decoding

private func trimmedFieldValue(_ fieldName: String, in fieldMap: [String: String]) -> String? {
    guard let raw = fieldMap[fieldName] else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

private func coverFieldValue(_ fieldName: String?, in fieldMap: [String: String]) -> String? {
    guard let fieldName, let raw = fieldMap[fieldName] else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    if let imageSource = extractImageSource(from: trimmed)?
        .trimmingCharacters(in: .whitespacesAndNewlines),
       !imageSource.isEmpty {
        return imageSource
    }
    // Bare HTML without an <img src> isn't a usable cover path; treat as empty.
    if trimmed.contains("<"), trimmed.contains(">") { return nil }
    return trimmed
}

private func extractImageSource(from value: String) -> String? {
    let range = NSRange(value.startIndex..<value.endIndex, in: value)
    let pattern = #"<img[^>]*\bsrc\s*=\s*['"]?([^'" >]+)"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
          let match = regex.firstMatch(in: value, options: [], range: range),
          let sourceRange = Range(match.range(at: 1), in: value) else {
        return nil
    }
    return String(value[sourceRange])
}

// MARK: - Chapter sort

private func chapterSort(lhs: ReaderChapter, rhs: ReaderChapter) -> Bool {
    let lhsOrder = lhs.order.flatMap(Double.init)
    let rhsOrder = rhs.order.flatMap(Double.init)
    switch (lhsOrder, rhsOrder) {
    case let (l?, r?) where l != r: return l < r
    case (_?, nil): return true
    case (nil, _?): return false
    default:
        let cmp = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
        if cmp != .orderedSame { return cmp == .orderedAscending }
        return lhs.id < rhs.id
    }
}

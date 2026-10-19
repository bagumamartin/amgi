public import Foundation
public import SwiftUI
import AmgiAppCore

/// One thing the chat is about: the collection, a deck, a card, a book's
/// chapter or page, a passage. A chat holds any number of them; each shows as
/// a removable chip above the composer and travels to the model as reference
/// text. Persisted with the chat, so a resumed chat keeps what it was about.
public struct AssistantContext: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case collection, deck, note, review, book, chapter, page, passage
        /// Whole screens: what the user is looking at when there is no
        /// single item — the deck list, today's queue, the stats dashboard,
        /// a search, the reading shelf.
        case library, today, stats, search, shelf
    }

    /// Raw kind, kept a string so chats saved before ``Kind`` grew still
    /// decode. Unknown values read as ``Kind/collection``.
    public var kind: String
    public var title: String
    /// Where the item lives — the book a chapter belongs to, the deck a card
    /// is in. Empty when there is nothing more specific to say.
    public var subtitle: String
    /// The text the model reads. Resolved lazily for notes and decks.
    public var reference: String
    public var deckID: Int64?
    public var noteID: Int64?
    /// Collection-media references only; image bytes stay out of chat metadata.
    /// Nil for unresolved contexts and chats saved before card images were supported.
    public var imageSources: [String]?
    /// A book, chapter or page identity, for de-duplication.
    public var sourceID: String?

    public init(
        title: String = "Collection", reference: String = "", deckID: Int64? = nil, noteID: Int64? = nil,
        kind: String = "collection", subtitle: String = "", sourceID: String? = nil
    ) {
        self.kind = kind; self.title = title; self.reference = reference
        self.deckID = deckID; self.noteID = noteID; self.subtitle = subtitle; self.sourceID = sourceID
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        kind = try values.decodeIfPresent(String.self, forKey: .kind) ?? Kind.collection.rawValue
        title = try values.decodeIfPresent(String.self, forKey: .title) ?? ""
        subtitle = try values.decodeIfPresent(String.self, forKey: .subtitle) ?? ""
        reference = try values.decodeIfPresent(String.self, forKey: .reference) ?? ""
        deckID = try values.decodeIfPresent(Int64.self, forKey: .deckID)
        noteID = try values.decodeIfPresent(Int64.self, forKey: .noteID)
        imageSources = try values.decodeIfPresent([String].self, forKey: .imageSources)
        sourceID = try values.decodeIfPresent(String.self, forKey: .sourceID)
        // Chats saved before chapters and pages were told apart.
        if kind == "reader" { kind = Kind.book.rawValue }
    }

    public var type: Kind { Kind(rawValue: kind) ?? .collection }

    /// About a whole screen rather than one item in it. A screen gives way
    /// to anything more specific shown on top of it.
    public var isScreen: Bool {
        switch type {
        case .collection, .library, .today, .stats, .search, .shelf: true
        default: false
        }
    }

    /// Two chips are the same thing when they point at the same item;
    /// re-adding one replaces it rather than stacking a duplicate.
    public var id: String {
        switch type {
        case .collection: "collection"
        case .deck: "deck:\(deckID ?? 0)"
        case .note, .review: "note:\(noteID ?? 0)"
        case .book, .chapter, .page: "\(kind):\(sourceID ?? title)"
        case .passage: "passage:\(sourceID ?? ""):\(reference.prefix(80))"
        case .library, .today, .shelf: kind
        case .stats, .search: "\(kind):\(sourceID ?? "")"
        }
    }

    public var systemImage: String {
        switch type {
        case .collection: "books.vertical"
        case .deck: "rectangle.stack"
        case .note: "note.text"
        case .review: "rectangle.on.rectangle"
        case .book: "book.closed"
        case .chapter: "book.pages"
        case .page: "doc.text"
        case .passage: "text.quote"
        case .library: "books.vertical"
        case .today: "sun.max"
        case .stats: "chart.bar"
        case .search: "magnifyingglass"
        case .shelf: "books.vertical.fill"
        }
    }

    /// The grey second line of the chip.
    public var caption: String {
        if !subtitle.isEmpty { return subtitle }
        return switch type {
        case .collection: L10n.text("All decks")
        case .deck: L10n.text("Deck")
        case .note: L10n.text("Note")
        case .review: L10n.text("Card in review")
        case .book: L10n.text("Book")
        case .chapter: L10n.text("Chapter")
        case .page: L10n.text("Page")
        case .passage: L10n.text("Selected text")
        case .library: L10n.text("All decks")
        case .today: L10n.text("Today's queue")
        case .stats: L10n.text("Statistics")
        case .search: L10n.text("Search")
        case .shelf: L10n.text("Your books")
        }
    }

    // MARK: Factories

    public static let collection = AssistantContext(title: L10n.text("Collection"), kind: Kind.collection.rawValue)

    /// The deck list. Named and counted when the chat opens.
    public static let library = AssistantContext(title: L10n.text("Library"), kind: Kind.library.rawValue)

    /// The Study screen: what is due today. Counted when the chat opens.
    public static let today = AssistantContext(title: L10n.text("Today"), kind: Kind.today.rawValue)

    /// The stats dashboard as it is filtered on screen, with the figures it
    /// shows. `summary` is empty while the numbers load.
    public static func stats(period: String, days: Int, deckID: Int64?, deckName: String?, summary: String) -> AssistantContext {
        let scope = deckName.map { $0.components(separatedBy: "::").last ?? $0 } ?? L10n.text("All decks")
        return AssistantContext(
            title: L10n.text("Statistics"), reference: summary, deckID: deckID, kind: Kind.stats.rawValue,
            subtitle: "\(period) · \(scope)", sourceID: "\(days):\(deckID ?? 0)"
        )
    }

    /// A search and what it found. `results` lists the matches on screen.
    public static func search(query: String, count: Int?, results: String) -> AssistantContext {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let found = count.map { $0 == 1 ? L10n.text("1 note") : L10n.text("\($0) notes") }
        return AssistantContext(
            title: "“\(query.prefix(40))\(query.count > 40 ? "…" : "")”",
            reference: "The user searched their notes for: \(query)\n" + (count.map { "Matches: \($0)\n" } ?? "") + results,
            kind: Kind.search.rawValue, subtitle: found.map { L10n.text("Search · \($0)") } ?? L10n.text("Search"), sourceID: query
        )
    }

    /// The reading shelf: the books on it, most recent first.
    public static func shelf(books: [String]) -> AssistantContext {
        AssistantContext(
            title: L10n.text("Reading"), reference: books.isEmpty ? "The shelf is empty." : "Books on the user's shelf, most recent first:\n" + books.prefix(40).joined(separator: "\n"),
            kind: Kind.shelf.rawValue, subtitle: books.count == 1 ? L10n.text("1 book") : L10n.text("\(books.count) books")
        )
    }

    public static func deck(id: Int64, name: String) -> AssistantContext {
        AssistantContext(title: name.components(separatedBy: "::").last ?? name, deckID: id, kind: Kind.deck.rawValue,
                         subtitle: name.contains("::") ? name.components(separatedBy: "::").dropLast().joined(separator: " › ") : "")
    }

    /// The card under review. Its title and fields are filled in when the
    /// chat opens, from the note itself.
    public static func card(noteID: Int64?, deckID: Int64?) -> AssistantContext {
        AssistantContext(title: L10n.text("This card"), deckID: deckID, noteID: noteID, kind: Kind.review.rawValue)
    }

    public static func note(id: Int64, deckID: Int64?, fields: String) -> AssistantContext {
        AssistantContext(title: L10n.text("Selected note"), reference: fields, deckID: deckID, noteID: id, kind: Kind.note.rawValue)
    }

    public static func book(id: String, title: String) -> AssistantContext {
        AssistantContext(title: title, kind: Kind.book.rawValue, sourceID: id)
    }

    /// A book's detail page: what it is, where the user is in it, its
    /// chapters.
    public static func bookDetail(id: String, title: String, author: String?, currentChapter: String?, chapters: [String]) -> AssistantContext {
        var lines = ["The user is on the detail page of the book “\(title)”" + (author.map { " by \($0)" } ?? "") + "."]
        if let currentChapter { lines.append("They are currently reading “\(currentChapter)”.") }
        if !chapters.isEmpty {
            lines.append("Chapters:\n" + chapters.prefix(60).enumerated().map { "\($0 + 1). \($1)" }.joined(separator: "\n"))
        }
        let subtitle = author ?? (chapters.count == 1 ? L10n.text("1 chapter") : L10n.text("\(chapters.count) chapters"))
        return AssistantContext(
            title: title, reference: lines.joined(separator: "\n"), kind: Kind.book.rawValue,
            subtitle: subtitle, sourceID: id
        )
    }

    public static func chapter(bookID: String, bookTitle: String, chapterID: Int64, title: String, text: String) -> AssistantContext {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return AssistantContext(
            title: name.isEmpty ? bookTitle : name, reference: text, kind: Kind.chapter.rawValue,
            subtitle: name.isEmpty ? L10n.text("Chapter") : bookTitle, sourceID: "\(bookID)#\(chapterID)"
        )
    }

    public static func page(bookID: String, bookTitle: String, page: Int, text: String) -> AssistantContext {
        AssistantContext(
            title: L10n.text("Page \(page)"), reference: text, kind: Kind.page.rawValue,
            subtitle: bookTitle, sourceID: "\(bookID)#p\(page)"
        )
    }

    /// Text the reader has selected. Nil when nothing is.
    public static func passage(_ text: String?, bookID: String, bookTitle: String) -> AssistantContext? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return AssistantContext(
            title: "“\(line.prefix(48))\(line.count > 48 || text.contains("\n") ? "…" : "")”", reference: text,
            kind: Kind.passage.rawValue, subtitle: L10n.text("Selected in \(bookTitle)"), sourceID: bookID
        )
    }
}

public enum AssistantRoute: Sendable {
    case section(String), settings, sync, importFile, exportCollection, browse(String), review(Int64)
}

/// What the screen on top is about, most specific first. Empty when the
/// screen has nothing to offer; the chat then starts on the section's own
/// context. Screens publish only while visible, and an item (a deck, a book,
/// a note) beats a whole screen whichever order they arrive in — a pushed
/// detail always wins over the list it came from.
public struct AssistantScreenContextKey: PreferenceKey {
    public static var defaultValue: [AssistantContext] { [] }
    public static func reduce(value: inout [AssistantContext], nextValue: () -> [AssistantContext]) {
        let next = nextValue()
        guard !next.isEmpty else { return }
        if !value.isEmpty, next.allSatisfy(\.isScreen), !value.allSatisfy(\.isScreen) { return }
        value = next
    }
}

public extension Array where Element == AssistantContext {
    /// Whether these describe a reader screen, which hides the global entry.
    /// A book chip with a reference is the book's detail page, not the
    /// reader: that page keeps the global entry.
    var isReader: Bool {
        contains { [.chapter, .page, .passage].contains($0.type) || ($0.type == .book && $0.reference.isEmpty) }
    }
}

public struct AssistantSceneNavigation: Sendable {
    public let route: @MainActor @Sendable (AssistantRoute) -> Void
    public let note: @MainActor @Sendable (AssistantCitation) -> Void
    public init(route: @escaping @MainActor @Sendable (AssistantRoute) -> Void = { _ in }, note: @escaping @MainActor @Sendable (AssistantCitation) -> Void = { _ in }) {
        self.route = route; self.note = note
    }
}
private struct AssistantSceneNavigationKey: EnvironmentKey {
    static let defaultValue = AssistantSceneNavigation()
}
/// Opens the scene's assistant with a context — through the root's own
/// presenter, so a screen that hides the global Ask AI entry (the readers)
/// gets the same sheet or floating panel instead of presenting its own.
/// Always equal: the action is stable, and a fresh closure on every root
/// body pass would otherwise invalidate every reader that reads it.
public struct AssistantOpener: Equatable {
    public let open: @MainActor ([AssistantContext]) -> Void
    public init(_ open: @escaping @MainActor ([AssistantContext]) -> Void) { self.open = open }
    public static func == (_: Self, _: Self) -> Bool { true }
}

public extension EnvironmentValues {
    /// `nil` outside the app root (previews, tests): entry points hide.
    @Entry var assistantOpener: AssistantOpener? = nil

    var assistantSceneNavigation: AssistantSceneNavigation {
        get { self[AssistantSceneNavigationKey.self] }
        set { self[AssistantSceneNavigationKey.self] = newValue }
    }
}

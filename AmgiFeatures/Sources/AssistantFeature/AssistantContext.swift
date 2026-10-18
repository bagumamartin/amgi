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
        sourceID = try values.decodeIfPresent(String.self, forKey: .sourceID)
        // Chats saved before chapters and pages were told apart.
        if kind == "reader" { kind = Kind.book.rawValue }
    }

    public var type: Kind { Kind(rawValue: kind) ?? .collection }

    /// Two chips are the same thing when they point at the same item;
    /// re-adding one replaces it rather than stacking a duplicate.
    public var id: String {
        switch type {
        case .collection: "collection"
        case .deck: "deck:\(deckID ?? 0)"
        case .note, .review: "note:\(noteID ?? 0)"
        case .book, .chapter, .page: "\(kind):\(sourceID ?? title)"
        case .passage: "passage:\(sourceID ?? ""):\(reference.prefix(80))"
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
        }
    }

    // MARK: Factories

    public static let collection = AssistantContext(title: L10n.text("Collection"), kind: Kind.collection.rawValue)

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
/// screen has nothing to offer; the chat then starts on the collection.
public struct AssistantScreenContextKey: PreferenceKey {
    public static var defaultValue: [AssistantContext] { [] }
    public static func reduce(value: inout [AssistantContext], nextValue: () -> [AssistantContext]) {
        let next = nextValue()
        if !next.isEmpty { value = next }
    }
}

public extension Array where Element == AssistantContext {
    /// Whether these describe a reader screen, which hides the global entry.
    var isReader: Bool { contains { [.book, .chapter, .page, .passage].contains($0.type) } }
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

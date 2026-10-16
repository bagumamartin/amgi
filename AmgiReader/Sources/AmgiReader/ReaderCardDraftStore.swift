public import Foundation

/// A flashcard being assembled while reading, before it becomes an Anki note.
///
/// Why drafts are not notes: a card's front and back often live pages apart —
/// a term on page 12, its definition on page 14. Writing a note with an empty
/// back into the collection would put a broken card into review and sync, so
/// the half-made card lives here, beside the book's annotations, until it has
/// both sides. Nothing reaches Anki until then.
///
/// Each side keeps the text the user sees and edits (`front`/`back`) *and* the
/// clips it was built from. The clips carry anchors, which is what lets the
/// reader draw a mark on the source text and jump back to it; the text is what
/// becomes the field. Editing the text never loses the anchors.
public struct ReaderCardDraft: Codable, Sendable, Hashable, Identifiable {
    public enum Side: String, Codable, Sendable, Hashable, CaseIterable {
        case front
        case back
    }

    /// One passage taken from the book into a side of the card.
    public struct Clip: Codable, Sendable, Hashable, Identifiable {
        public var id: UUID
        public var excerpt: String
        public var anchor: ReaderSourceAnchor?

        public init(id: UUID = UUID(), excerpt: String, anchor: ReaderSourceAnchor?) {
            self.id = id
            self.excerpt = excerpt
            self.anchor = anchor
        }
    }

    public var id: UUID
    public var bookID: String
    public var front: String
    public var back: String
    public var frontClips: [Clip]
    public var backClips: [Clip]
    public var createdAt: Date
    /// Last time the user acted on this draft. The stack orders by it, so the
    /// card you just touched is the one "Add to Back" targets.
    public var touchedAt: Date

    public init(
        id: UUID = UUID(),
        bookID: String,
        front: String = "",
        back: String = "",
        frontClips: [Clip] = [],
        backClips: [Clip] = [],
        createdAt: Date = .now,
        touchedAt: Date = .now
    ) {
        self.id = id
        self.bookID = bookID
        self.front = front
        self.back = back
        self.frontClips = frontClips
        self.backClips = backClips
        self.createdAt = createdAt
        self.touchedAt = touchedAt
    }

    public func text(_ side: Side) -> String {
        switch side {
        case .front: front
        case .back: back
        }
    }

    public func clips(_ side: Side) -> [Clip] {
        switch side {
        case .front: frontClips
        case .back: backClips
        }
    }

    public func hasContent(_ side: Side) -> Bool {
        !text(side).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A draft becomes a card only with both sides filled.
    public var isComplete: Bool {
        hasContent(.front) && hasContent(.back)
    }

    /// Appends a passage to one side. A second clip on the same side is a
    /// new paragraph, so "definition from p. 14 plus example from p. 15"
    /// reads as two thoughts rather than one run-on line.
    public mutating func append(_ clip: Clip, to side: Side) {
        let excerpt = clip.excerpt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !excerpt.isEmpty else { return }
        var stored = clip
        stored.excerpt = excerpt
        switch side {
        case .front:
            front = Self.joined(front, excerpt)
            frontClips.append(stored)
        case .back:
            back = Self.joined(back, excerpt)
            backClips.append(stored)
        }
        touchedAt = .now
    }

    public mutating func setText(_ text: String, for side: Side) {
        switch side {
        case .front: front = text
        case .back: back = text
        }
        touchedAt = .now
    }

    /// Short label for menus — "Add to Back of “mitochondrial…”".
    public var shortTitle: String {
        let source = hasContent(.front) ? front : back
        let collapsed = ReaderSourceAnchor.normalize(source)
        guard collapsed.count > Self.shortTitleLength else { return collapsed }
        return String(collapsed.prefix(Self.shortTitleLength)) + "…"
    }

    static let shortTitleLength = 24

    private static func joined(_ existing: String, _ addition: String) -> String {
        let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? addition : trimmed + "\n\n" + addition
    }
}

/// Persistent store for card drafts, one JSON file beside `annotations.json`.
///
/// Separate from `ReaderAnnotationStore` because a draft has two sides with
/// any number of anchors each, while an annotation is exactly one anchor. It
/// mirrors that store's shape (profile-scoped library root, atomic writes,
/// corruption tolerated) so the two behave the same on backup and restore.
public actor ReaderCardDraftStore {
    private static let fileName = "card-drafts.json"

    private let rootDirectory: URL
    private let fileURL: URL
    private var draftsByBook: [String: [ReaderCardDraft]] = [:]
    private var isLoaded = false

    public init(libraryRoot: URL) {
        self.rootDirectory = libraryRoot
        self.fileURL = libraryRoot.appendingPathComponent(Self.fileName)
    }

    /// The book's drafts, most recently touched first — the stack order.
    public func drafts(inBook bookID: String) throws -> [ReaderCardDraft] {
        try loadIfNeeded()
        return (draftsByBook[bookID] ?? []).sorted {
            if $0.touchedAt != $1.touchedAt { return $0.touchedAt > $1.touchedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    /// Unfinished-card counts per book, for the library.
    public func draftCounts() throws -> [String: Int] {
        try loadIfNeeded()
        return draftsByBook.mapValues(\.count).filter { $0.value > 0 }
    }

    @discardableResult
    public func save(_ draft: ReaderCardDraft) throws -> ReaderCardDraft {
        try loadIfNeeded()
        var list = draftsByBook[draft.bookID] ?? []
        var stored = draft
        if let index = list.firstIndex(where: { $0.id == draft.id }) {
            stored.createdAt = list[index].createdAt
            list[index] = stored
        } else {
            list.append(stored)
        }
        draftsByBook[draft.bookID] = list
        try persist()
        return stored
    }

    public func delete(id: UUID, inBook bookID: String) throws {
        try loadIfNeeded()
        guard var list = draftsByBook[bookID] else { return }
        list.removeAll { $0.id == id }
        draftsByBook[bookID] = list.isEmpty ? nil : list
        try persist()
    }

    public func deleteAll(inBook bookID: String) throws {
        try loadIfNeeded()
        draftsByBook.removeValue(forKey: bookID)
        try persist()
    }

    private struct Document: Codable {
        var version: Int
        var books: [String: [ReaderCardDraft]]
    }

    private func loadIfNeeded() throws {
        guard !isLoaded else { return }
        defer { isLoaded = true }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        // A corrupt file must not take the reader down; start over instead.
        guard let document = try? decoder.decode(Document.self, from: data) else { return }
        draftsByBook = document.books
    }

    private func persist() throws {
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Document(version: 1, books: draftsByBook))
        try data.write(to: fileURL, options: .atomic)
    }
}

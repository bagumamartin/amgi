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

    /// One passage taken from the book into a side of the card: selected
    /// text, or an area of the page captured as a picture.
    public struct Clip: Codable, Sendable, Hashable, Identifiable {
        public var id: UUID
        public var excerpt: String
        public var anchor: ReaderSourceAnchor?
        /// For an area capture: the picture's file name in the draft store's
        /// media folder. It moves into the collection's media only when the
        /// card is saved, so an abandoned draft leaves nothing in Anki.
        public var imageFile: String?
        /// For an area capture: where the area was, normalised to 0...1 with
        /// the origin at the top left — of the page, on a PDF; of the block
        /// that holds the area (the anchor's `path`), on a reflowing EPUB
        /// page, so its mark follows that block.
        public var region: ReaderPageRegion?

        public init(
            id: UUID = UUID(),
            excerpt: String,
            anchor: ReaderSourceAnchor?,
            imageFile: String? = nil,
            region: ReaderPageRegion? = nil
        ) {
            self.id = id
            self.excerpt = excerpt
            self.anchor = anchor
            self.imageFile = imageFile
            self.region = region
        }

        public var isImage: Bool { imageFile != nil }
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
    /// The capture's colour, as a hex string. Its marks in the book are drawn
    /// in it, so the colour is how a reader tells one kind of capture from
    /// another at a glance. Nil for drafts made before colours existed; they
    /// draw in the reader default.
    public var colorHex: String?
    /// Set when this draft adds to a card already in the collection rather
    /// than making a new one: the note it adds to. Its sides then hold only
    /// what is being added, and saving appends them to that note's fields.
    public var noteID: Int64?
    /// That card's front and back as they were when it was docked, as plain
    /// text, so the dock can say which card is being added to.
    public var existingFront: String?
    public var existingBack: String?

    public init(
        id: UUID = UUID(),
        bookID: String,
        front: String = "",
        back: String = "",
        frontClips: [Clip] = [],
        backClips: [Clip] = [],
        createdAt: Date = .now,
        touchedAt: Date = .now,
        colorHex: String? = nil,
        noteID: Int64? = nil,
        existingFront: String? = nil,
        existingBack: String? = nil
    ) {
        self.id = id
        self.bookID = bookID
        self.front = front
        self.back = back
        self.frontClips = frontClips
        self.backClips = backClips
        self.createdAt = createdAt
        self.touchedAt = touchedAt
        self.colorHex = colorHex
        self.noteID = noteID
        self.existingFront = existingFront
        self.existingBack = existingBack
    }

    /// Whether this draft adds to a card already in the collection.
    public var addsToExistingCard: Bool { noteID != nil }

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

    /// A side has content when it has text or a captured picture.
    public func hasContent(_ side: Side) -> Bool {
        !text(side).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || clips(side).contains(where: \.isImage)
    }

    /// The pictures on one side, in the order they were captured.
    public func images(_ side: Side) -> [String] {
        clips(side).compactMap(\.imageFile)
    }

    /// A new card needs both sides filled; an addition to an existing card
    /// needs something added to either.
    public var isComplete: Bool {
        if addsToExistingCard { return hasContent(.front) || hasContent(.back) }
        return hasContent(.front) && hasContent(.back)
    }

    /// Appends a passage to one side. A second clip on the same side is a
    /// new paragraph, so "definition from p. 14 plus example from p. 15"
    /// reads as two thoughts rather than one run-on line.
    ///
    /// A picture adds no text: the side's text stays what the reader typed
    /// or selected, and the pictures follow it on the card.
    public mutating func append(_ clip: Clip, to side: Side) {
        let excerpt = clip.excerpt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !excerpt.isEmpty || clip.isImage else { return }
        var stored = clip
        stored.excerpt = excerpt
        switch side {
        case .front:
            if !clip.isImage { front = Self.joined(front, excerpt) }
            frontClips.append(stored)
        case .back:
            if !clip.isImage { back = Self.joined(back, excerpt) }
            backClips.append(stored)
        }
        touchedAt = .now
    }

    /// Takes one clip off the card. A passage's words go from its side's
    /// text too, where they are still as captured; text the reader has since
    /// rewritten is left alone.
    public mutating func removeClip(_ id: UUID) {
        if let clip = frontClips.first(where: { $0.id == id }) {
            front = Self.removing(clip, from: front)
            frontClips.removeAll { $0.id == id }
        }
        if let clip = backClips.first(where: { $0.id == id }) {
            back = Self.removing(clip, from: back)
            backClips.removeAll { $0.id == id }
        }
        touchedAt = .now
    }

    /// Which side a clip is on, if it is on this card.
    public func side(of clipID: UUID) -> Side? {
        if frontClips.contains(where: { $0.id == clipID }) { return .front }
        if backClips.contains(where: { $0.id == clipID }) { return .back }
        return nil
    }

    /// Whether the card has anything on either side.
    public var isEmpty: Bool { !hasContent(.front) && !hasContent(.back) }

    private static func removing(_ clip: Clip, from text: String) -> String {
        guard !clip.isImage, !clip.excerpt.isEmpty, let range = text.range(of: clip.excerpt) else { return text }
        var remaining = text
        remaining.removeSubrange(range)
        while remaining.contains("\n\n\n") {
            remaining = remaining.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return remaining.trimmingCharacters(in: .whitespacesAndNewlines)
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
        if addsToExistingCard, let existing = existingFront.map(ReaderSourceAnchor.normalize), !existing.isEmpty {
            guard existing.count > Self.shortTitleLength else { return existing }
            return String(existing.prefix(Self.shortTitleLength)) + "…"
        }
        let frontText = ReaderSourceAnchor.normalize(front)
        let backText = ReaderSourceAnchor.normalize(back)
        if frontText.isEmpty, backText.isEmpty, !(frontClips + backClips).filter(\.isImage).isEmpty {
            return "Picture"
        }
        let source = frontText.isEmpty ? back : front
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

/// An area of a page, normalised to 0...1 with the origin at the top left.
public struct ReaderPageRegion: Codable, Sendable, Hashable {
    /// The page: a PDF page index, or the EPUB page within its chapter at the
    /// time of capture.
    public var page: Int
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(page: Int, x: Double, y: Double, width: Double, height: Double) {
        self.page = page
        self.x = x
        self.y = y
        self.width = width
        self.height = height
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
        self.mediaDirectory = libraryRoot.appendingPathComponent(Self.mediaFolderName, isDirectory: true)
    }

    private static let mediaFolderName = "card-draft-media"

    /// Where drafts keep their captured pictures until they become cards.
    public nonisolated let mediaDirectory: URL

    public nonisolated func imageURL(_ name: String) -> URL {
        mediaDirectory.appendingPathComponent(name)
    }

    /// Keeps a captured picture for a draft and returns its file name.
    public func saveImage(_ data: Data, fileExtension: String = "png") throws -> String {
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        let name = "\(UUID().uuidString).\(fileExtension)"
        try data.write(to: imageURL(name), options: .atomic)
        return name
    }

    /// Deletes pictures no draft refers to any more — left by drafts that
    /// were saved or discarded. Run when a book opens, never while an undo
    /// could still bring a draft back.
    public func sweepUnusedImages() throws {
        try loadIfNeeded()
        let used = Set(draftsByBook.values.joined().flatMap { ($0.frontClips + $0.backClips).compactMap(\.imageFile) })
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: mediaDirectory.path) else { return }
        for name in names where !used.contains(name) {
            try? manager.removeItem(at: imageURL(name))
        }
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

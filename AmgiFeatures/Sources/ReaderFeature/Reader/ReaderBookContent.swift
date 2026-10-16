import AmgiReader
import AnkiClients
import Dependencies

extension ReaderBook {
    /// An Anki-deck book from the shelf: its chapters are listed, but their
    /// text has not been read yet. Loaded books never have an empty chapter —
    /// the engine skips notes with no content.
    var needsChapterContent: Bool {
        guard case .ankiDeck = source else { return false }
        return chapters.contains { $0.content.isEmpty }
    }
}

/// Reads an Anki-deck book's chapter text when it is opened. The shelf loads
/// outlines only, so this is the one place chapter text crosses the bridge.
enum ReaderBookContent {
    /// The book with its chapter text, or nil if it could not be read.
    @MainActor
    static func load(_ book: ReaderBook) async -> ReaderBook? {
        guard book.needsChapterContent else { return book }
        guard let configuration = ReaderConfigurationLoader.loadConfiguration() else { return nil }
        @Dependency(\.readerBookClient) var client
        return try? await client.loadContent(book, configuration)
    }
}

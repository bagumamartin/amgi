public import AmgiReader
public import Dependencies
import DependenciesMacros

@DependencyClient
public struct ReaderBookClient: Sendable {
    /// Every book in the reader deck as an outline: chapters carry titles and
    /// order but an empty `content`. Cheap enough for the shelf.
    public var loadBooks: @Sendable (_ configuration: ReaderLibraryConfiguration) async throws -> [ReaderBook]
    /// One book, chapter text included.
    public var loadBook: @Sendable (_ bookID: String, _ configuration: ReaderLibraryConfiguration) async throws -> ReaderBook?
    /// Fills in the chapter text of an outline from `loadBooks`.
    public var loadContent: @Sendable (_ book: ReaderBook, _ configuration: ReaderLibraryConfiguration) async throws -> ReaderBook
}

extension ReaderBookClient: TestDependencyKey {
    public static let testValue = ReaderBookClient()
}

extension DependencyValues {
    public var readerBookClient: ReaderBookClient {
        get { self[ReaderBookClient.self] }
        set { self[ReaderBookClient.self] = newValue }
    }
}

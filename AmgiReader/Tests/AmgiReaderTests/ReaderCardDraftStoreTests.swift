import Foundation
import Testing
@testable import AmgiReader

/// Cards being assembled while reading. What these lock down is what a
/// reader would lose sleep over: a draft that vanishes between sessions, a
/// card saved with an empty side, or the stack forgetting which card is next.
@Suite("Reader card drafts")
struct ReaderCardDraftStoreTests {
    private func makeScratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AmgiCardDrafts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func clip(_ text: String, cfi: Int = 10) -> ReaderCardDraft.Clip {
        .init(excerpt: text, anchor: ReaderSourceAnchor(bookID: "b", chapterID: 1, cfi: cfi, quote: text))
    }

    @Test("a draft is complete only with both sides filled")
    func completeness() {
        var draft = ReaderCardDraft(bookID: "b")
        #expect(!draft.isComplete)
        draft.append(clip("uncoupling"), to: .front)
        #expect(!draft.isComplete)
        draft.append(clip("   "), to: .back)
        #expect(!draft.isComplete, "whitespace is not an answer")
        draft.append(clip("heat instead of ATP"), to: .back)
        #expect(draft.isComplete)
    }

    @Test("a second clip on a side becomes a new paragraph and keeps its anchor")
    func appendingKeepsAnchors() {
        var draft = ReaderCardDraft(bookID: "b")
        draft.append(clip("definition", cfi: 1), to: .back)
        draft.append(clip("example", cfi: 2), to: .back)
        #expect(draft.back == "definition\n\nexample")
        #expect(draft.backClips.compactMap(\.anchor?.cfi) == [1, 2])
    }

    @Test("short titles are trimmed for menus")
    func shortTitle() {
        var draft = ReaderCardDraft(bookID: "b")
        draft.append(clip("A rather long front that will not fit in a menu"), to: .front)
        #expect(draft.shortTitle.hasSuffix("…"))
        #expect(draft.shortTitle.count == ReaderCardDraft.shortTitleLength + 1)
    }

    @Test("drafts survive a relaunch, most recently touched first")
    func persistsInStackOrder() async throws {
        let root = try makeScratch()
        let store = ReaderCardDraftStore(libraryRoot: root)
        let older = ReaderCardDraft(bookID: "b", front: "older", touchedAt: .now.addingTimeInterval(-60))
        let newer = ReaderCardDraft(bookID: "b", front: "newer", touchedAt: .now)
        try await store.save(older)
        try await store.save(newer)
        try await store.save(ReaderCardDraft(bookID: "other", front: "elsewhere"))

        let reopened = ReaderCardDraftStore(libraryRoot: root)
        #expect(try await reopened.drafts(inBook: "b").map(\.front) == ["newer", "older"])
        #expect(try await reopened.draftCounts() == ["b": 2, "other": 1])
    }

    @Test("deleting one draft leaves the rest")
    func deleteOne() async throws {
        let store = ReaderCardDraftStore(libraryRoot: try makeScratch())
        let keep = ReaderCardDraft(bookID: "b", front: "keep")
        let drop = ReaderCardDraft(bookID: "b", front: "drop")
        try await store.save(keep)
        try await store.save(drop)
        try await store.delete(id: drop.id, inBook: "b")
        #expect(try await store.drafts(inBook: "b").map(\.id) == [keep.id])
    }

    @Test("a corrupt file starts over instead of failing the reader")
    func corruptFileIsTolerated() async throws {
        let root = try makeScratch()
        try Data("not json".utf8).write(to: root.appendingPathComponent("card-drafts.json"))
        let store = ReaderCardDraftStore(libraryRoot: root)
        #expect(try await store.drafts(inBook: "b").isEmpty)
        try await store.save(ReaderCardDraft(bookID: "b", front: "fresh"))
        #expect(try await store.drafts(inBook: "b").count == 1)
    }
}

import Foundation
import Testing
@testable import AmgiReader

/// Captured areas and capture colours on drafts. What these lock down: a
/// picture fills a side on its own, it never edits the side's text, drafts
/// written before colours and pictures existed still load, and the pictures
/// a draft keeps are cleaned up only once nothing refers to them.
@Suite("Reader card draft captures")
struct ReaderCardDraftCaptureTests {
    private func makeScratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AmgiCardCaptures-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func picture(_ name: String = "a.png") -> ReaderCardDraft.Clip {
        .init(
            excerpt: "",
            anchor: ReaderSourceAnchor(bookID: "b", cfi: 4, quote: ""),
            imageFile: name,
            region: ReaderPageRegion(page: 4, x: 0.1, y: 0.2, width: 0.5, height: 0.3)
        )
    }

    @Test("a picture fills a side without touching its text")
    func pictureFillsSide() {
        var draft = ReaderCardDraft(bookID: "b")
        draft.append(.init(excerpt: "Krebs cycle", anchor: nil), to: .front)
        #expect(!draft.isComplete)
        draft.append(picture(), to: .back)
        #expect(draft.isComplete, "a captured diagram is an answer")
        #expect(draft.back.isEmpty, "a picture adds no text to edit")
        #expect(draft.images(.back) == ["a.png"])
    }

    @Test("removing the only picture empties the side again")
    func removingPicture() {
        var draft = ReaderCardDraft(bookID: "b")
        let clip = picture()
        draft.append(clip, to: .front)
        #expect(draft.hasContent(.front))
        draft.removeClip(clip.id)
        #expect(!draft.hasContent(.front))
    }

    @Test("removing a passage takes its words off its side, and only them")
    func removingPassage() {
        var draft = ReaderCardDraft(bookID: "b")
        let first = ReaderCardDraft.Clip(excerpt: "definition", anchor: nil)
        let second = ReaderCardDraft.Clip(excerpt: "example", anchor: nil)
        draft.append(first, to: .back)
        draft.append(second, to: .back)
        #expect(draft.side(of: first.id) == .back)
        draft.removeClip(first.id)
        #expect(draft.back == "example")
        #expect(draft.backClips.map(\.id) == [second.id])
        #expect(draft.side(of: first.id) == nil)
    }

    @Test("a passage the reader rewrote leaves the text alone")
    func removingRewrittenPassage() {
        var draft = ReaderCardDraft(bookID: "b")
        let clip = ReaderCardDraft.Clip(excerpt: "mitochondria", anchor: nil)
        draft.append(clip, to: .front)
        draft.setText("The powerhouse", for: .front)
        draft.removeClip(clip.id)
        #expect(draft.front == "The powerhouse")
        #expect(!draft.isEmpty)
    }

    @Test("an addition to a saved card is ready with either side, and named after it")
    func additionReadiness() {
        var draft = ReaderCardDraft(bookID: "b", noteID: 42, existingFront: "Krebs cycle", existingBack: "…")
        #expect(draft.addsToExistingCard)
        #expect(!draft.isComplete, "nothing added yet")
        draft.append(.init(excerpt: "also called the citric acid cycle", anchor: nil), to: .back)
        #expect(draft.isComplete)
        #expect(draft.shortTitle == "Krebs cycle")
    }

    @Test("a draft that is only pictures is titled as one")
    func pictureTitle() {
        var draft = ReaderCardDraft(bookID: "b")
        draft.append(picture(), to: .front)
        #expect(draft.shortTitle == "Picture")
    }

    @Test("drafts saved before colours and pictures still load")
    func oldDraftsDecode() throws {
        let json = """
        {"id":"\(UUID().uuidString)","bookID":"b","front":"term","back":"","frontClips":[{"id":"\(UUID().uuidString)","excerpt":"term"}],"backClips":[],"createdAt":0,"touchedAt":0}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let draft = try decoder.decode(ReaderCardDraft.self, from: Data(json.utf8))
        #expect(draft.colorHex == nil)
        #expect(draft.frontClips.first?.imageFile == nil)
        #expect(draft.frontClips.first?.region == nil)
    }

    @Test("colour and pictures survive a round trip through the store")
    func roundTrip() async throws {
        let root = try makeScratch()
        let store = ReaderCardDraftStore(libraryRoot: root)
        var draft = ReaderCardDraft(bookID: "b", colorHex: "#70DB70")
        draft.append(picture("fig.png"), to: .front)
        try await store.save(draft)

        let reopened = ReaderCardDraftStore(libraryRoot: root)
        let loaded = try #require(try await reopened.drafts(inBook: "b").first)
        #expect(loaded.colorHex == "#70DB70")
        #expect(loaded.frontClips.first?.imageFile == "fig.png")
        #expect(loaded.frontClips.first?.region == ReaderPageRegion(page: 4, x: 0.1, y: 0.2, width: 0.5, height: 0.3))
    }

    @Test("the sweep keeps pictures a draft uses and deletes the rest")
    func sweep() async throws {
        let root = try makeScratch()
        let store = ReaderCardDraftStore(libraryRoot: root)
        let kept = try await store.saveImage(Data([1, 2, 3]))
        let orphan = try await store.saveImage(Data([4, 5, 6]))
        var draft = ReaderCardDraft(bookID: "b")
        draft.append(picture(kept), to: .front)
        try await store.save(draft)

        try await store.sweepUnusedImages()

        let manager = FileManager.default
        #expect(manager.fileExists(atPath: store.imageURL(kept).path))
        #expect(!manager.fileExists(atPath: store.imageURL(orphan).path))
    }
}

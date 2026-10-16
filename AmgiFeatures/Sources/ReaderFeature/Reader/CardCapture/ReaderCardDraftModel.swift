import AmgiAppCore
import AmgiReader
import Foundation
import Observation

/// The book's stack of unfinished cards, frontmost first.
///
/// More than one is allowed on purpose: a card started on page 12 may wait two
/// hundred pages for its answer while three others are made and finished in
/// between. What keeps that from becoming a junk drawer is that every draft is
/// anchored in the book (drawn as a hollow mark) and listed with the book's
/// annotations — never a hidden queue.
@Observable
@MainActor
final class ReaderCardDraftModel {
    private(set) var drafts: [ReaderCardDraft] = []
    var errorMessage: String?

    private var store: ReaderCardDraftStore?
    private(set) var bookID: String?

    /// The draft "Add to Back" targets and the dock shows.
    var frontmost: ReaderCardDraft? { drafts.first }

    func draft(_ id: UUID) -> ReaderCardDraft? {
        drafts.first { $0.id == id }
    }

    /// Drafts live beside the book's annotations, so they follow the profile
    /// the same way. Resolved per load so a profile switch is picked up.
    static func makeStore() -> ReaderCardDraftStore {
        ReaderCardDraftStore(
            libraryRoot: AccountStore.profileDirectory(for: AccountStore.shared.selectedID)
                .appendingPathComponent("EPUB", isDirectory: true)
        )
    }

    func load(bookID: String) async {
        if self.bookID != bookID || store == nil {
            store = Self.makeStore()
            self.bookID = bookID
        }
        await reload()
    }

    private func reload() async {
        guard let store, let bookID else { return }
        do {
            drafts = try await store.drafts(inBook: bookID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    var menuContext: ReaderCardMenuContext {
        ReaderCardMenuContext(
            drafts: drafts.map { .init(id: $0.id, title: $0.shortTitle) }
        )
    }

    // MARK: - Mutations

    /// Starts a card with `clip` on its front and puts it on top of the stack.
    @discardableResult
    func start(with clip: ReaderCardDraft.Clip, on side: ReaderCardDraft.Side = .front) async -> ReaderCardDraft? {
        guard let bookID else { return nil }
        var draft = ReaderCardDraft(bookID: bookID)
        draft.append(clip, to: side)
        guard draft.hasContent(side) else { return nil }
        return await persist(draft)
    }

    /// Adds a passage to one side of an existing draft and brings it forward.
    @discardableResult
    func add(_ clip: ReaderCardDraft.Clip, to id: UUID, side: ReaderCardDraft.Side) async -> ReaderCardDraft? {
        guard var draft = draft(id) else { return nil }
        draft.append(clip, to: side)
        return await persist(draft)
    }

    func update(_ id: UUID, front: String, back: String) async {
        guard var draft = draft(id),
              draft.front != front || draft.back != back else { return }
        draft.setText(front, for: .front)
        draft.setText(back, for: .back)
        await persist(draft)
    }

    func bringToFront(_ id: UUID) async {
        guard var draft = draft(id), drafts.first?.id != id else { return }
        draft.touchedAt = .now
        await persist(draft)
    }

    /// Steps through the stack like the home-bar app switcher: forward sends
    /// the frontmost card to the back, backward brings the last one forward.
    func cycle(forward: Bool) async {
        guard drafts.count > 1 else { return }
        if forward, var front = drafts.first, let last = drafts.last {
            front.touchedAt = last.touchedAt.addingTimeInterval(-1)
            await persist(front)
        } else if var last = drafts.last {
            last.touchedAt = .now
            await persist(last)
        }
    }

    /// Takes a draft off the stack and returns it, for saving or discarding.
    @discardableResult
    func remove(_ id: UUID) async -> ReaderCardDraft? {
        guard let store, let bookID, let draft = draft(id) else { return nil }
        do {
            try await store.delete(id: id, inBook: bookID)
        } catch {
            errorMessage = error.localizedDescription
        }
        await reload()
        return draft
    }

    /// Puts a removed draft back, as it was — the undo for save and discard.
    func restore(_ draft: ReaderCardDraft) async {
        var restored = draft
        restored.touchedAt = .now
        await persist(restored)
    }

    @discardableResult
    private func persist(_ draft: ReaderCardDraft) async -> ReaderCardDraft? {
        guard let store else { return nil }
        do {
            let saved = try await store.save(draft)
            await reload()
            return saved
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    // MARK: - Page bridge

    /// Hollow marks for every draft clip in a chapter. The mark id is the
    /// *draft* id, so a tap on any of its passages resumes that draft.
    func markDescriptors(chapterID: Int64) -> [[String: Any]] {
        drafts.flatMap { draft in
            (draft.frontClips + draft.backClips).compactMap { clip -> [String: Any]? in
                guard let anchor = clip.anchor,
                      anchor.chapterID == chapterID,
                      let start = anchor.cfi else { return nil }
                return [
                    "id": draft.id.uuidString,
                    "kind": "cardDraft",
                    "start": start,
                    "end": start + max(1, clip.excerpt.count),
                    "text": clip.excerpt,
                ]
            }
        }
    }
}

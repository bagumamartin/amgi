import AmgiReader
import AnkiBackend
import AnkiClients
import AnkiKit
import AnkiServices
import Dependencies
import Foundation
import Observation

/// A transient message over the reader: "Added to Spanish · Undo".
struct ReaderCardToast: Identifiable, Equatable {
    enum Undo: Equatable {
        /// A saved card: delete the note, erase its marks, and — when it came
        /// from a draft — put the draft back on the stack.
        case saved(noteID: NoteID, draft: ReaderCardDraft?, markIDs: [UUID])
        case discarded(ReaderCardDraft)
    }

    let id = UUID()
    let message: String
    var systemImage: String = "checkmark.circle.fill"
    var undo: Undo?
}

/// Everything card creation does while a book is open, behind one object the
/// reader view talks to: the draft stack, the note writes, the marks those
/// leave in the book, and the undo for each.
///
/// The view stays a composer of chrome; every rule about *when* a card is
/// saved lives here, where it can be read in one place.
@Observable
@MainActor
final class ReaderCardSession {
    let capture = ReaderCardCapture()
    let drafts = ReaderCardDraftModel()

    private(set) var destination: ReaderCardDestination?
    var toast: ReaderCardToast?
    /// The draft open in the refine sheet.
    var editingDraftID: UUID?
    /// A finished card opened from its mark.
    var openedNote: OpenedNote?
    /// Bumped on each event, to drive haptics from the view.
    private(set) var savedCount = 0
    private(set) var clippedCount = 0

    struct OpenedNote: Identifiable {
        var id: Int64 { note.id.rawValue }
        let note: NoteRecord
    }

    @ObservationIgnored private var annotations: ReaderAnnotationModel?
    @ObservationIgnored private var book: ReaderBook?
    @ObservationIgnored private var toastDismissal: Task<Void, Never>?
    /// Called after anything that changes what the page should draw.
    @ObservationIgnored var onMarksChanged: (() -> Void)?
    /// Called after a card is written, with the chapter it came from, so the
    /// book detail screen's per-chapter counts stay live.
    @ObservationIgnored var onCardAdded: ((Int64?) -> Void)?

    @ObservationIgnored @Dependency(\.notesService) private var notesService

    func attach(book: ReaderBook, annotations: ReaderAnnotationModel) async {
        self.book = book
        self.annotations = annotations
        await drafts.load(bookID: book.id)
        destination = await capture.destination(forBook: book.id)
    }

    var destinationDeckName: String? {
        destination.flatMap { capture.deckName($0.deckID) }
    }

    func setDestination(_ destination: ReaderCardDestination) {
        self.destination = destination
        capture.setDestination(destination, forBook: book?.id)
    }

    // MARK: - Selection commands

    /// Runs a card command from the selection menu.
    ///
    /// The rule that makes the split-card flow feel like one gesture: when a
    /// clip *completes* a draft — its back was empty and now is not, or the
    /// other way round — the card saves on the spot. A clip that only adds to
    /// a side already filled keeps the draft open for more.
    func handle(_ command: ReaderCardMenuCommand, payload: ReaderSelectionPayload, chapterID: Int64?) async {
        let clip = Self.clip(from: payload, bookID: book?.id ?? "", chapterID: chapterID)
        switch command {
        case .newCard:
            guard await drafts.start(with: clip) != nil else { return }
            clippedCount += 1
        case .add(let id, let side):
            let wasComplete = drafts.draft(id)?.isComplete ?? false
            guard let updated = await drafts.add(clip, to: id, side: side) else { return }
            clippedCount += 1
            if !wasComplete && updated.isComplete {
                await save(id)
                return
            }
        }
        onMarksChanged?()
    }

    /// Text dropped on a docked card goes to that card's back — a waiting card
    /// is waiting for its answer — and saves it if that completes it, exactly
    /// as "Add to Back" would.
    ///
    /// A drop carries only text. When it is the reader's live selection, that
    /// selection's anchor is kept, so the answer is marked in the book like any
    /// other clip; anything else falls back to a quote-only anchor.
    func drop(_ text: String, on id: UUID, selection: ReaderSelectionPayload?) async {
        let dropped = ReaderSourceAnchor.normalize(text)
        guard !dropped.isEmpty else { return }
        let payload: ReaderSelectionPayload
        if let selection, ReaderSourceAnchor.normalize(selection.text) == dropped {
            payload = selection
        } else {
            payload = ReaderSelectionPayload(text: text, token: text, sentence: text, anchor: nil)
        }
        await handle(.add(draftID: id, side: .back), payload: payload, chapterID: payload.anchor?.chapterID)
    }

    /// A selection made by dragging handles normally carries an anchor; when
    /// it does not, a quote-only one still re-anchors by text search later.
    static func clip(from payload: ReaderSelectionPayload, bookID: String, chapterID: Int64?) -> ReaderCardDraft.Clip {
        let anchor = payload.anchor ?? ReaderSourceAnchor(
            bookID: bookID,
            chapterID: chapterID,
            quote: ReaderSourceAnchor.normalize(payload.text)
        )
        return ReaderCardDraft.Clip(excerpt: payload.text, anchor: anchor)
    }

    // MARK: - Saving and discarding

    func save(_ id: UUID) async {
        guard let draft = drafts.draft(id) else { return }
        guard draft.isComplete else {
            // Never a silent no-op: open the card so the empty side is
            // obvious and fillable.
            editingDraftID = id
            return
        }
        guard let destination = await resolvedDestination() else {
            editingDraftID = id
            showToast(.init(message: "Choose a deck for this book’s cards", systemImage: "tray"))
            return
        }
        await drafts.remove(id)
        do {
            let noteID = try await capture.addCard(
                front: draft.front,
                back: draft.back,
                tags: tags(for: draft),
                destination: destination
            )
            let sources = (draft.frontClips + draft.backClips).compactMap { clip in
                clip.anchor.map { (anchor: $0, excerpt: clip.excerpt) }
            }
            let markIDs = await annotations?.addCardMarks(
                in: draft.bookID,
                sources: sources,
                noteID: noteID.rawValue
            ) ?? []
            savedCount += 1
            onMarksChanged?()
            onCardAdded?(Self.sourceChapterID(of: draft))
            showToast(.init(
                message: "Added to \(capture.deckName(destination.deckID) ?? "Anki")",
                undo: .saved(noteID: noteID, draft: draft, markIDs: markIDs)
            ))
        } catch {
            await drafts.restore(draft)
            showToast(.init(message: "Couldn’t add card", systemImage: "exclamationmark.triangle"))
        }
    }

    func discard(_ id: UUID) async {
        guard let draft = await drafts.remove(id) else { return }
        if editingDraftID == id { editingDraftID = nil }
        onMarksChanged?()
        showToast(.init(message: "Draft discarded", systemImage: "trash", undo: .discarded(draft)))
    }

    func undo(_ toast: ReaderCardToast) async {
        dismissToast()
        switch toast.undo {
        case .saved(let noteID, let draft, let markIDs):
            await capture.remove(noteID)
            if let book { await annotations?.deleteAnnotations(markIDs, inBook: book.id) }
            if let draft { await drafts.restore(draft) }
        case .discarded(let draft):
            await drafts.restore(draft)
        case nil:
            return
        }
        onMarksChanged?()
    }

    // MARK: - One-tap captures from the dictionary

    func recordLookupCard(noteID: NoteID, anchor: ReaderSourceAnchor?, term: String) async {
        guard let book, let anchor else { return }
        await annotations?.addCardMarks(in: book.id, sources: [(anchor, term)], noteID: noteID.rawValue)
        onMarksChanged?()
    }

    func removeLookupCard(noteID: NoteID) async {
        guard let book, let annotations else { return }
        await annotations.deleteAnnotations(annotations.cardMarkIDs(forNote: noteID.rawValue), inBook: book.id)
        onMarksChanged?()
    }

    // MARK: - Marks

    /// A tap on a hollow mark resumes its draft; a tap on a solid one opens
    /// the card it became.
    func markTapped(id: String, kind: String) async {
        switch kind {
        case "cardDraft":
            guard let uuid = UUID(uuidString: id) else { return }
            await drafts.bringToFront(uuid)
            clippedCount += 1
        case "card":
            guard let uuid = UUID(uuidString: id),
                  let mark = annotations?.cards.first(where: { $0.id == uuid }),
                  let raw = ReaderAnnotationModel.noteID(fromCardTag: mark.note) else { return }
            let notes = notesService
            let noteID = NoteID(rawValue: raw)
            if let note = try? await backendOffload({ try notes.getNote(noteID) }) {
                openedNote = OpenedNote(note: note)
            } else {
                // The note was deleted in Browse; its marks are stale.
                if let book, let annotations {
                    await annotations.deleteAnnotations(annotations.cardMarkIDs(forNote: raw), inBook: book.id)
                }
                onMarksChanged?()
            }
        default:
            break
        }
    }

    // MARK: - Helpers

    private func resolvedDestination() async -> ReaderCardDestination? {
        if let destination { return destination }
        destination = await capture.destination(forBook: book?.id)
        return destination
    }

    /// Source tags match the dictionary path's, so the book detail screen
    /// counts these cards per chapter the same way.
    func tags(for draft: ReaderCardDraft) -> [String] {
        guard let book else { return [] }
        var tags = ["amgi::book::\(book.id)"]
        if let chapterID = Self.sourceChapterID(of: draft),
           let index = book.chapters.firstIndex(where: { $0.id == chapterID }) {
            tags.append("amgi::book::\(book.id)::ch::\(index)")
        }
        return tags
    }

    static func sourceChapterID(of draft: ReaderCardDraft) -> Int64? {
        (draft.frontClips + draft.backClips).lazy.compactMap(\.anchor?.chapterID).first
    }

    func chapterTitle(for anchor: ReaderSourceAnchor?) -> String? {
        guard let chapterID = anchor?.chapterID,
              let index = book?.chapters.firstIndex(where: { $0.id == chapterID }) else { return nil }
        return "Ch. \(index + 1)"
    }

    func showToast(_ toast: ReaderCardToast) {
        toastDismissal?.cancel()
        self.toast = toast
        toastDismissal = Task { [weak self] in
            try? await Task.sleep(for: .seconds(toast.undo == nil ? 2.5 : 4))
            guard !Task.isCancelled else { return }
            self?.dismissToast()
        }
    }

    func dismissToast() {
        toastDismissal?.cancel()
        toast = nil
    }
}

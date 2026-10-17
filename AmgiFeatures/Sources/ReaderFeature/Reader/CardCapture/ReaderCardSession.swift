import AmgiReader
import AnkiBackend
import AnkiClients
import AnkiKit
import AnkiServices
import CoreGraphics
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
        /// Card marks taken off the page: put them back as they were.
        case marksRemoved([ReaderAnnotation])
        /// Passages added to an existing card: put its fields back, erase
        /// the new marks, and return the addition to the dock.
        case appended(noteID: NoteID, previousFields: String, draft: ReaderCardDraft, markIDs: [UUID])
    }

    let id = UUID()
    let message: String
    var systemImage: String = "checkmark.circle.fill"
    var undo: Undo?
}

/// An area of the page captured as a picture, ready to become a clip.
struct ReaderRegionCapture: Sendable {
    /// PNG bytes.
    let image: Data
    /// Where it came from: the page (PDF) or the element it covered (EPUB).
    let anchor: ReaderSourceAnchor
    let region: ReaderPageRegion
}

/// One capture as a book's highlights list shows it: a saved card or a
/// draft, with its passages and pictures and where it starts.
struct ReaderCaptureListing: Identifiable {
    enum Kind { case card, draft }

    let id: String
    let kind: Kind
    /// The first passage.
    let quote: String
    /// Another passage of the same card — usually its answer.
    let secondary: String?
    let images: [URL]
    let colorHex: String
    /// Where it starts in the book.
    let anchor: ReaderSourceAnchor?
}

/// The menu on a tapped capture mark, and what it acts on.
struct ReaderMarkMenu: Identifiable, Equatable {
    enum Target: Equatable {
        /// A saved card's mark, and the note it belongs to.
        case card(markID: UUID, noteID: Int64)
        /// A draft's mark: the draft, and the passage tapped when known.
        case draft(draftID: UUID, clipID: UUID?)
    }

    let id = UUID()
    let target: Target
    /// Where the mark was tapped, in window coordinates; zero when unknown.
    let point: CGPoint
    var colour: PDFAnnotationColour
    /// The card has a passage elsewhere to go to.
    let hasOtherPassage: Bool

    var isCard: Bool {
        if case .card = target { return true }
        return false
    }
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
    /// The colour new captures in this book take. Sticks until changed.
    private(set) var captureColour: PDFAnnotationColour = .captureDefault
    var toast: ReaderCardToast?
    /// The draft open in the refine sheet.
    var editingDraftID: UUID?
    /// A finished card opened from its mark.
    var openedNote: OpenedNote?
    /// The menu open on a tapped capture mark.
    var markMenu: ReaderMarkMenu?
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
    /// Takes the reader to a passage — set by the reader that owns the page.
    @ObservationIgnored var onGoTo: ((ReaderSourceAnchor) -> Void)?
    /// Called after a card is written, with the chapter it came from, so the
    /// book detail screen's per-chapter counts stay live.
    @ObservationIgnored var onCardAdded: ((Int64?) -> Void)?

    @ObservationIgnored @Dependency(\.notesService) private var notesService
    @ObservationIgnored @Dependency(\.mediaClient) private var mediaClient

    func attach(book: ReaderBook, annotations: ReaderAnnotationModel) async {
        self.book = book
        self.annotations = annotations
        captureColour = ReaderCaptureColourMemory.colour(forBook: book.id)
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

    // MARK: - Colour

    /// The colour for the captures that follow, in this book.
    func setCaptureColour(_ colour: PDFAnnotationColour) {
        captureColour = colour
        ReaderCaptureColourMemory.remember(colour, forBook: book?.id)
    }

    /// Recolours one draft. Choosing a colour is choosing it for what comes
    /// next too, so it becomes the book's colour as well.
    func setColour(_ colour: PDFAnnotationColour, forDraft id: UUID) async {
        setCaptureColour(colour)
        if let noteID = drafts.draft(id)?.noteID {
            // A saved card docked for additions: the card's marks change too.
            await recolourCard(noteID, to: colour)
        } else {
            await drafts.setColour(colour.hex, for: id)
        }
        onMarksChanged?()
    }

    // MARK: - Selection commands

    /// Runs a card command from the selection menu.
    ///
    /// A card with both sides filled stays docked, ready: more can still go
    /// on either side. It is saved by its check, by swiping it down, by
    /// starting the next card, or by leaving the book — so finishing one card
    /// and starting the next is still a single gesture.
    func handle(_ command: ReaderCardMenuCommand, payload: ReaderSelectionPayload, chapterID: Int64?) async {
        let clip = Self.clip(from: payload, bookID: book?.id ?? "", chapterID: chapterID)
        await apply(command, clip: clip)
    }

    /// The same commands for an area of the page captured as a picture.
    func handleRegion(_ command: ReaderCardMenuCommand, capture: ReaderRegionCapture) async {
        guard let name = await drafts.storeImage(capture.image) else {
            showToast(.init(message: "Couldn’t keep that picture", systemImage: "exclamationmark.triangle"))
            return
        }
        let clip = ReaderCardDraft.Clip(excerpt: "", anchor: capture.anchor, imageFile: name, region: capture.region)
        await apply(command, clip: clip)
    }

    /// What an area's bar button means: Front and Back go to the docked card,
    /// or start one when nothing is docked.
    func command(for action: ReaderAreaAction) -> ReaderCardMenuCommand {
        guard let front = drafts.frontmost else { return .newCard }
        switch action {
        case .newCard: return .newCard
        case .front: return .add(draftID: front.id, side: .front)
        case .back: return .add(draftID: front.id, side: .back)
        }
    }

    private func apply(_ command: ReaderCardMenuCommand, clip: ReaderCardDraft.Clip) async {
        switch command {
        case .newCard:
            await saveReadyDrafts()
            await dropIdleAdditions(except: nil)
            guard await drafts.start(with: clip, colorHex: captureColour.hex) != nil else { return }
        case .add(let id, let side):
            guard await drafts.add(clip, to: id, side: side) != nil else { return }
        }
        clippedCount += 1
        onMarksChanged?()
    }

    /// Saves every card whose sides are both filled. Run before a new card
    /// starts and when the reader leaves the book.
    func saveReadyDrafts() async {
        for draft in drafts.drafts where draft.isComplete {
            await save(draft.id)
        }
        await dropIdleAdditions(except: nil)
    }

    /// Text dropped on a docked card goes to that card's back — a waiting card
    /// is waiting for its answer — exactly as "Add to Back" would.
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
        if let noteID = draft.noteID {
            await saveAddition(draft, to: NoteID(rawValue: noteID))
            return
        }
        guard let destination = await resolvedDestination() else {
            editingDraftID = id
            showToast(.init(message: "Choose a deck for this book’s cards", systemImage: "tray"))
            return
        }
        await drafts.remove(id)
        do {
            let frontImages = try await mediaFiles(for: draft.images(.front))
            let backImages = try await mediaFiles(for: draft.images(.back))
            let noteID = try await capture.addCard(
                front: draft.front,
                back: draft.back,
                frontImages: frontImages,
                backImages: backImages,
                tags: tags(for: draft),
                destination: destination
            )
            // Each area's mark keeps the name its picture got in Anki.
            let stored = Dictionary(
                zip(draft.images(.front) + draft.images(.back), frontImages + backImages),
                uniquingKeysWith: { first, _ in first }
            )
            let sources = (draft.frontClips + draft.backClips).compactMap { clip in
                clip.anchor.map {
                    (anchor: $0, excerpt: clip.excerpt, region: clip.region, imageFile: clip.imageFile.flatMap { stored[$0] })
                }
            }
            let markIDs = await annotations?.addCardMarks(
                in: draft.bookID,
                sources: sources,
                noteID: noteID.rawValue,
                colorHex: draft.colorHex ?? PDFAnnotationColour.captureDefault.hex
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

    /// Appends a docked addition to the card it was opened from.
    private func saveAddition(_ draft: ReaderCardDraft, to noteID: NoteID) async {
        await drafts.remove(draft.id)
        do {
            let frontImages = try await mediaFiles(for: draft.images(.front))
            let backImages = try await mediaFiles(for: draft.images(.back))
            let front = draft.hasContent(.front) ? ReaderCardCapture.field(draft.front, images: frontImages) : ""
            let back = draft.hasContent(.back) ? ReaderCardCapture.field(draft.back, images: backImages) : ""
            let previous = try await capture.appendToCard(noteID, front: front, back: back)
            // Each area's mark keeps the name its picture got in Anki.
            let stored = Dictionary(
                zip(draft.images(.front) + draft.images(.back), frontImages + backImages),
                uniquingKeysWith: { first, _ in first }
            )
            let sources = (draft.frontClips + draft.backClips).compactMap { clip in
                clip.anchor.map {
                    (anchor: $0, excerpt: clip.excerpt, region: clip.region, imageFile: clip.imageFile.flatMap { stored[$0] })
                }
            }
            let markIDs = await annotations?.addCardMarks(
                in: draft.bookID,
                sources: sources,
                noteID: noteID.rawValue,
                colorHex: draft.colorHex ?? PDFAnnotationColour.captureDefault.hex
            ) ?? []
            savedCount += 1
            onMarksChanged?()
            showToast(.init(
                message: "Added to the card",
                undo: .appended(noteID: noteID, previousFields: previous, draft: draft, markIDs: markIDs)
            ))
        } catch {
            await drafts.restore(draft)
            showToast(.init(message: "Couldn’t add to that card", systemImage: "exclamationmark.triangle"))
        }
    }

    /// Moves a draft's pictures into the collection's media, returning the
    /// names Anki gave them. Only now, at save: a draft never touches Anki.
    private func mediaFiles(for names: [String]) async throws -> [String] {
        var stored: [String] = []
        for name in names {
            guard let url = drafts.imageURL(name) else { continue }
            let data = try Data(contentsOf: url)
            stored.append(try await mediaClient.addFile("amgi-capture-\(name)", data))
        }
        return stored
    }

    func discard(_ id: UUID) async {
        // A saved card that was only looked at leaves without a fuss: there
        // is nothing to undo.
        if let draft = drafts.draft(id), draft.addsToExistingCard, !draft.isComplete {
            await drafts.remove(id)
            if editingDraftID == id { editingDraftID = nil }
            return
        }
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
        case .marksRemoved(let marks):
            await annotations?.restore(marks)
        case .appended(let noteID, let previousFields, let draft, let markIDs):
            await capture.restoreFields(noteID, to: previousFields)
            if let book { await annotations?.deleteAnnotations(markIDs, inBook: book.id) }
            await drafts.restore(draft)
        case nil:
            return
        }
        onMarksChanged?()
    }

    // MARK: - One-tap captures from the dictionary

    func recordLookupCard(noteID: NoteID, anchor: ReaderSourceAnchor?, term: String) async {
        guard let book, let anchor else { return }
        await annotations?.addCardMarks(
            in: book.id,
            sources: [(anchor, term)],
            noteID: noteID.rawValue,
            colorHex: captureColour.hex
        )
        onMarksChanged?()
    }

    func removeLookupCard(noteID: NoteID) async {
        guard let book, let annotations else { return }
        await annotations.deleteAnnotations(annotations.cardMarkIDs(forNote: noteID.rawValue), inBook: book.id)
        onMarksChanged?()
    }

    // MARK: - Marks

    /// A tap on a capture mark opens its menu, at the mark — colours, open,
    /// go to the card's other passage, remove — and brings the capture to the
    /// front of the dock, ready to take more: a draft as itself, a saved
    /// card as an addition to it.
    func markTapped(id: String, kind: String, at point: CGPoint = .zero) async {
        switch kind {
        case "cardDraft":
            let parts = id.split(separator: ":").map(String.init)
            guard let draftID = parts.first.flatMap(UUID.init(uuidString:)),
                  let draft = drafts.draft(draftID) else { return }
            let clipID = parts.count > 1 ? UUID(uuidString: parts[1]) : nil
            let others = (draft.frontClips + draft.backClips).filter { $0.id != clipID && $0.anchor != nil }
            await dropIdleAdditions(except: draftID)
            await drafts.bringToFront(draftID)
            markMenu = ReaderMarkMenu(
                target: .draft(draftID: draftID, clipID: clipID),
                point: point,
                colour: PDFAnnotationColour(captureHex: draft.colorHex) ?? .captureDefault,
                hasOtherPassage: !others.isEmpty
            )
        case "card":
            guard let uuid = UUID(uuidString: id),
                  let mark = annotations?.cards.first(where: { $0.id == uuid }),
                  let noteID = ReaderAnnotationModel.noteID(fromCardTag: mark.note) else { return }
            let siblings = annotations?.cardMarkIDs(forNote: noteID).filter { $0 != uuid } ?? []
            await dock(noteID: noteID, colorHex: mark.colorHex)
            markMenu = ReaderMarkMenu(
                target: .card(markID: uuid, noteID: noteID),
                point: point,
                colour: PDFAnnotationColour(captureHex: mark.colorHex) ?? .captureDefault,
                hasOtherPassage: !siblings.isEmpty
            )
        default:
            break
        }
    }

    func dismissMarkMenu() { markMenu = nil }

    /// Puts a saved card back in the dock to be added to: what is selected
    /// next goes onto the end of its front or back. Already docked, it just
    /// comes to the front.
    func dock(noteID: Int64, colorHex: String?) async {
        if let docked = drafts.drafts.first(where: { $0.noteID == noteID }) {
            await drafts.bringToFront(docked.id)
            return
        }
        guard let book, let sides = await capture.sides(of: NoteID(rawValue: noteID)) else { return }
        await dropIdleAdditions(except: nil)
        let addition = ReaderCardDraft(
            bookID: book.id,
            colorHex: colorHex,
            noteID: noteID,
            existingFront: sides.front,
            existingBack: sides.back
        )
        await drafts.restore(addition)
    }

    /// A saved card docked for additions that never got any leaves again
    /// once something else takes the front, so the dock does not fill with
    /// cards that were only looked at.
    private func dropIdleAdditions(except keep: UUID?) async {
        for draft in drafts.drafts where draft.addsToExistingCard && !draft.isComplete && draft.id != keep {
            await drafts.remove(draft.id)
        }
    }

    /// Open Card: a saved card's note, or a draft in its sheet. (The tap has
    /// already brought either to the front of the dock.)
    func openMarkTarget(_ menu: ReaderMarkMenu) async {
        markMenu = nil
        switch menu.target {
        case .draft(let draftID, _):
            editingDraftID = draftID
        case .card(_, let noteID):
            let notes = notesService
            let id = NoteID(rawValue: noteID)
            if let note = try? await backendOffload({ try notes.getNote(id) }) {
                openedNote = OpenedNote(note: note)
            } else {
                // The note was deleted in Browse; its marks are stale.
                if let book, let annotations {
                    await annotations.deleteAnnotations(annotations.cardMarkIDs(forNote: noteID), inBook: book.id)
                }
                onMarksChanged?()
                showToast(.init(message: "That card was deleted", systemImage: "trash"))
            }
        }
    }

    /// Recolours the whole capture — every passage of the card or draft — and
    /// not the colour new captures take: this is fixing an old capture.
    func recolourMark(_ menu: ReaderMarkMenu, to colour: PDFAnnotationColour) async {
        markMenu?.colour = colour
        switch menu.target {
        case .draft(let draftID, _):
            await drafts.setColour(colour.hex, for: draftID)
        case .card(_, let noteID):
            await recolourCard(noteID, to: colour)
        }
        onMarksChanged?()
    }

    /// A saved card's colour, everywhere it shows: its marks in the book and
    /// the card itself if it is docked for additions.
    private func recolourCard(_ noteID: Int64, to colour: PDFAnnotationColour) async {
        if let book, let annotations {
            await annotations.setColour(colour.hex, ids: Set(annotations.cardMarkIDs(forNote: noteID)), inBook: book.id)
        }
        for draft in drafts.drafts where draft.noteID == noteID {
            await drafts.setColour(colour.hex, for: draft.id)
        }
    }

    /// Jumps to another passage of the same card: from a question to its
    /// answer, or back.
    func goToOtherPassage(_ menu: ReaderMarkMenu) {
        markMenu = nil
        switch menu.target {
        case .draft(let draftID, let clipID):
            guard let draft = drafts.draft(draftID) else { return }
            let anchor = (draft.frontClips + draft.backClips)
                .first { $0.id != clipID && $0.anchor != nil }?.anchor
            if let anchor { onGoTo?(anchor) }
        case .card(let markID, let noteID):
            guard let annotations else { return }
            let anchor = annotations.cards
                .first { $0.id != markID && $0.note == ReaderAnnotationModel.cardNoteTag(noteID) }?.anchor
            if let anchor { onGoTo?(anchor) }
        }
    }

    /// A draft's passage comes off the draft — the whole draft goes when it
    /// was the last thing on it. A card's mark comes off the page; the card
    /// stays in Anki. Both undo.
    func removeMark(_ menu: ReaderMarkMenu) async {
        markMenu = nil
        switch menu.target {
        case .draft(let draftID, let clipID):
            guard let before = drafts.draft(draftID) else { return }
            var after = before
            if let clipID { after.removeClip(clipID) }
            if clipID == nil || after.isEmpty {
                await drafts.remove(draftID)
                if editingDraftID == draftID { editingDraftID = nil }
                showToast(.init(message: "Draft discarded", systemImage: "trash", undo: .discarded(before)))
            } else {
                await drafts.removeClip(clipID!, from: draftID)
                showToast(.init(message: "Passage removed", systemImage: "eraser", undo: .discarded(before)))
            }
        case .card(_, let noteID):
            // The whole capture, every passage of the card, as recolouring
            // does: taking one passage off left the card's others behind.
            guard let book, let annotations else { return }
            let tag = ReaderAnnotationModel.cardNoteTag(noteID)
            let marks = annotations.cards.filter { $0.note == tag }
            guard !marks.isEmpty else { return }
            await annotations.deleteAnnotations(marks.map(\.id), inBook: book.id)
            await undock(noteID: noteID, keepingAdditions: true)
            showToast(.init(
                message: marks.count == 1 ? "Highlight removed" : "Highlights removed",
                systemImage: "eraser",
                undo: .marksRemoved(marks)
            ))
        }
        onMarksChanged?()
    }

    /// Takes a saved card's addition out of the dock. One with something
    /// already added stays when only the highlight went, since that work is
    /// the reader's; after the card itself is deleted it goes regardless.
    private func undock(noteID: Int64, keepingAdditions: Bool) async {
        for draft in drafts.drafts where draft.noteID == noteID {
            if keepingAdditions && draft.isComplete { continue }
            await drafts.remove(draft.id)
            if editingDraftID == draft.id { editingDraftID = nil }
        }
    }

    /// Deletes the card from Anki along with every mark it left in the book.
    /// Not undoable: a deleted note's review history does not come back.
    func deleteCard(_ menu: ReaderMarkMenu) async {
        markMenu = nil
        guard case .card(_, let noteID) = menu.target, let book, let annotations else { return }
        await capture.remove(NoteID(rawValue: noteID))
        await annotations.deleteAnnotations(annotations.cardMarkIDs(forNote: noteID), inBook: book.id)
        await undock(noteID: noteID, keepingAdditions: false)
        onMarksChanged?()
        showToast(.init(message: "Card deleted", systemImage: "trash"))
    }

    // MARK: - Listing

    /// Every capture in the book, one entry per card or draft rather than per
    /// passage: a card's front and back are one thing to the reader.
    func captureListings() -> [ReaderCaptureListing] {
        var listings: [ReaderCaptureListing] = []
        let marks = annotations?.cards ?? []
        var byNote: [String: [ReaderAnnotation]] = [:]
        for mark in marks { byNote[mark.note ?? mark.id.uuidString, default: []].append(mark) }
        for (key, group) in byNote {
            let ordered = group.sorted { $0.createdAt < $1.createdAt }
            let passages = ordered.map(\.excerpt).map(ReaderSourceAnchor.normalize).filter { !$0.isEmpty }
            listings.append(ReaderCaptureListing(
                id: "card-\(key)",
                kind: .card,
                quote: passages.first ?? "",
                secondary: passages.dropFirst().first,
                images: ordered.compactMap(\.imageFile).compactMap { mediaClient.localURL($0) },
                colorHex: ordered.first?.colorHex ?? PDFAnnotationColour.captureDefault.hex,
                anchor: ordered.first?.anchor
            ))
        }
        for draft in drafts.drafts {
            // A saved card docked only to be looked at is already listed.
            if draft.addsToExistingCard && !draft.isComplete { continue }
            let front = ReaderSourceAnchor.normalize(draft.front)
            let back = ReaderSourceAnchor.normalize(draft.back)
            let clips = draft.frontClips + draft.backClips
            listings.append(ReaderCaptureListing(
                id: "draft-\(draft.id.uuidString)",
                kind: .draft,
                quote: front.isEmpty ? back : front,
                secondary: front.isEmpty || back.isEmpty ? nil : back,
                images: clips.compactMap(\.imageFile).compactMap { drafts.imageURL($0) },
                colorHex: draft.colorHex ?? PDFAnnotationColour.captureDefault.hex,
                anchor: clips.lazy.compactMap(\.anchor).first
            ))
        }
        return listings
    }

    /// A listed capture as the target the mark menu acts on, so the list's
    /// edit, recolour and remove do exactly what the page's menu does.
    func menu(forListing id: String) -> ReaderMarkMenu? {
        if id.hasPrefix("draft-"), let draftID = UUID(uuidString: String(id.dropFirst(6))),
           let draft = drafts.draft(draftID) {
            return ReaderMarkMenu(
                target: .draft(draftID: draftID, clipID: nil),
                point: .zero,
                colour: PDFAnnotationColour(captureHex: draft.colorHex) ?? .captureDefault,
                hasOtherPassage: false
            )
        }
        guard id.hasPrefix("card-") else { return nil }
        let key = String(id.dropFirst(5))
        let marks = (annotations?.cards ?? []).filter { ($0.note ?? $0.id.uuidString) == key }
        guard let first = marks.min(by: { $0.createdAt < $1.createdAt }),
              let noteID = ReaderAnnotationModel.noteID(fromCardTag: first.note) else { return nil }
        return ReaderMarkMenu(
            target: .card(markID: first.id, noteID: noteID),
            point: .zero,
            colour: PDFAnnotationColour(captureHex: first.colorHex) ?? .captureDefault,
            hasOtherPassage: false
        )
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

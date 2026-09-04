import Testing
import Foundation
import AnkiKit
@testable import AnkiProtoBridge
@testable import AnkiBackend

/// Behavioral probes for the Browse bridge surface (browse-redesign-spec
/// §8): every NEW (service, method) pair is fired against a live engine
/// over a scratch collection before any UI rides on it. Catches method-ID
/// drift — a stale constant dispatches some *other* rpc and shows up here
/// as a wrong-shaped result, not a clean failure.
///
/// Runs on macOS (xcframework macOS slice). Scheduling-rule rejections are
/// still valid probe outcomes when they prove correct dispatch: an unknown
/// method yields a dispatch-level failure while engine business rules yield
/// structured `BackendError`s — those get recorded as such.
@Suite("Browse engine probes", .serialized)
struct BrowseEngineProbesTests {
    private struct Scratch {
        let root: URL
        let backend: AnkiBackend
        let noteIDs: [NoteID]
        let cardIDs: [CardID]
    }

    private func openScratch() throws -> Scratch {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("amgi-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(atPath: root.path, withIntermediateDirectories: true)

        let mediaFolder = root.appendingPathComponent("media").path
        try FileManager.default.createDirectory(atPath: mediaFolder, withIntermediateDirectories: true)

        let backend = try AnkiBackend(preferredLangs: ["en"])
        try backend.openCollection(
            collectionPath: root.appendingPathComponent("collection.anki2").path,
            mediaFolderPath: mediaFolder,
            mediaDbPath: root.appendingPathComponent("media.db").path
        )

        let names = try backend.invoke(.notetypeNames)
        guard !names.isEmpty else { throw ProbeError("collection must ship default notetypes") }
        let basicID = (names.first { $0.name == "Basic" } ?? names[0]).id

        for pair in [("DupeFront", "BackOne"), ("DupeFront", "BackTwo"), ("UniqueFront", "BackThree")] {
            try backend.invoke(.addNote(
                template: NewNoteTemplate(notetypeId: basicID, fields: [pair.0, pair.1]),
                deckId: DeckID(1)
            ))
        }

        let noteIDs = try backend.invoke(.searchNoteIds(query: "deck:\"Default\""))
        guard noteIDs.count == 3 else { throw ProbeError("expected 3 notes, got \(noteIDs.count)") }
        let cardIDs = try backend.invoke(.searchCardIds(query: "deck:\"Default\""))
        guard cardIDs.count == 3 else { throw ProbeError("expected 3 cards, got \(cardIDs.count)") }

        return Scratch(root: root, backend: backend, noteIDs: noteIDs, cardIDs: cardIDs)
    }

    private struct ProbeError: Error, CustomStringConvertible {
        let description: String
        init(_ text: String) { description = text }
    }

    @Test func searchCompositionProbes() throws {
        let scratch = try openScratch()
        defer { cleanup(scratch) }
        let backend = scratch.backend

        let built = try backend.invoke(.buildSearchString(query: "deck:* is:new"))
        #expect(!built.isEmpty, "BuildSearchString (29/0) must return canonical text")

        let joined = try backend.invoke(.joinSearchNodes(
            existing: "deck:Default", additional: "is:new", joiner: .and
        ))
        // Canonical AND form is space-joined, no literal "AND".
        #expect(joined.lowercased().contains("default") && joined.lowercased().contains("is:new"),
                "JoinSearchNodes (29/3)")

        let replaced = try backend.invoke(.replaceSearchNode(previous: "is:new", replacement: "is:due"))
        #expect(replaced.lowercased().contains("is:due"), "ReplaceSearchNode (29/4)")

        let columns = try backend.invoke(.allBrowserColumns())
        // Engine keys from rslib browser_table.rs strum serializations.
        #expect(columns.contains { $0.key == "noteCrt" }, "AllBrowserColumns (29/6) exposes noteCrt")
        #expect(columns.contains { $0.key == "noteFld" }, "sort field column key is noteFld")

        let noteOrder = try backend.invoke(.searchNoteIds(
            query: "deck:\"Default\"",
            order: SearchOrder(.builtin(column: "noteCrt", reverse: false))
        ))
        #expect(noteOrder.count == 3, "sorted searchNoteIds")

        let cardOrder = try backend.invoke(.searchCardIds(
            query: "",
            order: SearchOrder(.builtin(column: "noteCrt", reverse: true))
        ))
        #expect(cardOrder.count == 3, "sorted searchCardIds over empty-query rewrite")
    }

    @Test func browserRowProbe() throws {
        let scratch = try openScratch()
        defer { cleanup(scratch) }
        let backend = scratch.backend

        // Engine requires an active column set before rows render.
        let columns = try backend.invoke(.allBrowserColumns())
        try backend.invoke(.setActiveBrowserColumns(columns.map(\.key)))

        let row = try backend.invoke(.browserRowForId(id: scratch.cardIDs[0].rawValue))
        #expect(row.cells.count == columns.count, "BrowserRowForId (29/7) fills every active column")
        #expect(!row.cells.first!.text.isEmpty, "question cell renders non-empty")
    }

    @Test func findDuplicatesExactProbe() throws {
        let scratch = try openScratch()
        defer { cleanup(scratch) }
        let dupes = try scratch.backend.invoke(.findDuplicatesExact(search: "", fieldName: "Front"))
        #expect(dupes.notesScanned == 3)
        #expect(dupes.groups.count == 1, "exactly the two DupeFronts group together")
        let expectedIDs = Set(scratch.noteIDs.prefix(2).map(\.rawValue))
        #expect(Set(dupes.groups.first?.noteIds ?? []) == expectedIDs)
    }

    @Test func mutationProbes() throws {
        let scratch = try openScratch()
        defer { cleanup(scratch) }
        let backend = scratch.backend
        let cardIDs = Array(scratch.cardIDs)

        // Moving to own deck is a success path regardless of reported count.
        _ = try backend.invoke(.setDeck(cardIds: cardIDs, deckId: DeckID(1)))

        // Reposition new cards — SortCards' native domain.
        let repositioned = try backend.invoke(.sortCards(
            cardIds: cardIDs, startingFrom: 100, stepSize: 10,
            randomize: false, shiftExisting: false
        ))
        #expect(repositioned == 3, "SortCards (13/21) repositions new cards")

        // Suspend → observable queue change → undo status populated → restore.
        try backend.invoke(.suspendCards(cardIds: cardIDs, noteIds: []))
        let suspendedCard = try backend.invoke(.getCard(id: cardIDs[0]))
        #expect(suspendedCard.queue == -1, "suspend lands queue -1")

        let statusAfterSuspend = try backend.invoke(.undoStatus)
        #expect(statusAfterSuspend.canUndo, "UndoStatusInfo carries canUndo after mutation")

        try backend.invoke(.restoreBuriedAndSuspendedCards(cardIds: cardIDs))
        let restoredCard = try backend.invoke(.getCard(id: cardIDs[0]))
        #expect(restoredCard.queue != -1, "restore clears suspension")

        // Bury via note ids exercises the note→cards fanout branch.
        try backend.invoke(.buryUserCards(cardIds: [], noteIds: scratch.noteIDs))
        let buriedCard = try backend.invoke(.getCard(id: cardIDs[1]))
        #expect(buriedCard.queue < -1, "user bury occupies negative queues (-2/-3)")
        try backend.invoke(.restoreBuriedAndSuspendedCards(cardIds: cardIDs))
    }

    @Test func schedulingRuleRejectionsReachBusinessLogic() throws {
        let scratch = try openScratch()
        defer { cleanup(scratch) }
        let backend = scratch.backend

        // SetDueDate targets review cards; fresh/new rejections still prove
        // dispatch reaches scheduler logic (unknown-method failures would not).
        if let failure = probe({ try backend.invoke(.setDueDate(cardIds: [scratch.cardIDs[0]], daysExpression: "5-7")) }) {
            Issue.record("SetDueDate: \(failure)")
        }
        if let failure = probe({ try backend.invoke(.gradeNow(cardIds: Array(scratch.cardIDs), rating: .good)) }) {
            Issue.record("GradeNow: \(failure)")
        }
    }

    @Test func undoRedoRoundTripProbe() throws {
        let scratch = try openScratch()
        defer { cleanup(scratch) }
        let backend = scratch.backend

        try backend.invoke(.suspendCards(cardIds: Array(scratch.cardIDs), noteIds: []))

        let before = try backend.invoke(.undoStatus)
        #expect(before.canUndo && !before.undoText.isEmpty)

        try backend.invoke(.undoLastAction)
        let afterUndo = try backend.invoke(.undoStatus)
        #expect(afterUndo.canRedo, "undo makes redo available")
        #expect(!afterUndo.redoText.isEmpty, "redo label text present for toolbar display")

        try backend.invoke(.redoLastAction)
    }

    /// Tolerated-outcome wrapper: rejections by scheduling rules are fine;
    /// anything suggesting bad dispatch ("unknown") is a probe failure.
    private func probe(_ body: () throws -> Void) -> String? {
        do {
            try body()
            return nil
        } catch let error as BackendError {
            let message = error.message.lowercased()
            if message.contains("unknown") || message.contains("invalid method") {
                return "failed with a dispatch-level error: \(error.message)"
            }
            return nil
        } catch {
            return "non-backend failure: \(error)"
        }
    }

    private func cleanup(_ scratch: Scratch) {
        _ = scratch.backend
        try? FileManager.default.removeItem(at: scratch.root)
    }
}

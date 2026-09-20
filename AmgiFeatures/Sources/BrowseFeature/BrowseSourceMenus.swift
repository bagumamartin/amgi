import SwiftUI
import AnkiKit

/// One mass-action pass over a sidebar scope. Sheets are presented by the
/// host; immediate mutations run here after a count confirmation.
struct BrowseSourceBatchMenu: View {
    let source: BrowseSource
    var includeSubdecks: Bool = true
    var model: BrowseModel
    var onPresentSheet: (BrowseView.Sheet, Set<NoteID>, Set<CardID>) -> Void
    var onPresentTagSheet: (Set<NoteID>, Set<CardID>) -> Void
    var onConfirm: (String, String, Bool, @escaping () async -> Void) -> Void

    var body: some View {
        Section("Cards") {
            Button("Suspend") { runCards("Suspend", "pause") { notes, cards in
                await model.suspendSelected(Set(notes), cardIDs: cards)
            } }
            Button("Unsuspend / Unbury") { runCards("Unsuspend", "restore") { notes, cards in
                await model.unSuspendSelected(Set(notes), cardIDs: cards)
            } }
            Button("Bury Until Tomorrow") { runCards("Bury", "bury") { notes, cards in
                await model.burySelected(Set(notes), cardIDs: cards)
            } }
            Menu("Flag") {
                ForEach(flagChoices, id: \.value) { choice in
                    Button("Flag \(choice.name)") {
                        runCards("Flag", "flag") { notes, cards in
                            await model.flagSelected(Set(notes), cardIDs: cards, value: choice.value)
                        }
                    }
                }
                Button("Clear flag") { runCards("Clear flags on", "update") { notes, cards in
                    await model.flagSelected(Set(notes), cardIDs: cards, value: 0)
                } }
            }
            Button("Change Deck…") { presentSheet(.changeDeck) }
            Button("Set Due Date…") { presentSheet(.setDueDate) }
            Button("Forget…") { presentSheet(.forget) }
            Button("Reposition New Cards…") { presentSheet(.reposition) }
        }

        Section("Grade Now") {
            ForEach([(Rating.again, "Again"), (.hard, "Hard"), (.good, "Good"), (.easy, "Easy")],
                    id: \.1) { rating, label in
                Button(label) {
                    runCards("Grade \(label.lowercased())", "grade") { notes, cards in
                        await model.gradeNowSelectedNotes(Set(notes), cardIDs: cards, rating: rating)
                    }
                }
            }
        }

        Section("Notes") {
            Button("Mark") { runNotes("Mark", "mark") { notes, cards in
                await model.toggleMarkSelected(Set(notes), cardIDs: cards)
            } }
            Button("Add Tags…") { presentTags() }
            Button("Remove Tags…") { presentSheet(.removeTags) }
            Button("Create Copy…") { presentSheet(.copyNote) }
            Button("Export…") { presentSheet(.export) }
            Button("Change Note Type…") { presentSheet(.changeNotetype) }
        }

        Section {
            Button("Delete Notes…", role: .destructive) {
                runNotes("Delete", "delete", destructive: true) { notes, _ in
                    await model.deleteSelected(Set(notes))
                }
            }
        }
    }

    private var flagChoices: [(value: UInt32, name: String)] {
        [
            (1, "Red"), (2, "Orange"), (3, "Green"), (4, "Blue"),
            (5, "Pink"), (6, "Turquoise"), (7, "Purple"),
        ]
    }

    private func presentSheet(_ sheet: BrowseView.Sheet) {
        Task {
            let scope = await model.searchScope(source, includeSubdecks: includeSubdecks)
            guard !scope.notes.isEmpty || !scope.cards.isEmpty else {
                model.errorMessage = "Nothing in \(model.title(for: source)) to change."
                return
            }
            onPresentSheet(sheet, Set(scope.notes), Set(scope.cards))
        }
    }

    private func presentTags() {
        Task {
            let scope = await model.searchScope(source, includeSubdecks: includeSubdecks)
            guard !scope.notes.isEmpty else {
                model.errorMessage = "Nothing in \(model.title(for: source)) to tag."
                return
            }
            onPresentTagSheet(Set(scope.notes), Set(scope.cards))
        }
    }

    private func runCards(
        _ verb: String,
        _ noun: String,
        destructive: Bool = false,
        work: @escaping (Set<NoteID>, [CardID]) async -> Void
    ) {
        Task {
            let scope = await model.searchScope(source, includeSubdecks: includeSubdecks)
            let count = scope.cards.count
            guard count > 0 else {
                model.errorMessage = "Nothing in \(model.title(for: source)) to \(noun)."
                return
            }
            let name = model.title(for: source)
            let sub = includeSubdecks && isDeck ? " and its subdecks" : ""
            onConfirm(
                "\(verb) \(count) card\(count == 1 ? "" : "s")?",
                "Applies to \(name)\(sub). You can undo this from More.",
                destructive
            ) {
                await work(Set(scope.notes), scope.cards)
            }
        }
    }

    private func runNotes(
        _ verb: String,
        _ noun: String,
        destructive: Bool = false,
        work: @escaping (Set<NoteID>, [CardID]) async -> Void
    ) {
        Task {
            let scope = await model.searchScope(source, includeSubdecks: includeSubdecks)
            let count = scope.notes.count
            guard count > 0 else {
                model.errorMessage = "Nothing in \(model.title(for: source)) to \(noun)."
                return
            }
            let name = model.title(for: source)
            let sub = includeSubdecks && isDeck ? " and its subdecks" : ""
            onConfirm(
                "\(verb) \(count) note\(count == 1 ? "" : "s")?",
                "Applies to \(name)\(sub). You can undo this from More.",
                destructive
            ) {
                await work(Set(scope.notes), scope.cards)
            }
        }
    }

    private var isDeck: Bool {
        if case .deck = source { return true }
        return false
    }
}

/// Desktop modifier-click analogs: AND / OR / exclude this row's fragment.
struct BrowseSourceCompositionMenu: View {
    let source: BrowseSource
    var model: BrowseModel

    var body: some View {
        if let node = model.filterNode(for: source), source != .allDecks {
            Section("Search") {
                Button("AND with current search") {
                    Task { await model.composeSidebarNode(node, composition: .andWithExisting) }
                }
                Button("OR with current search") {
                    Task { await model.composeSidebarNode(node, composition: .orWithExisting) }
                }
                Button("Exclude from current search", role: .destructive) {
                    Task { await model.composeSidebarNode(node, composition: .negateAndAdd) }
                }
            }
        }
    }
}

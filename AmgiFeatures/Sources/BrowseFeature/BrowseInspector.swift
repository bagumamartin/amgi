// AmgiApp/Sources/Browse/BrowseInspector.swift
import SwiftUI
import AnkiKit
import AnkiClients
import AnkiServices
import Dependencies
import AmgiTheme

/// Trailing inspector for single selection (spec §5.8): Edit uses the
/// existing rich editor pipeline, Preview renders the REAL card via the
/// same WKWebView renderer review uses, Info surfaces scheduling facts.
/// On iPhone there is no trailing pane — sheets host the same tabs via
/// `BrowseDetailSheet`.
struct BrowseDetailTabs: View {
    @Environment(\.palette) private var palette

    let note: NoteRecord?
    let notetypeName: String?
    /// Cards-mode record for the Info tab (per-card facts).
    let infoCard: CardRecord?
    /// First card of the selected note — feeds Preview rendering.
    let firstCardID: CardID?
    let onSaved: () -> Void

    enum Tab: String, CaseIterable {
        case edit = "Edit"
        case preview = "Preview"
        case info = "Info"
    }

    // Clicking a row is a peek, not an edit session — Preview leads and
    // Edit is one tap away (desktop-Anki parity for the default view).
    @State private var tab: Tab = .preview

    var body: some View {
        VStack(spacing: 0) {
            Picker("Tab", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(8)

            Divider()

            content
        }
        .background(palette.background)
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .edit:
            if let note {
                NoteEditorView(note: note, onSave: onSaved)
                    .id(note.id)
            } else {
                Text("Select one row to edit its fields and tags.")
                    .amgiFont(.body)
                    .foregroundStyle(palette.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        case .preview:
            if let firstCardID {
                CardPreviewPane(cardId: firstCardID)
            } else {
                Text("Preview needs a card; switch to Cards mode or resolve the note's cards.")
                    .amgiFont(.body).foregroundStyle(palette.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        case .info:
            CardInfoPane(card: infoCard)
        }
    }
}

// MARK: - Preview pane (real renderer)

struct CardPreviewPane: View {
    @Environment(\.palette) private var palette
    let cardId: CardID?

    struct Rendered: Equatable {
        let frontHTML: String
        let backHTML: String
        let css: String
    }

    @State private var rendered: Rendered?
    @State private var showAnswer = false
    @State private var failed = false

    @Dependency(\.cardRenderingService) private var rendering

    var body: some View {
        Group {
            if let rendered {
                ScrollView {
                    VStack(spacing: 12) {
                        flipCard(rendered)
                        Button(showAnswer ? "Show question" : "Show answer") {
                            withAnimation(.easeInOut(duration: 0.18)) { showAnswer.toggle() }
                        }
                        .buttonStyle(.bordered)
                        .padding(.bottom, 16)
                    }
                    .padding()
                }
            } else if failed {
                emptyState("Preview unavailable for this row.")
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: cardId) {
            await load()
        }
    }

    @ViewBuilder
    private func flipCard(_ rendered: Rendered) -> some View {
        CardWebView(
            html: showAnswer ? rendered.backHTML : rendered.frontHTML,
            cardCSS: rendered.css,
            autoplayEnabled: false,
            isAnswerSide: showAnswer,
            openLinksExternally: true,
            lookupPopupEnabled: false
        )
        .frame(minHeight: 220)
        .clipShape(RoundedRectangle(cornerRadius: AmgiRadius.hero))
        .overlay(
            RoundedRectangle(cornerRadius: AmgiRadius.hero)
                .strokeBorder(palette.separator, lineWidth: 1)
        )
    }

    private func load() async {
        guard let cardId else {
            failed = true
            return
        }
        do {
            // Sync FFI under the hood — hop off MainActor per the blocking-
            // FFI rule. `rendering` is Sendable, so its closure capture is
            // legal outside the actor.
            let renderer = rendering
            let card = try await Task.detached(priority: .userInitiated) {
                try renderer.renderCard(cardId)
            }.value
            rendered = Rendered(
                frontHTML: card.frontHTML,
                backHTML: card.backHTML,
                css: card.cardCSS
            )
            failed = false
        } catch {
            failed = true
        }
    }

    private func emptyState(_ text: String) -> some View {
        ContentUnavailableView("No Preview", systemImage: "eye.slash", description: Text(text))
    }
}

private extension CardPreviewPane {
    // `firstCardID` is passed in directly; placeholder kept for symmetry.
}

// MARK: - Info pane (native facts; revlog history ships with engine rows)

struct CardInfoPane: View {
    @Environment(\.palette) private var palette
    /// Cards-mode rows hand a full record; notes-mode hands nil (info is
    /// per-card — desktop shows note's first card).
    let card: CardRecord?

    var body: some View {
        List {
            if let card {
                Section("Scheduling") {
                    factRow("Type", typeName(card.type))
                    factRow("Queue", queueName(card.queue))
                    factRow("Due", dueDescription(card))
                    if card.ivl > 0 {
                        factRow("Interval", "\(card.ivl)d")
                    }
                    if card.factor > 0 {
                        factRow("Ease factor", "\(card.factor.formatted(.number.precision(.fractionLength(1))))‰")
                    }
                    factRow("Reviews", "\(card.reps)")
                    factRow("Lapses", "\(card.lapses)")
                }
                Section("Identity") {
                    factRow("Card ID", "\(card.id.rawValue)")
                    factRow("Note ID", "\(card.nid.rawValue)")
                    factRow("Deck ID", "\(card.did.rawValue)")
                    if card.odid != DeckID(0) {
                        factRow("Original deck", "\(card.odid.rawValue)")
                        factRow("Original due", "\(card.odue)")
                    }
                }
                Section("Flags") {
                    factRow("Flag color", flagName(card.flags & 0b111))
                }
            } else {
                Text("Scheduling info is per-card. Switch to Cards mode or pick a specific card to inspect it.")
                    .amgiFont(.body)
                    .foregroundStyle(palette.textSecondary)
            }
        }
    }

    private func factRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(palette.textSecondary)
            Spacer()
            Text(value.isEmpty ? "—" : value)
                .monospacedDigit()
        }
        .amgiFont(.body)
    }

    private func typeName(_ type: Int16) -> String {
        switch type {
        case 0: "New"
        case 1: "Learning"
        case 2: "Review"
        case 3: "Relearning"
        default: "type \(type)"
        }
    }

    private func queueName(_ queue: Int16) -> String {
        switch queue {
        case ..<(-1): "Buried"
        case -1: "Suspended"
        case 0: "New"
        case 1...: "In learning/review"
        default: "queue \(queue)"
        }
    }

    private func dueDescription(_ card: CardRecord) -> String {
        switch card.type {
        case 0: "#\(card.due)"
        default:
            card.due > 86_400 ? "+\(card.due / 86_400)d" : "today (\(card.due))"
        }
    }

    private func flagName(_ flag: Int32) -> String {
        ["None", "Red", "Orange", "Green", "Blue", "Pink", "Turquoise", "Purple"][Int(flag)]
    }
}

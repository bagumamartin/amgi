import AmgiReader
import AmgiTheme
import AmgiUI
import SwiftUI

/// The docked draft, opened: the card itself, editable in place, with the
/// page still visible above it at the medium detent.
///
/// Deliberately the card and not a form — a front and a back you can read as
/// they will be reviewed, each with a way back to the passage it came from.
/// Where the card goes (deck, note type) sits underneath, set once per book.
struct ReaderCardDraftSheet: View {
    let draftID: UUID
    @Bindable var session: ReaderCardSession
    let onGoTo: (ReaderSourceAnchor) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    @State private var front = ""
    @State private var back = ""
    @State private var didLoad = false
    @FocusState private var focusedSide: ReaderCardDraft.Side?

    private var draft: ReaderCardDraft? { session.drafts.draft(draftID) }

    private var isComplete: Bool {
        !front.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !back.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    side(.front, text: $front, placeholder: "Question, term, or prompt")
                    side(.back, text: $back, placeholder: "Answer — or select it in the book")
                    destination
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .navigationTitle("Card")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { commitAndDismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add Card") {
                        Task {
                            await commit()
                            dismiss()
                            await session.save(draftID)
                        }
                    }
                    .disabled(!isComplete)
                }
                ToolbarItem(placement: .destructiveAction) {
                    Button("Discard", systemImage: "trash", role: .destructive) {
                        dismiss()
                        Task { await session.discard(draftID) }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task {
            guard !didLoad, let draft else { return }
            front = draft.front
            back = draft.back
            didLoad = true
            // No keyboard on open. The missing side is usually still in the
            // book, and a keyboard would lift the sheet over the very page it
            // has to be selected from. Tapping a field types into it.
            await session.capture.loadIfNeeded()
        }
        .onDisappear {
            Task { await commit() }
        }
    }

    private func side(
        _ side: ReaderCardDraft.Side,
        text: Binding<String>,
        placeholder: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(side == .front ? "FRONT" : "BACK")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(palette.textSecondary)
                Spacer()
                sources(for: side)
            }
            TextField(placeholder, text: text, axis: .vertical)
                .amgiFont(.body)
                .foregroundStyle(palette.textPrimary)
                .lineLimit(2...12)
                .focused($focusedSide, equals: side)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: AmgiRadius.inset, style: .continuous)
                .fill(palette.surfaceElevated)
        )
    }

    /// "Ch. 3" chips that jump to where each passage came from.
    @ViewBuilder
    private func sources(for side: ReaderCardDraft.Side) -> some View {
        let anchors = (draft?.clips(side) ?? []).compactMap(\.anchor)
        HStack(spacing: 6) {
            ForEach(Array(anchors.prefix(3).enumerated()), id: \.offset) { _, anchor in
                Button {
                    commitAndDismiss()
                    onGoTo(anchor)
                } label: {
                    Label(session.chapterTitle(for: anchor) ?? "Source", systemImage: "arrow.turn.down.right")
                        .amgiFont(.micro)
                        .foregroundStyle(palette.accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Go to the passage this came from")
            }
        }
    }

    @ViewBuilder
    private var destination: some View {
        let capture = session.capture
        if let current = session.destination {
            VStack(spacing: 0) {
                Picker(selection: Binding(
                    get: { current.deckID },
                    set: { session.setDestination(.init(deckID: $0, notetypeID: current.notetypeID)) }
                )) {
                    ForEach(capture.decks) { deck in
                        Text(deck.name).tag(deck.id)
                    }
                } label: {
                    Label("Deck", systemImage: "tray")
                }
                .padding(.vertical, 6)
                Divider()
                Picker(selection: Binding(
                    get: { current.notetypeID },
                    set: { session.setDestination(.init(deckID: current.deckID, notetypeID: $0)) }
                )) {
                    ForEach(capture.notetypes) { notetype in
                        Text(notetype.name).tag(notetype.id)
                    }
                } label: {
                    Label("Note Type", systemImage: "rectangle.on.rectangle")
                }
                .padding(.vertical, 6)
            }
            .pickerStyle(.menu)
            .amgiFont(.body)
            .foregroundStyle(palette.textPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: AmgiRadius.inset, style: .continuous)
                    .fill(palette.surfaceElevated)
            )
            Text("Every card from this book goes here.")
                .amgiFont(.caption)
                .foregroundStyle(palette.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
        }
    }

    private func commit() async {
        guard didLoad else { return }
        await session.drafts.update(draftID, front: front, back: back)
    }

    private func commitAndDismiss() {
        Task { await commit() }
        dismiss()
    }
}

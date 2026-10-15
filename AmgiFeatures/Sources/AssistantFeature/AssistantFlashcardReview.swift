import AmgiAppCore
import AmgiTheme
import AmgiUI
import SwiftUI

/// The one gate every assistant write passes through: the proposed cards,
/// editable, with the destination deck, before anything is saved.
struct AssistantFlashcardReview: View {
    @State private var draft: FlashcardDraft
    let finish: (FlashcardDraft?) -> Void
    @Environment(\.palette) private var palette

    init(draft: FlashcardDraft, finish: @escaping (FlashcardDraft?) -> Void) {
        _draft = State(initialValue: draft)
        self.finish = finish
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: AmgiSpacing.md) {
                        AssistantHead(.curious).frame(width: 44, height: 44)
                        Text("Edit anything you like. Nothing is saved until you add the cards.")
                            .amgiFont(.caption)
                            .foregroundStyle(palette.textSecondary)
                    }
                    Picker("Deck", selection: $draft.deckID) {
                        ForEach(draft.decks) { Text($0.name).tag($0.id) }
                    }
                } footer: {
                    Text("Note type: \(draft.notetypeName)")
                }
                ForEach($draft.cards) { $card in
                    Section {
                        TextField("Front", text: $card.front, axis: .vertical)
                            .lineLimit(1...6)
                        TextField("Back", text: $card.back, axis: .vertical)
                            .lineLimit(1...8)
                            .foregroundStyle(palette.textSecondary)
                    } header: {
                        Toggle(isOn: $card.included) {
                            Text("Card \((draft.cards.firstIndex { $0.id == card.id } ?? 0) + 1)")
                        }
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                    }
                    .opacity(card.included ? 1 : 0.45)
                }
            }
            .navigationTitle("Review cards")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Don't add") { finish(nil) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add \(draft.includedCount)") { finish(draft) }
                        .disabled(draft.includedCount == 0)
                }
            }
        }
        .presentationDetents([.large])
    }
}

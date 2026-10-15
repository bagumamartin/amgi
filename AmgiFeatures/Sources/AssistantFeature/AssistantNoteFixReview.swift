import AmgiAppCore
import AmgiCardWeb
import AmgiTheme
import AmgiUI
import SwiftUI

/// Before and after for each field the assistant wants to change. Nothing
/// is written until the user saves.
struct AssistantNoteFixReview: View {
    @State private var draft: NoteFixDraft
    let finish: (NoteFixDraft?) -> Void
    @Environment(\.palette) private var palette

    init(draft: NoteFixDraft, finish: @escaping (NoteFixDraft?) -> Void) {
        _draft = State(initialValue: draft)
        self.finish = finish
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: AmgiSpacing.md) {
                        AssistantHead(.curious).frame(width: 44, height: 44)
                        Text("Check the correction. Edit it if you like; the card only changes when you save.")
                            .amgiFont(.caption)
                            .foregroundStyle(palette.textSecondary)
                    }
                }
                ForEach($draft.fields) { $field in
                    Section {
                        VStack(alignment: .leading, spacing: AmgiSpacing.xs) {
                            Text("Before").amgiFont(.micro).foregroundStyle(palette.textTertiary)
                            Text(CardText.plainText(field.before))
                                .amgiFont(.body)
                                .foregroundStyle(palette.textSecondary)
                                .strikethrough(field.included, color: palette.textTertiary)
                                .textSelection(.enabled)
                        }
                        VStack(alignment: .leading, spacing: AmgiSpacing.xs) {
                            Text("After").amgiFont(.micro).foregroundStyle(palette.textTertiary)
                            TextField("New text", text: $field.after, axis: .vertical)
                                .lineLimit(1...10)
                        }
                    } header: {
                        Toggle(isOn: $field.included) { Text(field.name) }
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                    } footer: {
                        if field.before.contains("<") {
                            Text("This field has formatting. Saving replaces it with plain text.")
                        }
                    }
                    .opacity(field.included ? 1 : 0.45)
                }
            }
            .navigationTitle("Fix this card")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Keep as is") { finish(nil) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { finish(draft) }
                        .disabled(draft.changedCount == 0)
                }
            }
        }
        .presentationDetents([.large])
    }
}

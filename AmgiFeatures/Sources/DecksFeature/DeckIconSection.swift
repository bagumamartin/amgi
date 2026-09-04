import SwiftUI
import AnkiKit
import AmgiIcons
import AmgiTheme
import AnkiClients
import Dependencies

// MARK: - DeckIconSection
//
// Shared icon row for CreateDeckSheet / RenameDeckSheet: shows the deck's
// current tile (manual pick, else live auto-suggestion from the name), and
// opens `IconPickerView` to override. Implements the spec's manual-override
// semantics — any pick through the picker flips `iconManuallySet`, after
// which name changes no longer rewrite the selection.

struct DeckIconSection: View {
    @Binding var selectedIconName: String?
    @Binding var iconManuallySet: Bool
    let deckName: String
    @Environment(\.palette) private var palette

    @State private var showPicker = false
    /// Live suggestion while the user hasn't picked manually.
    @State private var suggestedIconName: String?

    private var displayedIconName: String? {
        iconManuallySet ? selectedIconName : (selectedIconName ?? suggestedIconName)
    }

    var body: some View {
        HStack(spacing: 12) {
            iconPreview
            VStack(alignment: .leading, spacing: 2) {
                Text(displayedIconName.map { displayName($0) } ?? "Automatic")
                    .amgiFont(.body)
                Text(iconManuallySet ? "Manually set" : "Suggested from deck name")
                    .amgiFont(.caption)
                    .foregroundStyle(palette.textSecondary)
            }
            Spacer()
            Button("Change…") { showPicker = true }
                .buttonStyle(.borderless)
        }
        .sheet(isPresented: $showPicker) {
            IconPickerView(selection: $selectedIconName) { picked in
                // A concrete pick stops auto-suggestion; the picker's
                // "Automatic" action (nil) resumes it.
                iconManuallySet = (picked != nil)
            }
            #if os(macOS)
            .frame(minWidth: 540, minHeight: 520)
            #endif
        }
        .task(id: autoSuggestKey) {
            guard !iconManuallySet else { return }
            let trimmed = deckName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                suggestedIconName = nil
                return
            }
            // Debounce so typing doesn't re-embed every keystroke; SwiftUI
            // cancels this task when the key changes.
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            suggestedIconName = await IconSuggester.shared.bestMatch(for: trimmed)
        }
    }

    private var autoSuggestKey: String {
        "\(iconManuallySet)|\(deckName)"
    }

    @ViewBuilder
    private var iconPreview: some View {
        if let name = displayedIconName,
           let glyph = AmgiIcons.DeckIconGlyph.image(for: name) {
            RoundedRectangle(cornerRadius: AmgiRadius.small, style: .continuous)
                .fill(palette.accent.opacity(0.15))
                .frame(width: 44, height: 44)
                .overlay { glyph.font(.system(size: 24)) }
        } else {
            RoundedRectangle(cornerRadius: AmgiRadius.small, style: .continuous)
                .fill(.quaternary)
                .frame(width: 44, height: 44)
                .overlay {
                    Image(systemName: "questionmark")
                        .font(.system(size: 20))
                        .foregroundStyle(palette.textSecondary)
                }
        }
    }

    private func displayName(_ camelCase: String) -> String {
        camelCase.replacingOccurrences(
            of: "([a-z])([A-Z])",
            with: "$1 $2",
            options: .regularExpression
        )
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Icon section") {
    struct Harness: View {
        @State private var selection: String? = "flask"
        @State private var manual = true
        var body: some View {
            Form {
                TextField("Name", text: .constant("Organic Chemistry"))
                DeckIconSection(
                    selectedIconName: $selection,
                    iconManuallySet: $manual,
                    deckName: "Organic Chemistry"
                )
            }
        }
    }
    return Harness()
}
#endif

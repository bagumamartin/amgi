import SwiftUI
import Sharing

/// Settings pane for rebinding the review keyboard shortcuts. Each action
/// shows its current binding; clicking it arms a recorder that captures the
/// next key press (with modifiers).
struct ShortcutsSettingsView: View {
    @Shared(.reviewShortcuts) private var shortcuts: [String: ReviewShortcut] = [:]

    var body: some View {
        Form {
            Section {
                ForEach(ReviewShortcutAction.allCases) { action in
                    ShortcutRow(
                        action: action,
                        shortcut: Binding(
                            get: { shortcuts[action.rawValue] ?? action.defaultShortcut },
                            set: { newValue in
                                $shortcuts.withLock { $0[action.rawValue] = newValue }
                            }
                        )
                    )
                }
            } header: {
                Text("Review Shortcuts")
            } footer: {
                Text("Shortcuts apply while reviewing. Select a shortcut to record a new one — letters, digits, space, or arrow keys, with any modifiers (e.g. ⌥→). Press Escape to cancel.")
            }
        }
        .navigationTitle("Shortcuts")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ShortcutRow: View {
    let action: ReviewShortcutAction
    @Binding var shortcut: ReviewShortcut

    @State private var isRecording = false
    @FocusState private var isFocused: Bool

    var body: some View {
        LabeledContent {
            Button(isRecording ? "Press keys…" : shortcut.displayString) {
                isRecording = true
            }
            .buttonStyle(.bordered)
            .monospaced()
        } label: {
            Label(action.title, systemImage: action.systemImage)
        }
        .contentShape(Rectangle())
        .focusable()
        .focused($isFocused)
        .onChange(of: isRecording) { _, recording in
            if recording {
                // Dispatch async so the Form row can become focusable after the tap
                DispatchQueue.main.async { isFocused = true }
            } else {
                isFocused = false
            }
        }
        .onKeyPress { press in
            guard isRecording else { return .ignored }
            if press.key == .escape {
                isRecording = false
                return .handled
            }
            let key = String(press.key.character)
            guard !key.isEmpty else { return .handled }
            shortcut = ReviewShortcut(key: key, modifiers: press.modifiers)
            isRecording = false
            return .handled
        }
    }
}

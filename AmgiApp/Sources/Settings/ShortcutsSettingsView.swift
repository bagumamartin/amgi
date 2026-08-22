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
                Text("Shortcuts apply while reviewing. Select a shortcut to record a new one; press Escape to cancel.")
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

    var body: some View {
        LabeledContent {
            Button(isRecording ? "Press keys…" : shortcut.displayString) {
                isRecording = true
            }
            .buttonStyle(.bordered)
            .monospaced()
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
        } label: {
            Label(action.title, systemImage: action.systemImage)
        }
    }
}

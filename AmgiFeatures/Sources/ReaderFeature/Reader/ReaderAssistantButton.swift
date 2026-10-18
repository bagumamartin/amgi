import AmgiTheme
import AmgiUI
import AssistantFeature
import SwiftUI

/// The assistant's way into a reader: its head in a glass circle, the same
/// size as the reader's other round chrome. Readers hide the root's Ask AI
/// entry, so each places this one in its bottom-trailing column, clear of
/// its own controls. Opens through the root's presenter; renders nothing
/// without one (previews).
struct ReaderAssistantButton: View {
    let context: () -> AssistantContext
    var size: CGFloat = 44
    /// Off in a toolbar, which draws its own glass.
    var floating = true

    @Environment(\.assistantOpener) private var opener

    var body: some View {
        if let opener {
            Button { opener.open(context()) } label: {
                AssistantHead(.idle)
                    .frame(width: size * 0.62, height: size * 0.62)
                    .frame(width: size, height: size)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .modifier(FloatingGlass(isOn: floating))
            .accessibilityLabel("Ask AI about this book")
            .accessibilityIdentifier("reader.assistant")
            .help("Ask AI about this book")
        }
    }
}

private struct FloatingGlass: ViewModifier {
    let isOn: Bool

    func body(content: Content) -> some View {
        if isOn {
            content
                .amgiMaterial(.regular, in: Circle(), interactive: true)
                .amgiMaterialElevation(Circle())
        } else {
            content
        }
    }
}

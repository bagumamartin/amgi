import AmgiReaderPDF
import SwiftUI

/// The bottom toolbar: navigation, zoom, rotation, layout and the markup tools.
///
/// Laid out as Preview lays it out — navigation and zoom on the left, the
/// annotation tools in the middle, and the sidebar toggle and search on the
/// right — because a reader's muscle memory is the strongest argument a UI has.
struct PDFReaderToolbar: View {
    @Binding var navigation: PDFReaderNavigation
    let model: PDFReaderModel
    @Binding var activeTool: PDFAnnotationTool?
    @Binding var activeKind: PDFAnnotationKind
    @Binding var activeColour: PDFAnnotationColour
    @Binding var showsThickness: Bool
    let onToggleSidebar: () -> Void
    let onGoToPage: (Int) -> Void
    let onSearch: () -> Void
    let onEditAnnotation: (String) -> Void
    let onDeleteAnnotation: (String) -> Void

    @State private var goToPageText: String = ""
    @State private var isEditingPageField = false

    var body: some View {
        HStack(spacing: 12) {
            navigationControls
            Divider().frame(height: 20)
            zoomControls
            Divider().frame(height: 20)
            layoutControls
            Spacer(minLength: 8)
            annotationTools
            Spacer(minLength: 8)
            Divider().frame(height: 20)
            pageField
            searchButton
            sidebarButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    // MARK: - Navigation

    private var navigationControls: some View {
        HStack(spacing: 4) {
            Button {
                let target = navigation.turn(by: -1)
                onGoToPage(target)
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(navigation.pageIndex <= 0)
            .help("Previous page")

            Text("\(navigation.pageIndex + 1) of \(max(1, navigation.pageCount))")
                .font(.callout)
                .monospacedDigit()
                // The document's own label, not the index: a book with roman
                // front matter is "xii", and showing "12" for the same page is
                // the sort of small wrongness that makes a reader distrust the
                // page numbers.
                .accessibilityLabel("Page \(navigation.pageLabel) of \(navigation.pageCount)")

            Button {
                let target = navigation.turn(by: 1)
                onGoToPage(target)
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(navigation.pageIndex >= navigation.pageCount - 1)
            .help("Next page")
        }
        .buttonStyle(.borderless)
    }

    @ViewBuilder
    private var pageField: some View {
        HStack(spacing: 4) {
            Text("Page")
                .font(.caption)
                .foregroundStyle(.secondary)
            // A plain text field with a stepper, as Preview has: the field
            // accepts a typed page number for a 900-page book, where a slider
            // would be unusable.
            TextField(
                "",
                text: Binding(
                    get: { isEditingPageField ? goToPageText : navigation.pageLabel },
                    set: { goToPageText = $0 }
                )
            )
            .textFieldStyle(.roundedBorder)
            .frame(width: 56)
            .multilineTextAlignment(.center)
            .onSubmit { commitPageField() }
            .onTapGesture { beginPageEdit() }
            #if os(macOS)
            // Escape abandons an edit, as it does in every macOS text field.
            // iOS has no equivalent gesture, and the return key already commits.
            .onExitCommand { cancelPageEdit() }
            #endif
        }
    }

    private func beginPageEdit() {
        // Prefilled with the label, so editing means changing one character
        // rather than typing the whole thing.
        goToPageText = navigation.pageLabel
        isEditingPageField = true
    }

    private func cancelPageEdit() {
        isEditingPageField = false
        goToPageText = ""
    }

    private func commitPageField() {
        defer { cancelPageEdit() }
        let trimmed = goToPageText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        // Accept the document's own label as well as a plain number, because the
        // field is prefilled with the label and a user who edits it expects
        // their edit to mean the same thing.
        if let index = model.pageIndex(matchingLabel: trimmed) {
            onGoToPage(index)
            return
        }
        guard let number = Int(trimmed), number >= 1, number <= model.pageCount else {
            return
        }
        onGoToPage(number - 1)
    }

    // MARK: - Zoom

    private var zoomControls: some View {
        HStack(spacing: 4) {
            Picker("Zoom", selection: $navigation.zoom) {
                ForEach(PDFReaderNavigation.Zoom.allCases) { zoom in
                    Label(zoom.label, systemImage: zoom.symbolName).tag(zoom)
                }
            }
            .labelsHidden()
            .frame(width: 110)

            Button {
                navigation.rotateCounterClockwise()
            } label: {
                Image(systemName: "rotate.left")
            }
            .help("Rotate left")

            Button {
                navigation.rotateClockwise()
            } label: {
                Image(systemName: "rotate.right")
            }
            .help("Rotate right")
        }
        .buttonStyle(.borderless)
    }

    // MARK: - Layout

    private var searchButton: some View {
        Button(action: onSearch) {
            Image(systemName: "magnifyingglass")
        }
        .help("Find in document")
    }

    private var sidebarButton: some View {
        Button(action: onToggleSidebar) {
            Image(systemName: "sidebar.leading")
        }
        .help(navigation.isSidebarVisible ? "Hide sidebar" : "Show sidebar")
    }

    private var layoutControls: some View {
        HStack(spacing: 4) {
            Picker("Page transition", selection: $navigation.transition) {
                ForEach(PDFReaderNavigation.Transition.allCases) { transition in
                    Label(transition.label, systemImage: transition.symbolName).tag(transition)
                }
            }
            .labelsHidden()
            .frame(width: 120)

            Toggle(isOn: $navigation.isTwoUp) {
                Image(systemName: "rectangle.split.2x1")
            }
            .toggleStyle(.button)
            .help("Two pages side by side")
        }
    }

    // MARK: - Annotation tools

    private var annotationTools: some View {
        HStack(spacing: 6) {
            ForEach(PDFAnnotationTool.allCases) { tool in
                toolButton(tool)
            }
            Divider().frame(height: 20)
            colourSwatches
        }
    }

    private func toolButton(_ tool: PDFAnnotationTool) -> some View {
        // One button per *group*, as Preview has. Ten individual tools in a row
        // is unusable on a phone and unreadable on a Mac; the group opens a
        // menu of the specific marks.
        Menu {
            ForEach(tool.kinds) { kind in
                Button {
                    activeKind = kind
                    activeTool = tool
                } label: {
                    Label(kind.label, systemImage: kind.symbolName)
                }
            }
        } label: {
            Label {
                Text(activeTool == tool ? tool.label : "")
            } icon: {
                Image(systemName: tool.symbolName)
                    .foregroundStyle(activeTool == tool ? Color.accentColor : Color.primary)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(tool.label)
    }

    private var colourSwatches: some View {
        HStack(spacing: 4) {
            ForEach(PDFAnnotationColour.allCases) { colour in
                Button {
                    activeColour = colour
                    // Choosing a colour implies the user wants to use it, so the
                    // tool is selected too. Requiring both steps means picking a
                    // colour does nothing visible, which reads as a dead control.
                    if activeTool == nil { activeTool = .marker }
                } label: {
                    Circle()
                        .fill(colour.swiftUIColor)
                        .frame(width: 14, height: 14)
                        .overlay {
                            Circle().strokeBorder(
                                activeColour == colour ? Color.primary : .clear,
                                lineWidth: 1.5
                            )
                        }
                }
                .buttonStyle(.plain)
                .help(colour.label)
                .accessibilityLabel(colour.label)
            }
        }
    }
}

extension PDFReaderModel {
    /// The page index a typed label refers to.
    ///
    /// Matches the document's own page labels, so a book numbered "xii" can be
    /// navigated by typing "xii" — which is what the field shows and therefore
    /// what the user has in front of them.
    func pageIndex(matchingLabel label: String) -> Int? {
        guard let descriptor else { return nil }
        let wanted = label.trimmingCharacters(in: .whitespaces).lowercased()
        guard !wanted.isEmpty else { return nil }
        for index in 0..<max(0, pageCount) {
            if descriptor.label(forPageIndex: index).lowercased() == wanted {
                return index
            }
        }
        return nil
    }
}

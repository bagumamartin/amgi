import SwiftUI
import UIKit
import AmgiTheme
import AmgiUI
import SwiftUINavigation

private enum IOMaskFillOption: CaseIterable {
    case `default`
    case yellow
    case red
    case blue
    case green

    var label: String {
        switch self {
        case .default: return "Default"
        case .yellow:  return "Yellow"
        case .red:     return "Red"
        case .blue:    return "Blue"
        case .green:   return "Green"
        }
    }

    var hex: String? {
        switch self {
        case .default: return nil
        case .yellow:  return "FFEBA2CC"
        case .red:     return "FF8E8ECC"
        case .blue:    return "8FB8FFCC"
        case .green:   return "A7E3AECC"
        }
    }
}

// MARK: - ImageOcclusionWorkspaceView

struct ImageOcclusionWorkspaceView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.undoManager) private var undoManager
    @Environment(\.palette) private var palette

    let title: String
    let onSave: ([IOMask]) -> Void

    @State private var model: ImageOcclusionWorkspaceModel
    @State private var destination: ImageOcclusionDestination?
    @State private var zoomCommand: IOCanvasZoomCommand = .fit
    @State private var zoomCommandID = 0

    init(title: String, image: UIImage, initialMasks: [IOMask], onSave: @escaping ([IOMask]) -> Void) {
        self.title = title
        self.onSave = onSave
        _model = State(initialValue: ImageOcclusionWorkspaceModel(image: image, initialMasks: initialMasks))
    }

    var body: some View {
        VStack(spacing: 0) {
            toolPalette
            canvas
        }
        .toolbar(.hidden, for: .tabBar)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { workspaceToolbar }
        .safeAreaInset(edge: .bottom) { bottomToolbars }
        .modifier(WorkspacePresentations(destination: $destination, model: model, onDiscard: { dismiss() }))
        // The environment UndoManager isn't available at init, so hand it to
        // the model once the view is on screen.
        .onAppear { model.undoManager = undoManager }
        .onChange(of: undoManager) { _, manager in model.undoManager = manager }
    }

    private var canvas: some View {
        ZoomableOcclusionCanvasView(
            image: model.image,
            masks: $model.masks,
            selectedMaskIndex: $model.selectedMaskIndex,
            selectedMaskIndices: model.highlightedMaskIndices,
            highlightedMaskIndices: model.highlightedMaskIndices,
            shapeType: model.shapeType,
            maskOpacity: showsTranslucentMasks ? 0.72 : 0.94,
            zoomCommand: zoomCommand,
            zoomCommandID: zoomCommandID,
            onRequestText: { destination = .textEditor(model.textDraft(insertingAt: $0)) },
            onRequestTextEdit: { index in
                guard let draft = model.textDraft(editing: index) else { return }
                destination = .textEditor(draft)
            },
            onAppend: { model.appendMask($0) },
            onSelectionChange: { model.handleCanvasSelectionChange($0) },
            onTransformDidBegin: { model.handleTransformDidBegin() },
            onTransformDidEnd: { model.handleTransformDidEnd() }
        )
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.background)
    }

    @State private var showsTranslucentMasks = true

    @ToolbarContentBuilder
    private var workspaceToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("Cancel") { requestDismiss() }
                .amgiToolbarTextButton(tone: .neutral)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button("Save") { saveWorkspace() }
                .amgiToolbarTextButton()
        }
    }

    private var toolPalette: some View {
        HStack(spacing: 4) {
            ForEach(IOShapeType.allCases, id: \.self) { tool in
                ioPaletteButton(
                    title: tool.label,
                    systemImage: tool.systemImage,
                    isSelected: model.shapeType == tool
                ) {
                    model.shapeType = tool
                }
                .frame(maxWidth: .infinity)
            }

            Menu {
                ForEach(IOMaskFillOption.allCases, id: \.self) { option in
                    Button(option.label) {
                        model.applyFill(option.hex)
                    }
                }
                Divider()
                Button("Custom") {
                    destination = .fillEditor(IOFillDraft(color: model.fillEditorSeedColor))
                }
                Button("Default") {
                    model.applyFill(nil as String?)
                }
            } label: {
                ioPaletteChip(
                    title: "Fill",
                    systemImage: "paintpalette",
                    isSelected: false
                )
            }
            .frame(maxWidth: .infinity)
            .disabled(model.activeSelectionIndices.isEmpty)

            Menu {
                ForEach(IOOcclusionMode.allCases, id: \.self) { mode in
                    Button(mode.label) {
                        model.applyOcclusionMode(mode)
                    }
                }
            } label: {
                ioPaletteChip(
                    title: "Mode",
                    systemImage: "square.stack.3d.up",
                    isSelected: false
                )
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(palette.surface)
    }

    private var bottomToolbars: some View {
        VStack(spacing: 8) {
            editingToolbar
            arrangeToolbar
        }
        .padding(.top, 10)
        .padding(.bottom, 10)
        .background(palette.surface)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private var editingToolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                toolbarIconButton(systemImage: "arrow.uturn.backward") {
                    undoManager?.undo()
                }
                .disabled(!(undoManager?.canUndo ?? false))

                toolbarIconButton(systemImage: "arrow.uturn.forward") {
                    undoManager?.redo()
                }
                .disabled(!(undoManager?.canRedo ?? false))

                toolbarIconButton(systemImage: "trash") {
                    model.deleteSelection()
                }
                .disabled(model.activeSelectionIndices.isEmpty)

                toolbarIconButton(systemImage: "plus.square.on.square") {
                    model.duplicateSelection()
                }
                .disabled(model.activeSelectionIndices.isEmpty)

                toolbarIconButton(systemImage: model.allMasksSelected ? "checkmark.circle.fill" : "checkmark.circle") {
                    model.toggleSelectAll()
                }
                .disabled(model.masks.isEmpty)

                toolbarIconButton(systemImage: "arrow.left.arrow.right") {
                    model.invertSelection()
                }
                .disabled(model.masks.isEmpty)

                toolbarIconButton(systemImage: showsTranslucentMasks ? "circle.lefthalf.filled" : "circle") {
                    showsTranslucentMasks.toggle()
                }
                .disabled(model.masks.isEmpty)
            }
            .padding(.horizontal, 16)
        }
    }

    private var arrangeToolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                toolbarIconButton(systemImage: "link") {
                    model.groupSelection()
                }
                .disabled(model.activeSelectionIndices.count < 2)

                toolbarIconButton(systemImage: "link.slash", fallbackSystemImage: "scissors") {
                    model.ungroupSelection()
                }
                .disabled(!model.canUngroup)

                Menu {
                    ForEach(IOMaskAlignMode.allCases, id: \.self) { mode in
                        Button(mode.label) {
                            model.alignSelection(mode)
                        }
                    }
                } label: {
                    toolbarIcon(systemImage: "align.horizontal.left")
                }
                .disabled(model.activeSelectionIndices.isEmpty)

                toolbarIconButton(systemImage: "plus.magnifyingglass") {
                    sendZoomCommand(.zoomIn)
                }

                toolbarIconButton(systemImage: "minus.magnifyingglass") {
                    sendZoomCommand(.zoomOut)
                }

                toolbarIconButton(systemImage: "arrow.up.left.and.down.right.magnifyingglass") {
                    sendZoomCommand(.fit)
                }
            }
            .padding(.horizontal, 16)
        }
    }
}

// MARK: - Presentations

/// Split out of `body` so the SwiftUI type-checker doesn't have to solve one
/// long modifier chain, matching `DeckDetailPresentations`.
private struct WorkspacePresentations: ViewModifier {
    @Binding var destination: ImageOcclusionDestination?
    let model: ImageOcclusionWorkspaceModel
    let onDiscard: () -> Void

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                "Discard changes?",
                isPresented: $destination.discardConfirmation,
                titleVisibility: .visible
            ) {
                Button("Discard", role: .destructive) { onDiscard() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Unsaved changes will be lost.")
            }
            .sheet(item: $destination.textEditor) { $draft in
                IOTextEditorSheet(draft: $draft) { submitted in
                    model.apply(submitted)
                    destination = nil
                } onCancel: {
                    destination = nil
                }
            }
            .sheet(item: $destination.fillEditor) { $draft in
                IOFillEditorSheet(draft: $draft) { color in
                    destination = nil
                    model.applyFill(color)
                } onDefault: {
                    destination = nil
                    model.applyFill(nil as String?)
                } onCancel: {
                    destination = nil
                }
            }
    }
}

private struct IOTextEditorSheet: View {
    @Environment(\.palette) private var palette
    @Binding var draft: IOTextDraft
    let onSave: (IOTextDraft) -> Void
    let onCancel: () -> Void

    private var title: String {
        if case .insert = draft.target { return "Prompt" }
        return "Edit text"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Prompt") {
                    TextField("Enter prompt text", text: $draft.text, axis: .vertical)
                        .lineLimit(3...6)
                }

                Section("Text color") {
                    ColorPicker("Custom", selection: $draft.color, supportsOpacity: true)
                }
            }
            .scrollContentBackground(.hidden)
            .background(palette.background)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { onCancel() }
                        .amgiToolbarTextButton(tone: .neutral)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { onSave(draft) }
                        .amgiToolbarTextButton()
                        .disabled(!draft.isSubmittable)
                }
            }
        }
    }
}

private struct IOFillEditorSheet: View {
    @Environment(\.palette) private var palette
    @Binding var draft: IOFillDraft
    let onSave: (Color) -> Void
    let onDefault: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Custom") {
                    ColorPicker("Custom", selection: $draft.color, supportsOpacity: true)
                }
            }
            .scrollContentBackground(.hidden)
            .background(palette.background)
            .navigationTitle("Custom")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { onCancel() }
                        .amgiToolbarTextButton(tone: .neutral)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Default") { onDefault() }
                        .amgiToolbarTextButton(tone: .neutral)

                    Button("Save") { onSave(draft.color) }
                        .amgiToolbarTextButton()
                }
            }
        }
    }
}

// MARK: - Chrome

private extension ImageOcclusionWorkspaceView {
    func requestDismiss() {
        if model.hasUnsavedChanges {
            destination = .discardConfirmation
        } else {
            dismiss()
        }
    }

    func saveWorkspace() {
        onSave(model.masks)
        dismiss()
    }

    func sendZoomCommand(_ command: IOCanvasZoomCommand) {
        zoomCommand = command
        zoomCommandID += 1
    }

    @ViewBuilder
    func ioPaletteButton(
        title: String,
        systemImage: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ioPaletteChip(title: title, systemImage: systemImage, isSelected: isSelected)
        }
        .buttonStyle(.pressScale)
    }

    @ViewBuilder
    func ioPaletteChip(
        title: String,
        systemImage: String,
        isSelected: Bool
    ) -> some View {
        VStack(spacing: 3) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(2)
                .minimumScaleFactor(0.65)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(isSelected ? Color.white : palette.textPrimary)
        .frame(maxWidth: .infinity, minHeight: 42)
        .padding(.horizontal, 2)
        .background(isSelected ? palette.accent : palette.surfaceElevated, in: RoundedRectangle(cornerRadius: AmgiRadius.inset, style: .continuous))
    }

    @ViewBuilder
    func toolbarIconButton(systemImage: String, fallbackSystemImage: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            toolbarIcon(systemImage: systemImage, fallbackSystemImage: fallbackSystemImage)
        }
        .buttonStyle(.pressScale)
    }

    @ViewBuilder
    func toolbarIcon(systemImage: String, fallbackSystemImage: String? = nil) -> some View {
        let resolvedSymbol = if UIImage(systemName: systemImage) != nil {
            systemImage
        } else {
            fallbackSystemImage ?? "questionmark"
        }

        Image(systemName: resolvedSymbol)
            .font(.system(size: 13, weight: .semibold))
            .amgiToolbarIconButton(size: 30)
    }
}

import SwiftUI
import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
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
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let title: String
    let onSave: ([IOMask]) -> Void

    @State private var model: ImageOcclusionWorkspaceModel
    @State private var destination: ImageOcclusionDestination?
    @State private var zoomCommand: IOCanvasZoomCommand = .fit
    @State private var zoomCommandID = 0
    @State private var showsInspector = true

    init(title: String, image: PlatformImage, initialMasks: [IOMask], onSave: @escaping ([IOMask]) -> Void) {
        self.title = title
        self.onSave = onSave
        _model = State(initialValue: ImageOcclusionWorkspaceModel(image: image, initialMasks: initialMasks))
        #if os(macOS)
        _showsInspector = State(initialValue: true)
        #else
        _showsInspector = State(initialValue: false)
        #endif
    }

    var body: some View {
        VStack(spacing: 0) {
            IOToolPalette(
                shapeType: model.shapeType,
                hasSelection: !model.activeSelectionIndices.isEmpty,
                onSelectTool: { model.shapeType = $0 },
                onApplyFill: { model.applyFill($0) },
                onCustomFill: {
                    destination = .fillEditor(IOFillDraft(color: model.fillEditorSeedColor))
                },
                onSelectOcclusionMode: { model.applyOcclusionMode($0) }
            )
            .equatable()

            editorCanvas
        }
        #if os(iOS)
        .toolbarVisibility(.hidden, for: .tabBar)
        #endif
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { workspaceToolbar }
        .safeAreaInset(edge: .bottom) { bottomToolbars }
        .modifier(WorkspacePresentations(destination: $destination, model: model, onDiscard: { dismiss() }))
        .sheet(
            isPresented: Binding(
                get: { showsInspector && !shouldShowInlineInspector },
                set: { if !$0 { showsInspector = false } }
            )
        ) {
            NavigationStack {
                IOMaskInspector(
                    masks: model.masks,
                    selectedIndex: model.selectedMaskIndex,
                    onEditText: editSelectedText,
                    onDuplicate: { model.duplicateSelection() },
                    onDelete: { model.deleteSelection() }
                )
                .navigationTitle("Mask Inspector")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { showsInspector = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
        // The environment UndoManager isn't available at init, so hand it to
        // the model once the view is on screen.
        .onAppear {
            model.undoManager = undoManager
            if shouldShowInlineInspector { showsInspector = true }
        }
        .onChange(of: undoManager) { _, manager in model.undoManager = manager }
    }

    private var editorCanvas: some View {
        HStack(spacing: 0) {
            canvas
            if showsInspector, shouldShowInlineInspector {
                Divider()
                IOMaskInspector(
                    masks: model.masks,
                    selectedIndex: model.selectedMaskIndex,
                    onEditText: editSelectedText,
                    onDuplicate: { model.duplicateSelection() },
                    onDelete: { model.deleteSelection() }
                )
                .frame(width: 248)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contextMenu {
            if !model.masks.isEmpty {
                Button("Duplicate Selected Masks", systemImage: "plus.square.on.square") {
                    model.duplicateSelection()
                }
                .disabled(model.activeSelectionIndices.isEmpty)
                Button("Delete Selected Masks", systemImage: "trash", role: .destructive) {
                    model.deleteSelection()
                }
                .disabled(model.activeSelectionIndices.isEmpty)
                Divider()
                Button("Select All Masks", systemImage: "checkmark.circle") {
                    model.toggleSelectAll()
                }
                Button("Invert Selection", systemImage: "arrow.left.arrow.right") {
                    model.invertSelection()
                }
            }
            Button("Fit Image to Window", systemImage: "arrow.up.left.and.down.right.magnifyingglass") {
                sendZoomCommand(.fit)
            }
        }
        .background {
            keyboardCommands
        }
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

    private var shouldShowInlineInspector: Bool {
        #if os(macOS)
        true
        #else
        horizontalSizeClass == .regular
        #endif
    }

    @ViewBuilder
    private var keyboardCommands: some View {
        // Keep command targets in the accessibility tree-free command layer;
        // the visible controls remain the discoverable path on touch.
        Group {
            Button("Duplicate Selected Masks") { model.duplicateSelection() }
                .keyboardShortcut("d", modifiers: .command)
            Button("Delete Selected Masks") { model.deleteSelection() }
                .keyboardShortcut(.delete, modifiers: [])
            Button("Select All Masks") { model.toggleSelectAll() }
                .keyboardShortcut("a", modifiers: .command)
            Button("Invert Selection") { model.invertSelection() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
            Button("Undo") { undoManager?.undo() }
                .keyboardShortcut("z", modifiers: .command)
            Button("Redo") { undoManager?.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private func editSelectedText() {
        guard let index = model.selectedMaskIndex,
              model.masks.indices.contains(index),
              case .text = model.masks[index],
              let draft = model.textDraft(editing: index) else { return }
        destination = .textEditor(draft)
    }

    @State private var showsTranslucentMasks = true

    @ToolbarContentBuilder
    private var workspaceToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("Cancel") { requestDismiss() }
                .amgiToolbarTextButton(tone: .neutral)
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                withAnimation(AmgiMotion.quick) { showsInspector.toggle() }
            } label: {
                Image(systemName: showsInspector ? "sidebar.trailing" : "sidebar.trailing")
            }
            .help(showsInspector ? "Hide mask inspector" : "Show mask inspector")
            .accessibilityLabel(showsInspector ? "Hide mask inspector" : "Show mask inspector")
            .keyboardShortcut("i", modifiers: [.command, .option])
            Button("Save") { saveWorkspace() }
                .amgiToolbarTextButton()
        }
    }

    private var bottomToolbars: some View {
        VStack(spacing: 8) {
            IOEditingToolbar(
                selectionCount: model.activeSelectionIndices.count,
                hasMasks: !model.masks.isEmpty,
                allMasksSelected: model.allMasksSelected,
                showsTranslucentMasks: showsTranslucentMasks,
                undoManager: undoManager,
                canUndo: undoManager?.canUndo ?? false,
                canRedo: undoManager?.canRedo ?? false,
                onDelete: { model.deleteSelection() },
                onDuplicate: { model.duplicateSelection() },
                onToggleSelectAll: { model.toggleSelectAll() },
                onInvertSelection: { model.invertSelection() },
                onToggleTranslucency: { showsTranslucentMasks.toggle() }
            )
            .equatable()

            IOArrangeToolbar(
                selectionCount: model.activeSelectionIndices.count,
                canUngroup: model.canUngroup,
                onGroup: { model.groupSelection() },
                onUngroup: { model.ungroupSelection() },
                onAlign: { model.alignSelection($0) },
                onZoom: { sendZoomCommand($0) }
            )
            .equatable()
        }
        .padding(.top, 10)
        .padding(.bottom, 10)
        .background(palette.surface)
        .overlay(alignment: .top) {
            Divider()
        }
    }
}

// MARK: - Mask inspector

private struct IOMaskInspector: View {
    @Environment(\.palette) private var palette
    let masks: [IOMask]
    let selectedIndex: Int?
    let onEditText: () -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Label("Mask Inspector", systemImage: "info.circle")
                    .font(.headline)
                    .foregroundStyle(palette.textPrimary)

                if let selectedIndex, masks.indices.contains(selectedIndex) {
                    let mask = masks[selectedIndex]
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(maskTitle(mask))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(palette.textPrimary)
                            Spacer()
                            Text("#\(mask.serializationOrdinal ?? (selectedIndex + 1))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(palette.textSecondary)
                        }
                        Divider()
                        valueRow("Shape", shapeName(mask))
                        valueRow("Position", positionDescription(mask))
                        valueRow("Size", sizeDescription(mask))
                        valueRow("Fill", mask.extras["fill"] ?? "Default")
                        valueRow("Occludes inactive", mask.occludesInactive ? "Yes" : "No")
                        if case .text(_, _, let text, _, _, _) = mask {
                            valueRow("Prompt", text.isEmpty ? "—" : text)
                            Button("Edit Prompt…", systemImage: "pencil") {
                                onEditText()
                            }
                            .buttonStyle(.bordered)
                            .accessibilityLabel("Edit mask prompt")
                        }
                    }
                    .padding(12)
                    .background(palette.surfaceElevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                    HStack {
                        Button("Duplicate", systemImage: "plus.square.on.square", action: onDuplicate)
                            .buttonStyle(.bordered)
                        Spacer()
                        Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
                            .buttonStyle(.bordered)
                    }
                } else {
                    ContentUnavailableView(
                        "No Mask Selected",
                        systemImage: "square.dashed",
                        description: Text("Select a mask on the image to inspect its geometry.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 180)
                }
            }
            .padding(16)
        }
        .background(palette.surface)
        .contextMenu {
            Button("Duplicate Selected Mask", systemImage: "plus.square.on.square", action: onDuplicate)
                .disabled(selectedIndex == nil)
            Button("Delete Selected Mask", systemImage: "trash", role: .destructive, action: onDelete)
                .disabled(selectedIndex == nil)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mask inspector")
    }

    private func valueRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(palette.textSecondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.caption.weight(.medium))
                .foregroundStyle(palette.textPrimary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
    }

    private func maskTitle(_ mask: IOMask) -> String {
        switch mask {
        case .rect: "Rectangle"
        case .ellipse: "Ellipse"
        case .polygon: "Polygon"
        case .text: "Text prompt"
        }
    }

    private func shapeName(_ mask: IOMask) -> String {
        switch mask {
        case .rect: "Rectangle"
        case .ellipse: "Ellipse"
        case .polygon(let points, _): "Polygon (\(points.count) points)"
        case .text: "Text"
        }
    }

    private func positionDescription(_ mask: IOMask) -> String {
        switch mask {
        case .rect(let left, let top, _, _, _),
             .ellipse(let left, let top, _, _, _),
             .text(let left, let top, _, _, _, _):
            return "\(percent(left)), \(percent(top))"
        case .polygon(let points, _):
            guard let first = points.first else { return "—" }
            return "\(percent(first.x)), \(percent(first.y))"
        }
    }

    private func sizeDescription(_ mask: IOMask) -> String {
        switch mask {
        case .rect(_, _, let width, let height, _):
            return "\(percent(width)) × \(percent(height))"
        case .ellipse(_, _, let rx, let ry, _):
            return "\(percent(rx * 2)) × \(percent(ry * 2))"
        case .polygon(let points, _):
            let xs = points.map(\.x)
            let ys = points.map(\.y)
            guard let minX = xs.min(), let maxX = xs.max(),
                  let minY = ys.min(), let maxY = ys.max() else { return "—" }
            return "\(percent(maxX - minX)) × \(percent(maxY - minY))"
        case .text(_, _, _, let scale, let fontSize, _):
            return "Scale \(decimal(scale)), font \(decimal(fontSize))"
        }
    }

    private func decimal(_ value: CGFloat) -> String {
        String(format: "%.2f", Double(value))
    }

    private func percent(_ value: CGFloat) -> String {
        "\(Int((value * 100).rounded()))%"
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
}

// MARK: - Chrome components

/// The palette and the two bottom toolbars are separate `View` types rather
/// than computed properties on the workspace so a `masks` mutation — which
/// the canvas performs on every frame of a drag, via the `$model.masks`
/// binding — re-evaluates only the canvas. As computed properties they shared
/// the workspace's invalidation boundary, so every drag frame also rebuilt
/// three `ForEach`es, four `Menu`s and ~13 buttons, each of which resolves its
/// SF Symbol through `UIImage(systemName:)`.
///
/// The `Equatable` conformances compare only the value inputs. The action
/// closures are freshly allocated on each parent body pass and would otherwise
/// always compare unequal, which would defeat the skip entirely.
private struct IOToolPalette: View, Equatable {
    @Environment(\.palette) private var palette

    let shapeType: IOShapeType
    let hasSelection: Bool
    let onSelectTool: (IOShapeType) -> Void
    let onApplyFill: (String?) -> Void
    let onCustomFill: () -> Void
    let onSelectOcclusionMode: (IOOcclusionMode) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.shapeType == rhs.shapeType && lhs.hasSelection == rhs.hasSelection
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(IOShapeType.allCases, id: \.self) { tool in
                Button {
                    onSelectTool(tool)
                } label: {
                    IOPaletteChip(
                        title: tool.label,
                        systemImage: tool.systemImage,
                        isSelected: shapeType == tool
                    )
                }
                .buttonStyle(.pressScale)
                .frame(maxWidth: .infinity)
                .accessibilityLabel(tool.label)
                .help(tool.label)
            }

            Menu {
                ForEach(IOMaskFillOption.allCases, id: \.self) { option in
                    Button(option.label) { onApplyFill(option.hex) }
                }
                Divider()
                Button("Custom") { onCustomFill() }
                Button("Default") { onApplyFill(nil) }
            } label: {
                IOPaletteChip(title: "Fill", systemImage: "paintpalette", isSelected: false)
            }
            .frame(maxWidth: .infinity)
            .disabled(!hasSelection)
            .accessibilityLabel("Mask fill")
            .help("Choose mask fill")

            Menu {
                ForEach(IOOcclusionMode.allCases, id: \.self) { mode in
                    Button(mode.label) { onSelectOcclusionMode(mode) }
                }
            } label: {
                IOPaletteChip(title: "Mode", systemImage: "square.stack.3d.up", isSelected: false)
            }
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Occlusion mode")
            .help("Choose what inactive masks hide")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(palette.surface)
    }
}

private struct IOEditingToolbar: View, Equatable {
    let selectionCount: Int
    let hasMasks: Bool
    let allMasksSelected: Bool
    let showsTranslucentMasks: Bool
    /// Held as the manager rather than as `onUndo`/`onRedo` closures: when
    /// `==` returns true SwiftUI keeps the *old* view value, closures and all,
    /// so a captured manager would outlive an `undoManager` swap that left
    /// `canUndo`/`canRedo` unchanged. Identity is part of the comparison.
    let undoManager: UndoManager?
    let canUndo: Bool
    let canRedo: Bool
    let onDelete: () -> Void
    let onDuplicate: () -> Void
    let onToggleSelectAll: () -> Void
    let onInvertSelection: () -> Void
    let onToggleTranslucency: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.selectionCount == rhs.selectionCount
            && lhs.hasMasks == rhs.hasMasks
            && lhs.allMasksSelected == rhs.allMasksSelected
            && lhs.showsTranslucentMasks == rhs.showsTranslucentMasks
            && lhs.undoManager === rhs.undoManager
            && lhs.canUndo == rhs.canUndo
            && lhs.canRedo == rhs.canRedo
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                IOToolbarIconButton(systemImage: "arrow.uturn.backward") { undoManager?.undo() }
                    .disabled(!canUndo)

                IOToolbarIconButton(systemImage: "arrow.uturn.forward") { undoManager?.redo() }
                    .disabled(!canRedo)

                IOToolbarIconButton(systemImage: "trash", action: onDelete)
                    .disabled(selectionCount == 0)

                IOToolbarIconButton(systemImage: "plus.square.on.square", action: onDuplicate)
                    .disabled(selectionCount == 0)

                IOToolbarIconButton(
                    systemImage: allMasksSelected ? "checkmark.circle.fill" : "checkmark.circle",
                    action: onToggleSelectAll
                )
                .disabled(!hasMasks)

                IOToolbarIconButton(systemImage: "arrow.left.arrow.right", action: onInvertSelection)
                    .disabled(!hasMasks)

                IOToolbarIconButton(
                    systemImage: showsTranslucentMasks ? "circle.lefthalf.filled" : "circle",
                    action: onToggleTranslucency
                )
                .disabled(!hasMasks)
            }
            .padding(.horizontal, 16)
        }
    }
}

private struct IOArrangeToolbar: View, Equatable {
    let selectionCount: Int
    let canUngroup: Bool
    let onGroup: () -> Void
    let onUngroup: () -> Void
    let onAlign: (IOMaskAlignMode) -> Void
    let onZoom: (IOCanvasZoomCommand) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.selectionCount == rhs.selectionCount && lhs.canUngroup == rhs.canUngroup
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                IOToolbarIconButton(systemImage: "link", action: onGroup)
                    .disabled(selectionCount < 2)

                IOToolbarIconButton(
                    systemImage: "link.slash",
                    fallbackSystemImage: "scissors",
                    action: onUngroup
                )
                .disabled(!canUngroup)

                Menu {
                    ForEach(IOMaskAlignMode.allCases, id: \.self) { mode in
                        Button(mode.label) { onAlign(mode) }
                    }
                } label: {
                    IOToolbarIcon(systemImage: "align.horizontal.left")
                }
                .disabled(selectionCount == 0)
                .accessibilityLabel("Align selected masks")

                IOToolbarIconButton(systemImage: "plus.magnifyingglass") { onZoom(.zoomIn) }
                IOToolbarIconButton(systemImage: "minus.magnifyingglass") { onZoom(.zoomOut) }
                IOToolbarIconButton(
                    systemImage: "arrow.up.left.and.down.right.magnifyingglass"
                ) { onZoom(.fit) }
            }
            .padding(.horizontal, 16)
        }
    }
}

private struct IOPaletteChip: View {
    @Environment(\.palette) private var palette

    let title: String
    let systemImage: String
    let isSelected: Bool

    var body: some View {
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
        .background(
            isSelected ? palette.accent : palette.surfaceElevated,
            in: RoundedRectangle(cornerRadius: AmgiRadius.inset, style: .continuous)
        )
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct IOToolbarIconButton: View {
    let systemImage: String
    var fallbackSystemImage: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            IOToolbarIcon(systemImage: systemImage, fallbackSystemImage: fallbackSystemImage)
        }
        .buttonStyle(.pressScale)
        .accessibilityLabel(accessibilityName)
        .help(accessibilityName)
    }

    private var accessibilityName: String {
        switch systemImage {
        case "arrow.uturn.backward": "Undo"
        case "arrow.uturn.forward": "Redo"
        case "trash": "Delete selected masks"
        case "plus.square.on.square": "Duplicate selected masks"
        case "checkmark.circle", "checkmark.circle.fill": "Select all masks"
        case "arrow.left.arrow.right": "Invert mask selection"
        case "circle", "circle.lefthalf.filled": "Toggle mask translucency"
        case "link": "Group selected masks"
        case "link.slash", "scissors": "Ungroup selected masks"
        case "plus.magnifyingglass": "Zoom in"
        case "minus.magnifyingglass": "Zoom out"
        case "arrow.up.left.and.down.right.magnifyingglass": "Fit image to window"
        default: "Image occlusion action"
        }
    }
}

private struct IOToolbarIcon: View {
    let systemImage: String
    var fallbackSystemImage: String? = nil

    var body: some View {
        // Only the one caller that passes a fallback pays for the lookup;
        // probing `UIImage(systemName:)` for the rest just discards the result.
        let resolvedSymbol = if let fallbackSystemImage, !isSystemImageAvailable(systemImage) {
            fallbackSystemImage
        } else {
            systemImage
        }

        Image(systemName: resolvedSymbol)
            .font(.system(size: 13, weight: .semibold))
            .amgiToolbarIconButton(size: 30)
    }
}

private func isSystemImageAvailable(_ name: String) -> Bool {
    #if canImport(UIKit)
    UIImage(systemName: name) != nil
    #elseif canImport(AppKit)
    NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
    #else
    true
    #endif
}

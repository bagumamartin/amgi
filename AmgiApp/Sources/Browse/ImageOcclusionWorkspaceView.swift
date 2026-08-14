import SwiftUI
import UIKit
import AmgiTheme
import AmgiUI

// MARK: - Workspace private types

private struct IOMaskSnapshot: Equatable {
    var masks: [IOMask]
    var selectedMaskIndex: Int?
    var selectedMaskIndices: Set<Int>
}

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

private enum IOMaskAlignMode: CaseIterable {
    case left
    case horizontalCenter
    case right
    case top
    case verticalCenter
    case bottom

    var label: String {
        switch self {
        case .left:             return "Align left"
        case .horizontalCenter: return "Center horizontally"
        case .right:            return "Align right"
        case .top:              return "Align top"
        case .verticalCenter:   return "Center vertically"
        case .bottom:           return "Align bottom"
        }
    }
}

private enum IOOcclusionMode: CaseIterable {
    case hideAllGuessOne
    case hideOneGuessOne

    var label: String {
        switch self {
        case .hideAllGuessOne: return "Hide all, guess one"
        case .hideOneGuessOne: return "Hide one, guess one"
        }
    }

    var occludesInactive: Bool {
        switch self {
        case .hideAllGuessOne: return true
        case .hideOneGuessOne: return false
        }
    }
}

// MARK: - ImageOcclusionWorkspaceView

struct ImageOcclusionWorkspaceView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.undoManager) private var undoManager
    @Environment(\.palette) private var palette

    let title: String
    let image: UIImage
    let initialMasks: [IOMask]
    let onSave: ([IOMask]) -> Void

    @State private var masks: [IOMask]
    @State private var selectedMaskIndex: Int?
    @State private var selectedMaskIndices: Set<Int>
    @State private var shapeType: IOShapeType
    @State private var pendingTextPoint: CGPoint?
    @State private var pendingTextValue = ""
    @State private var pendingTextMaskIndex: Int?
    @State private var pendingTextColor = Color.black
    @State private var showTextEditor = false
    @State private var showFillEditor = false
    @State private var fillEditorColor = Color.yellow
    @State private var showDiscardConfirmation = false
    @State private var showsTranslucentMasks = true
    @State private var occlusionMode: IOOcclusionMode
    @State private var transformStartSnapshot: IOMaskSnapshot?
    @State private var zoomCommand: IOCanvasZoomCommand = .fit
    @State private var zoomCommandID = 0

    init(title: String, image: UIImage, initialMasks: [IOMask], onSave: @escaping ([IOMask]) -> Void) {
        self.title = title
        self.image = image
        self.initialMasks = initialMasks
        self.onSave = onSave
        _masks = State(initialValue: initialMasks)
        let initialSelection = initialMasks.indices.first
        _selectedMaskIndex = State(initialValue: initialSelection)
        _selectedMaskIndices = State(initialValue: initialSelection.map { Set([$0]) } ?? [])
        _shapeType = State(initialValue: initialMasks.isEmpty ? .rect : .select)
        _occlusionMode = State(initialValue: initialMasks.contains(where: \.occludesInactive) ? .hideAllGuessOne : .hideOneGuessOne)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolPalette

            ZoomableOcclusionCanvasView(
                image: image,
                masks: $masks,
                selectedMaskIndex: $selectedMaskIndex,
                selectedMaskIndices: highlightedMaskIndices,
                highlightedMaskIndices: highlightedMaskIndices,
                shapeType: shapeType,
                maskOpacity: showsTranslucentMasks ? 0.72 : 0.94,
                zoomCommand: zoomCommand,
                zoomCommandID: zoomCommandID,
                onRequestText: beginTextInsertion(at:),
                onRequestTextEdit: beginTextEditing(maskIndex:),
                onAppend: appendMask(_:),
                onSelectionChange: handleCanvasSelectionChange(_:),
                onTransformDidBegin: handleTransformDidBegin,
                onTransformDidEnd: handleTransformDidEnd
            )
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(palette.background)
        }
        .toolbar(.hidden, for: .tabBar)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") { requestDismiss() }
                    .amgiToolbarTextButton(tone: .neutral)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") { saveWorkspace() }
                .amgiToolbarTextButton()
            }
        }
        .safeAreaInset(edge: .bottom) {
            bottomToolbars
        }
        .confirmationDialog("Discard changes?", isPresented: $showDiscardConfirmation, titleVisibility: .visible) {
            Button("Discard", role: .destructive) {
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Unsaved changes will be lost.")
        }
        .sheet(isPresented: $showTextEditor) {
            textEditorSheet
        }
        .sheet(isPresented: $showFillEditor) {
            fillEditorSheet
        }
    }

    private var activeSelectionIndices: [Int] {
        let filtered = selectedMaskIndices.filter { masks.indices.contains($0) }
        if !filtered.isEmpty {
            return filtered.sorted()
        }

        guard let selectedMaskIndex, masks.indices.contains(selectedMaskIndex) else {
            return []
        }
        return [selectedMaskIndex]
    }

    private var highlightedMaskIndices: Set<Int> {
        Set(activeSelectionIndices)
    }

    private var allMasksSelected: Bool {
        !masks.isEmpty && highlightedMaskIndices.count == masks.count
    }

    private var hasUnsavedChanges: Bool {
        masks != initialMasks
    }

    private var textEditorTitle: String {
        pendingTextMaskIndex == nil ? "Prompt" : "Edit text"
    }

    private var toolPalette: some View {
        HStack(spacing: 4) {
            ForEach(IOShapeType.allCases, id: \.self) { tool in
                ioPaletteButton(
                    title: tool.label,
                    systemImage: tool.systemImage,
                    isSelected: shapeType == tool
                ) {
                    shapeType = tool
                }
                .frame(maxWidth: .infinity)
            }

            Menu {
                ForEach(IOMaskFillOption.allCases, id: \.self) { option in
                    Button(option.label) {
                        applyFill(option.hex)
                    }
                }
                Divider()
                Button("Custom") {
                    openFillEditor()
                }
                Button("Default") {
                    applyFill(nil)
                }
            } label: {
                ioPaletteChip(
                    title: "Fill",
                    systemImage: "paintpalette",
                    isSelected: false
                )
            }
            .frame(maxWidth: .infinity)
            .disabled(activeSelectionIndices.isEmpty)

            Menu {
                ForEach(IOOcclusionMode.allCases, id: \.self) { mode in
                    Button(mode.label) {
                        applyOcclusionMode(mode)
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
                        deleteSelection()
                    }
                    .disabled(activeSelectionIndices.isEmpty)

                    toolbarIconButton(systemImage: "plus.square.on.square") {
                        duplicateSelection()
                    }
                    .disabled(activeSelectionIndices.isEmpty)

                    toolbarIconButton(systemImage: allMasksSelected ? "checkmark.circle.fill" : "checkmark.circle") {
                        toggleSelectAll()
                    }
                    .disabled(masks.isEmpty)

                    toolbarIconButton(systemImage: "arrow.left.arrow.right") {
                        invertSelection()
                    }
                    .disabled(masks.isEmpty)

                    toolbarIconButton(systemImage: showsTranslucentMasks ? "circle.lefthalf.filled" : "circle") {
                        showsTranslucentMasks.toggle()
                    }
                    .disabled(masks.isEmpty)
                }
                .padding(.horizontal, 16)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    toolbarIconButton(systemImage: "link") {
                        groupSelection()
                    }
                    .disabled(activeSelectionIndices.count < 2)

                    toolbarIconButton(systemImage: "link.slash", fallbackSystemImage: "scissors") {
                        ungroupSelection()
                    }
                    .disabled(activeSelectionIndices.isEmpty || !activeSelectionIndices.contains(where: { masks[$0].serializationOrdinal != nil }))

                    Menu {
                        ForEach(IOMaskAlignMode.allCases, id: \.self) { mode in
                            Button(mode.label) {
                                alignSelection(mode)
                            }
                        }
                    } label: {
                        toolbarIcon(systemImage: "align.horizontal.left")
                    }
                    .disabled(activeSelectionIndices.isEmpty)

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
        .padding(.top, 10)
        .padding(.bottom, 10)
        .background(palette.surface)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private var textEditorSheet: some View {
        NavigationStack {
            Form {
                Section("Prompt") {
                    TextField("Enter prompt text", text: $pendingTextValue, axis: .vertical)
                        .lineLimit(3...6)
                }

                Section("Text color") {
                    ColorPicker("Custom", selection: $pendingTextColor, supportsOpacity: true)
                }
            }
            .scrollContentBackground(.hidden)
            .background(palette.background)
            .navigationTitle(textEditorTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        closeTextEditor()
                    }
                    .amgiToolbarTextButton(tone: .neutral)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        insertOrUpdateTextMask()
                    }
                    .amgiToolbarTextButton()
                    .disabled(pendingTextValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private var fillEditorSheet: some View {
        NavigationStack {
            Form {
                Section("Custom") {
                    ColorPicker("Custom", selection: $fillEditorColor, supportsOpacity: true)
                }
            }
            .scrollContentBackground(.hidden)
            .background(palette.background)
            .navigationTitle("Custom")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        showFillEditor = false
                    }
                    .amgiToolbarTextButton(tone: .neutral)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Default") {
                        showFillEditor = false
                        applyFill(nil)
                    }
                    .amgiToolbarTextButton(tone: .neutral)

                    Button("Save") {
                        showFillEditor = false
                        applyFill(hexString(for: fillEditorColor))
                    }
                    .amgiToolbarTextButton()
                }
            }
        }
    }

}

private extension ImageOcclusionWorkspaceView {
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

    func handleCanvasSelectionChange(_ selection: OcclusionCanvasView.IOCanvasSelectionChange) {
        switch selection {
        case .replace(let index):
            guard let index, masks.indices.contains(index) else {
                selectedMaskIndex = nil
                selectedMaskIndices = []
                return
            }
            let group = groupedSelectionIndices(for: index)
            selectedMaskIndex = index
            selectedMaskIndices = group
        case .toggle(let index):
            guard masks.indices.contains(index) else { return }
            let group = groupedSelectionIndices(for: index)
            if group.isSubset(of: selectedMaskIndices) {
                selectedMaskIndices.subtract(group)
                if selectedMaskIndices.isEmpty {
                    selectedMaskIndex = nil
                } else if let selectedMaskIndex, !selectedMaskIndices.contains(selectedMaskIndex) {
                    self.selectedMaskIndex = selectedMaskIndices.sorted().first
                }
            } else {
                selectedMaskIndices.formUnion(group)
                selectedMaskIndex = index
            }
        }
    }

    func beginTextInsertion(at point: CGPoint) {
        pendingTextPoint = point
        pendingTextMaskIndex = nil
        pendingTextValue = ""
        pendingTextColor = .black
        showTextEditor = true
    }

    func beginTextEditing(maskIndex: Int) {
        guard masks.indices.contains(maskIndex),
              case .text(_, _, let text, _, _, let extras) = masks[maskIndex] else {
            return
        }
        pendingTextPoint = nil
        pendingTextMaskIndex = maskIndex
        pendingTextValue = text
        pendingTextColor = color(from: extras["fill"], fallback: .black)
        showTextEditor = true
    }

    func closeTextEditor() {
        pendingTextPoint = nil
        pendingTextMaskIndex = nil
        pendingTextValue = ""
        showTextEditor = false
    }

    func insertOrUpdateTextMask() {
        let text = pendingTextValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let fillHex = hexString(for: pendingTextColor)

        if let pendingTextMaskIndex, masks.indices.contains(pendingTextMaskIndex) {
            var updatedMasks = masks
            updatedMasks[pendingTextMaskIndex] = updatedMasks[pendingTextMaskIndex].updatingText(text, fillHex: fillHex)
            commitSnapshot(
                IOMaskSnapshot(
                    masks: updatedMasks,
                    selectedMaskIndex: pendingTextMaskIndex,
                    selectedMaskIndices: groupedSelectionIndices(for: pendingTextMaskIndex, in: updatedMasks)
                )
            )
        } else if let pendingTextPoint {
            appendMask(
                .text(
                    left: pendingTextPoint.x,
                    top: pendingTextPoint.y,
                    text: text,
                    scale: 1,
                    fontSize: 0.055,
                    extras: ["fill": fillHex]
                )
            )
        }

        closeTextEditor()
    }

    func appendMask(_ mask: IOMask) {
        var updatedMasks = masks
        updatedMasks.append(mask.applyingOccludeInactive(occlusionMode.occludesInactive))
        let newIndex = updatedMasks.count - 1
        commitSnapshot(
            IOMaskSnapshot(
                masks: updatedMasks,
                selectedMaskIndex: newIndex,
                selectedMaskIndices: [newIndex]
            )
        )
    }

    func deleteSelection() {
        let indices = activeSelectionIndices
        guard !indices.isEmpty else { return }
        let indexSet = Set(indices)
        let updatedMasks = masks.enumerated().compactMap { index, mask in
            indexSet.contains(index) ? nil : mask
        }
        let newSelection = updatedMasks.indices.first.map { Set([$0]) } ?? []
        commitSnapshot(
            IOMaskSnapshot(
                masks: updatedMasks,
                selectedMaskIndex: newSelection.sorted().first,
                selectedMaskIndices: newSelection
            )
        )
    }

    func duplicateSelection() {
        let indices = activeSelectionIndices
        guard !indices.isEmpty else { return }

        var updatedMasks = masks
        var duplicatedIndices: Set<Int> = []
        var ordinalMapping: [Int: Int] = [:]

        for index in indices {
            var duplicate = offset(mask: masks[index], dx: 0.03, dy: 0.03).applyingSerializationOrdinal(nil)
            if let ordinal = masks[index].serializationOrdinal {
                let mappedOrdinal = ordinalMapping[ordinal] ?? nextAvailableOrdinal(in: updatedMasks, reserved: Set(ordinalMapping.values))
                ordinalMapping[ordinal] = mappedOrdinal
                duplicate = duplicate.applyingSerializationOrdinal(mappedOrdinal)
            }
            updatedMasks.append(duplicate)
            duplicatedIndices.insert(updatedMasks.count - 1)
        }

        commitSnapshot(
            IOMaskSnapshot(
                masks: updatedMasks,
                selectedMaskIndex: duplicatedIndices.sorted().first,
                selectedMaskIndices: duplicatedIndices
            )
        )
    }

    func toggleSelectAll() {
        guard !masks.isEmpty else { return }
        if allMasksSelected {
            selectedMaskIndices = []
            selectedMaskIndex = nil
        } else {
            selectedMaskIndices = Set(masks.indices)
            selectedMaskIndex = masks.indices.first
        }
    }

    func invertSelection() {
        guard !masks.isEmpty else { return }
        let inverted = Set(masks.indices).subtracting(selectedMaskIndices)
        selectedMaskIndices = inverted
        if let selectedMaskIndex, inverted.contains(selectedMaskIndex) {
            return
        }
        self.selectedMaskIndex = inverted.sorted().first
    }

    func openFillEditor() {
        fillEditorColor = color(from: activeSelectionIndices.first.flatMap { masks[$0].extras["fill"] }, fallback: .yellow)
        showFillEditor = true
    }

    func applyFill(_ hex: String?) {
        let indices = activeSelectionIndices
        guard !indices.isEmpty else { return }

        var updatedMasks = masks
        for index in indices {
            updatedMasks[index] = updatedMasks[index].applyingFill(hex)
        }
        commitSnapshot(
            IOMaskSnapshot(
                masks: updatedMasks,
                selectedMaskIndex: selectedMaskIndex,
                selectedMaskIndices: Set(indices)
            )
        )
    }

    func applyOcclusionMode(_ mode: IOOcclusionMode) {
        occlusionMode = mode
        guard !masks.isEmpty else { return }

        let updatedMasks = masks.map { $0.applyingOccludeInactive(mode.occludesInactive) }
        commitSnapshot(
            IOMaskSnapshot(
                masks: updatedMasks,
                selectedMaskIndex: selectedMaskIndex,
                selectedMaskIndices: Set(activeSelectionIndices)
            )
        )
    }

    func groupSelection() {
        let indices = activeSelectionIndices
        guard indices.count >= 2 else { return }
        let targetOrdinal = indices.compactMap { masks[$0].serializationOrdinal }.min()
            ?? nextAvailableOrdinal(in: masks)
        var updatedMasks = masks
        for index in indices {
            updatedMasks[index] = updatedMasks[index].applyingSerializationOrdinal(targetOrdinal)
        }
        commitSnapshot(
            IOMaskSnapshot(
                masks: updatedMasks,
                selectedMaskIndex: selectedMaskIndex,
                selectedMaskIndices: Set(indices)
            )
        )
    }

    func ungroupSelection() {
        let indices = activeSelectionIndices
        guard !indices.isEmpty else { return }
        var updatedMasks = masks
        for index in indices {
            updatedMasks[index] = updatedMasks[index].applyingSerializationOrdinal(nil)
        }
        commitSnapshot(
            IOMaskSnapshot(
                masks: updatedMasks,
                selectedMaskIndex: selectedMaskIndex,
                selectedMaskIndices: Set(indices)
            )
        )
    }

    func alignSelection(_ mode: IOMaskAlignMode) {
        let indices = activeSelectionIndices
        guard !indices.isEmpty else { return }

        let canvasBounds = CGRect(x: 0, y: 0, width: 1, height: 1)
        var updatedMasks = masks
        for index in indices {
            let maskBounds = normalizedBounds(for: updatedMasks[index])
            let delta: CGPoint
            switch mode {
            case .left:
                delta = CGPoint(x: canvasBounds.minX - maskBounds.minX, y: 0)
            case .horizontalCenter:
                delta = CGPoint(x: canvasBounds.midX - maskBounds.midX, y: 0)
            case .right:
                delta = CGPoint(x: canvasBounds.maxX - maskBounds.maxX, y: 0)
            case .top:
                delta = CGPoint(x: 0, y: canvasBounds.minY - maskBounds.minY)
            case .verticalCenter:
                delta = CGPoint(x: 0, y: canvasBounds.midY - maskBounds.midY)
            case .bottom:
                delta = CGPoint(x: 0, y: canvasBounds.maxY - maskBounds.maxY)
            }
            updatedMasks[index] = offset(mask: updatedMasks[index], dx: delta.x, dy: delta.y)
        }

        commitSnapshot(
            IOMaskSnapshot(
                masks: updatedMasks,
                selectedMaskIndex: selectedMaskIndex,
                selectedMaskIndices: Set(indices)
            )
        )
    }

    func requestDismiss() {
        if hasUnsavedChanges {
            showDiscardConfirmation = true
        } else {
            dismiss()
        }
    }

    func saveWorkspace() {
        onSave(masks)
        dismiss()
    }

    func handleTransformDidBegin() {
        if transformStartSnapshot == nil {
            transformStartSnapshot = currentSnapshot()
        }
    }

    func handleTransformDidEnd() {
        guard let previousSnapshot = transformStartSnapshot else { return }
        transformStartSnapshot = nil
        let current = currentSnapshot()
        guard current != previousSnapshot else { return }
        registerUndo(previous: previousSnapshot, current: current)
    }

    func sendZoomCommand(_ command: IOCanvasZoomCommand) {
        zoomCommand = command
        zoomCommandID += 1
    }

    func groupedSelectionIndices(for index: Int, in masks: [IOMask]? = nil) -> Set<Int> {
        let resolvedMasks = masks ?? self.masks
        guard resolvedMasks.indices.contains(index) else { return [] }
        guard let ordinal = resolvedMasks[index].serializationOrdinal else {
            return [index]
        }
        return Set(resolvedMasks.indices.filter { resolvedMasks[$0].serializationOrdinal == ordinal })
    }

    func nextAvailableOrdinal(in masks: [IOMask], reserved: Set<Int> = []) -> Int {
        let currentMax = masks.compactMap(\.serializationOrdinal).max() ?? 0
        var candidate = currentMax + 1
        while reserved.contains(candidate) {
            candidate += 1
        }
        return candidate
    }

    func color(from hex: String?, fallback: Color) -> Color {
        guard let hex, let color = workspaceUIColor(ioHex: hex) else {
            return fallback
        }
        return Color(uiColor: color)
    }

    func hexString(for color: Color) -> String {
        let uiColor = UIColor(color)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return String(
            format: "%02X%02X%02X%02X",
            Int(round(red * 255)),
            Int(round(green * 255)),
            Int(round(blue * 255)),
            Int(round(alpha * 255))
        )
    }

    func workspaceUIColor(ioHex: String) -> UIColor? {
        let sanitized = ioHex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard sanitized.count == 6 || sanitized.count == 8,
              let value = UInt64(sanitized, radix: 16) else {
            return nil
        }

        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        let alpha: CGFloat

        if sanitized.count == 8 {
            red = CGFloat((value & 0xFF000000) >> 24) / 255
            green = CGFloat((value & 0x00FF0000) >> 16) / 255
            blue = CGFloat((value & 0x0000FF00) >> 8) / 255
            alpha = CGFloat(value & 0x000000FF) / 255
        } else {
            red = CGFloat((value & 0xFF0000) >> 16) / 255
            green = CGFloat((value & 0x00FF00) >> 8) / 255
            blue = CGFloat(value & 0x0000FF) / 255
            alpha = 1
        }

        return UIColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    func currentSnapshot() -> IOMaskSnapshot {
        IOMaskSnapshot(
            masks: masks,
            selectedMaskIndex: selectedMaskIndex,
            selectedMaskIndices: Set(activeSelectionIndices)
        )
    }

    func commitSnapshot(_ snapshot: IOMaskSnapshot) {
        let previous = currentSnapshot()
        applySnapshot(snapshot)
        registerUndo(previous: previous, current: snapshot)
    }

    func registerUndo(previous: IOMaskSnapshot, current: IOMaskSnapshot) {
        undoManager?.registerUndo(withTarget: UIApplication.shared) { _ in
            self.restoreSnapshot(previous, redo: current)
        }
    }

    func restoreSnapshot(_ snapshot: IOMaskSnapshot, redo: IOMaskSnapshot) {
        applySnapshot(snapshot)
        registerUndo(previous: redo, current: snapshot)
    }

    func applySnapshot(_ snapshot: IOMaskSnapshot) {
        masks = snapshot.masks
        selectedMaskIndices = snapshot.selectedMaskIndices.filter { snapshot.masks.indices.contains($0) }
        if let selectedMaskIndex = snapshot.selectedMaskIndex, snapshot.masks.indices.contains(selectedMaskIndex) {
            self.selectedMaskIndex = selectedMaskIndex
        } else {
            self.selectedMaskIndex = selectedMaskIndices.sorted().first
        }
        occlusionMode = snapshot.masks.contains(where: \.occludesInactive) ? .hideAllGuessOne : .hideOneGuessOne
    }

    func normalizedBounds(for mask: IOMask) -> CGRect {
        switch mask {
        case .rect(let left, let top, let width, let height, _):
            return CGRect(x: left, y: top, width: width, height: height)
        case .ellipse(let left, let top, let rx, let ry, _):
            return CGRect(x: left, y: top, width: rx * 2, height: ry * 2)
        case .polygon(let points, _):
            let xs = points.map(\.x)
            let ys = points.map(\.y)
            return CGRect(
                x: xs.min() ?? 0,
                y: ys.min() ?? 0,
                width: (xs.max() ?? 0) - (xs.min() ?? 0),
                height: (ys.max() ?? 0) - (ys.min() ?? 0)
            )
        case .text(let left, let top, let text, let scale, let fontSize, _):
            return CGRect(origin: CGPoint(x: left, y: top), size: normalizedTextSize(text: text, scale: scale, fontSize: fontSize))
        }
    }

    func normalizedTextSize(text: String, scale: CGFloat, fontSize: CGFloat) -> CGSize {
        let resolvedSize = max(14, image.size.height * max(fontSize, 0.02) * max(scale, 1))
        let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: resolvedSize, weight: .semibold)]
        let textSize = (text as NSString).size(withAttributes: attrs)
        return CGSize(
            width: min(1, (textSize.width + 20) / max(image.size.width, 1)),
            height: min(1, (textSize.height + 12) / max(image.size.height, 1))
        )
    }

    func offset(mask: IOMask, dx: CGFloat, dy: CGFloat) -> IOMask {
        switch mask {
        case .rect(let left, let top, let width, let height, let extras):
            return .rect(
                left: max(0, min(1 - width, left + dx)),
                top: max(0, min(1 - height, top + dy)),
                width: width,
                height: height,
                extras: extras
            )
        case .ellipse(let left, let top, let rx, let ry, let extras):
            return .ellipse(
                left: max(0, min(1 - rx * 2, left + dx)),
                top: max(0, min(1 - ry * 2, top + dy)),
                rx: rx,
                ry: ry,
                extras: extras
            )
        case .polygon(let points, let extras):
            let minX = points.map(\.x).min() ?? 0
            let maxX = points.map(\.x).max() ?? 1
            let minY = points.map(\.y).min() ?? 0
            let maxY = points.map(\.y).max() ?? 1
            let clampedDX = max(-minX, min(1 - maxX, dx))
            let clampedDY = max(-minY, min(1 - maxY, dy))
            let shifted = points.map {
                CGPoint(x: $0.x + clampedDX, y: $0.y + clampedDY)
            }
            return .polygon(points: shifted, extras: extras)
        case .text(let left, let top, let text, let scale, let fontSize, let extras):
            let size = normalizedTextSize(text: text, scale: scale, fontSize: fontSize)
            return .text(
                left: max(0, min(1 - size.width, left + dx)),
                top: max(0, min(1 - size.height, top + dy)),
                text: text,
                scale: scale,
                fontSize: fontSize,
                extras: extras
            )
        }
    }
}

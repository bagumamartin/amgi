package import SwiftUI
import AmgiAppCore
import AmgiTheme
import AmgiUI
package import AnkiKit
import Sharing
import SwiftUINavigation

/// Notetype/template editor — front, back, and CSS panes plus a render
/// preview. Container owns the editable `Notetype`; the cosmetic subviews
/// (`TemplateEditorHeaderCard`, `InsertFieldSearchBox`) and presentation
/// modifier (`TemplateEditorPresentations`) live below.
package struct TemplateEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.palette) private var palette
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let notetypeId: NotetypeID
    let previewNoteId: NoteID?
    let initialTemplateIndex: Int
    let mode: TemplateEditorMode
    var onSaved: (@Sendable () async -> Void)? = nil

    @Shared(.appStorage(CodeEditorPreferences.Keys.fontSize))
    private var codeEditorFontSize: Double = CodeEditorPreferences.defaultFontSize
    @Shared(.appStorage(CodeEditorPreferences.Keys.fontFamily))
    private var codeEditorFontFamilyRaw: String = CodeEditorPreferences.defaultFontFamily

    @State private var model = TemplateEditorModel()
    @State private var destination: TemplateEditorDestination?
    @State private var editorTab: TemplateEditorTab = .front
    @State private var editorSearchText = ""

    package init(
        notetypeId: NotetypeID,
        previewNoteId: NoteID? = nil,
        initialTemplateIndex: Int,
        mode: TemplateEditorMode,
        onSaved: (@Sendable () async -> Void)? = nil
    ) {
        self.notetypeId = notetypeId
        self.previewNoteId = previewNoteId
        self.initialTemplateIndex = initialTemplateIndex
        self.mode = mode
        self.onSaved = onSaved
    }

    private var currentTemplateValidationMessage: String? {
        templateValidationMessage(for: model.notetype)
    }

    private var canSaveTemplate: Bool {
        model.notetype.templates.indices.contains(model.selectedTemplateIndex)
            && currentTemplateValidationMessage == nil
            && !model.isSaving
    }

    private var separatorBorderColor: Color {
        colorScheme == .light
            ? palette.border.opacity(0.8)
            : palette.border.opacity(0.5)
    }

    private var currentTemplateName: String {
        guard model.notetype.templates.indices.contains(model.selectedTemplateIndex) else {
            return "No template selected."
        }
        return model.notetype.templates[model.selectedTemplateIndex].name
    }

    package var body: some View {
        NavigationStack {
            mainContent
                .background(palette.background)
                .navigationTitle(mode.title)
                .navigationBarTitleDisplayMode(.inline)
                .interactiveDismissDisabled(model.hasUnsavedChanges)
                .toolbar { toolbarContent }
                .modifier(TemplateEditorPresentations(
                    destination: $destination,
                    errorMessage: model.errorMessage,
                    onDiscard: { dismiss() },
                    fieldManager: { fieldManagerSheet },
                    preview: { previewSheet }
                ))
                .task { await model.loadNotetype(notetypeId: notetypeId, preferred: initialTemplateIndex) }
                .onKeyPress { press in
                    guard press.key == .escape else { return .ignored }
                    attemptDismiss()
                    return .handled
                }
        }
    }

    private var fieldManagerSheet: some View {
        NavigationStack {
            NotetypeFieldManagerView(
                notetypeId: notetypeId,
                preferredName: model.notetype.name,
                onSaved: {
                    await model.loadNotetype(
                        notetypeId: notetypeId,
                        preferred: model.selectedTemplateIndex
                    )
                    if let onSaved {
                        await onSaved()
                    }
                }
            )
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        if model.isLoading {
            ProgressView()
        } else if let errorMessage = model.errorMessage {
            AmgiStatusMessageView(
                title: "Could not load templates",
                message: errorMessage,
                systemImage: "exclamationmark.triangle",
                tone: .warning
            )
        } else {
            editorContent
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("Cancel") { attemptDismiss() }
                .amgiToolbarTextButton(tone: .neutral)
                .keyboardShortcut(.cancelAction)
        }
        ToolbarItem(placement: .principal) {
            Text(mode.title)
                .amgiFont(.bodyEmphasis)
                .foregroundStyle(palette.textPrimary)
                .lineLimit(1)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button("Fields") { destination = .fieldManager }
                .amgiToolbarTextButton(tone: .neutral)
                .disabled(model.isLoading || model.hasUnsavedChanges)
                .accessibilityHint(
                    model.hasUnsavedChanges
                        ? "Save template changes before editing fields"
                        : "Edit the fields in this notetype"
                )
        }
        ToolbarItem(placement: .topBarTrailing) {
            if model.isSaving {
                ProgressView()
            } else {
                Button("Save") {
                    Task {
                        if await model.saveTemplate(onSaved: onSaved) {
                            dismiss()
                        } else {
                            destination = .saveError
                        }
                    }
                }
                .amgiToolbarTextButton()
                .disabled(!canSaveTemplate)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var editorContent: some View {
        GeometryReader { proxy in
            let layout = TemplateEditorLayout.resolve(
                availableWidth: proxy.size.width,
                isAccessibilitySize: dynamicTypeSize.isAccessibilitySize
            )
            Group {
                switch layout {
                case .compact:
                    compactEditorLayout
                case .stacked:
                    stackedEditorLayout
                case .wide:
                    wideEditorLayout
                }
            }
            .background(palette.background)
        }
    }

    private var compactEditorLayout: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                editorHeader(allowsTemplateSelection: mode.allowsTemplateSelection)
                templateValidationStatus
                sourceEditor
                InsertFieldSearchBox(
                    searchText: $editorSearchText,
                    borderColor: separatorBorderColor
                )
            }
            .padding(20)
        }
    }

    private var stackedEditorLayout: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 18) {
                templateTree
                    .frame(maxWidth: .infinity)
                editorHeader(allowsTemplateSelection: false)
                templateValidationStatus
                sourceEditor
                    .frame(maxWidth: .infinity)
                InsertFieldSearchBox(
                    searchText: $editorSearchText,
                    borderColor: separatorBorderColor
                )
                TemplateEditorLivePreview(
                    notetype: model.notetype,
                    templateIndex: model.selectedTemplateIndex,
                    loadSampleFields: {
                        try await model.loadSampleFields(
                            notetypeId: notetypeId,
                            previewNoteId: previewNoteId
                        )
                    }
                )
                .frame(maxWidth: .infinity)
                .frame(minHeight: 420)
            }
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
            .padding(20)
        }
    }

    /// A regular-width editor gets the same mental model as a native Mac
    /// document window: templates on the left, source in the middle, and a
    /// live card surface on the right. It remains a single vertical page on
    /// iPhone, where three columns would make the code unreadable.
    private var wideEditorLayout: some View {
        ScrollView(.vertical) {
            HStack(alignment: .top, spacing: 16) {
                templateTree
                    .frame(width: 190)
                VStack(alignment: .leading, spacing: 16) {
                    editorHeader(allowsTemplateSelection: false)
                    templateValidationStatus
                    sourceEditor
                        .frame(minWidth: 420)
                    InsertFieldSearchBox(
                        searchText: $editorSearchText,
                        borderColor: separatorBorderColor
                    )
                }
                .frame(minWidth: 440, idealWidth: 560, maxWidth: 680)
                TemplateEditorLivePreview(
                    notetype: model.notetype,
                    templateIndex: model.selectedTemplateIndex,
                    loadSampleFields: {
                        try await model.loadSampleFields(
                            notetypeId: notetypeId,
                            previewNoteId: previewNoteId
                        )
                    }
                )
                .frame(minWidth: 300, idealWidth: 390, maxWidth: 520)
                .frame(minHeight: 560)
            }
            .padding(20)
        }
    }

    private var templateTree: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Templates")
                .amgiFont(.captionBold)
                .foregroundStyle(palette.textSecondary)
                .padding(.horizontal, 4)

            if model.notetype.templates.isEmpty {
                Text("No templates")
                    .amgiFont(.caption)
                    .foregroundStyle(palette.textTertiary)
                    .padding(.horizontal, 4)
            } else {
                ForEach(Array(model.notetype.templates.enumerated()), id: \.offset) { index, template in
                    let isSelected = index == model.selectedTemplateIndex
                    let row = HStack(spacing: 8) {
                        Image(systemName: isSelected
                            ? "largecircle.fill.circle"
                            : "circle")
                            .foregroundStyle(isSelected ? palette.accent : palette.textTertiary)
                        Text(template.name)
                            .amgiFont(.caption)
                            .foregroundStyle(palette.textPrimary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        isSelected ? palette.accentSoft : Color.clear,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )

                    Group {
                        if mode.allowsTemplateSelection {
                            Button {
                                model.selectedTemplateIndex = index
                            } label: {
                                row
                            }
                            .buttonStyle(.plain)
                        } else {
                            row
                        }
                    }
                    .accessibilityLabel(template.name)
                    .accessibilityValue(isSelected ? "Selected template" : "Template")
                    .contextMenu {
                        Button {
                            destination = .preview
                        } label: {
                            Label("Preview", systemImage: "eye")
                        }
                    }
                }
                .accessibilityElement(children: .contain)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(palette.surfaceElevated, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(separatorBorderColor, lineWidth: 1)
        }
    }

    private func editorHeader(allowsTemplateSelection: Bool) -> some View {
        TemplateEditorHeaderCard(
            currentTemplateName: currentTemplateName,
            allowsTemplateSelection: allowsTemplateSelection,
            templates: model.notetype.templates,
            selectedTemplateIndex: $model.selectedTemplateIndex,
            editorTab: $editorTab,
            onPreviewTab: { previousTab in
                destination = .preview
                editorTab = previousTab
            },
            borderColor: separatorBorderColor
        )
    }

    @ViewBuilder
    private var templateValidationStatus: some View {
        if let currentTemplateValidationMessage {
            AmgiStatusMessageView(
                title: "Template issue",
                message: currentTemplateValidationMessage,
                systemImage: "exclamationmark.triangle",
                tone: .warning
            )
        }
    }

    private var sourceEditor: some View {
        TemplateSourceEditor(
            text: currentEditorBinding,
            fieldNames: currentFieldNames,
            insertableTokens: currentInsertableTokens,
            fieldButtonTitle: "Fields",
            doneButtonTitle: "Done",
            searchQuery: editorSearchText,
            fontSize: codeEditorFontSize,
            fontFamilyRaw: codeEditorFontFamilyRaw
        )
        .padding(16)
        .frame(minHeight: 420)
        .background(palette.surfaceElevated, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(separatorBorderColor, lineWidth: 1)
        }
    }

    private var previewSheet: some View {
        TemplatePreviewSheet(
            title: "Rendered preview",
            emptyMessage: "This card has no content to preview.",
            notetype: model.notetype,
            initialTemplateIndex: model.selectedTemplateIndex,
            loadSampleFields: {
                try await model.loadSampleFields(notetypeId: notetypeId, previewNoteId: previewNoteId)
            }
        )
    }

    private var currentFieldNames: [String] {
        editorTab == .css ? [] : model.notetype.fields.map(\.name)
    }

    private var currentInsertableTokens: [String] {
        switch editorTab {
        case .front, .back, .preview:
            return ["(", ")", ".", "=", "#", "<br>", "{{FrontSide}}"]
        case .css:
            return ["{", "}", ":", ";", ".", "#"]
        }
    }

    private var currentEditorBinding: Binding<String> {
        switch editorTab {
        case .front:
            return qFormatBinding
        case .back:
            return aFormatBinding
        case .css:
            return cssBinding
        case .preview:
            return qFormatBinding
        }
    }

    private var qFormatBinding: Binding<String> {
        Binding(
            get: {
                guard model.notetype.templates.indices.contains(model.selectedTemplateIndex) else { return "" }
                return model.notetype.templates[model.selectedTemplateIndex].config.qFormat
            },
            set: { newValue in
                guard model.notetype.templates.indices.contains(model.selectedTemplateIndex) else { return }
                var config = model.notetype.templates[model.selectedTemplateIndex].config
                config.qFormat = newValue
                model.notetype.templates[model.selectedTemplateIndex].config = config
            }
        )
    }

    private var aFormatBinding: Binding<String> {
        Binding(
            get: {
                guard model.notetype.templates.indices.contains(model.selectedTemplateIndex) else { return "" }
                return model.notetype.templates[model.selectedTemplateIndex].config.aFormat
            },
            set: { newValue in
                guard model.notetype.templates.indices.contains(model.selectedTemplateIndex) else { return }
                var config = model.notetype.templates[model.selectedTemplateIndex].config
                config.aFormat = newValue
                model.notetype.templates[model.selectedTemplateIndex].config = config
            }
        )
    }

    private var cssBinding: Binding<String> {
        Binding(
            get: { model.notetype.config.css },
            set: { newValue in
                var config = model.notetype.config
                config.css = newValue
                model.notetype.config = config
            }
        )
    }

}

private extension TemplateEditorView {
    func attemptDismiss() {
        if model.hasUnsavedChanges {
            destination = .discardChanges
        } else {
            dismiss()
        }
    }
}

struct TemplateEditorPresentations<FieldManager: View, Preview: View>: ViewModifier {
    @Binding var destination: TemplateEditorDestination?
    let errorMessage: String?
    let onDiscard: () -> Void
    @ViewBuilder let fieldManager: () -> FieldManager
    @ViewBuilder let preview: () -> Preview

    func body(content: Content) -> some View {
        content
            .alert("Save failed", isPresented: $destination.saveError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "An unknown error occurred.")
            }
            .confirmationDialog(
                "Unsaved changes",
                isPresented: $destination.discardChanges,
                titleVisibility: .visible
            ) {
                Button("Discard", role: .destructive) { onDiscard() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You have unsaved changes. Discard them?")
            }
            .sheet(isPresented: $destination.fieldManager) { fieldManager() }
            .sheet(isPresented: $destination.preview) { preview() }
    }
}

enum TemplateEditorLayout: Equatable {
    case compact
    case stacked
    case wide

    static let minimumStackedWidth: CGFloat = 620
    static let minimumWideWidth: CGFloat = 1_040

    static func resolve(
        availableWidth: CGFloat,
        isAccessibilitySize: Bool
    ) -> TemplateEditorLayout {
        guard !isAccessibilitySize else { return .compact }
        if availableWidth >= minimumWideWidth { return .wide }
        if availableWidth >= minimumStackedWidth { return .stacked }
        return .compact
    }
}

// MARK: - Editor subviews

struct TemplateEditorHeaderCard: View {
    let currentTemplateName: String
    let allowsTemplateSelection: Bool
    let templates: [Notetype.Template]
    @Binding var selectedTemplateIndex: Int
    @Binding var editorTab: TemplateEditorTab
    let onPreviewTab: (TemplateEditorTab) -> Void
    let borderColor: Color

    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if allowsTemplateSelection, templates.count > 1 {
                HStack(spacing: 12) {
                    Text(currentTemplateName)
                        .amgiFont(.bodyEmphasis)
                        .foregroundStyle(palette.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    templatePickerMenu
                }
            } else {
                Text(currentTemplateName)
                    .amgiFont(.bodyEmphasis)
                    .foregroundStyle(palette.textSecondary)
            }

            Picker("Template Editor", selection: $editorTab) {
                ForEach(TemplateEditorTab.allCases, id: \.self) { tab in
                    Text(tab.label).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .onChange(of: editorTab) { old, new in
                if new == .preview {
                    onPreviewTab(old)
                }
            }
        }
        .padding(16)
        .background(palette.surfaceElevated, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(borderColor, lineWidth: 1)
        }
    }

    private var templatePickerMenu: some View {
        Menu {
            ForEach(Array(templates.enumerated()), id: \.offset) { index, template in
                Button {
                    selectedTemplateIndex = index
                } label: {
                    if selectedTemplateIndex == index {
                        Label(template.name, systemImage: "checkmark")
                    } else {
                        Text(template.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.up.chevron.down")
                    .amgiFont(.caption)
                    .foregroundStyle(palette.textSecondary)
            }
            .amgiCapsuleControl(horizontalPadding: 12, verticalPadding: 8)
        }
    }
}

struct InsertFieldSearchBox: View {
    @Binding var searchText: String
    let borderColor: Color

    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Insert field")
                .amgiFont(.captionBold)
                .foregroundStyle(palette.textSecondary)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(palette.textSecondary)
                TextField("Search fields", text: $searchText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(palette.surfaceElevated, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(borderColor, lineWidth: 1)
            }
        }
    }
}

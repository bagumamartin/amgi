package import SwiftUI
import AmgiTheme
import AmgiUI
import AnkiKit
package import Foundation

/// Format-aware import preflight and confirmation. The model owns staging,
/// inspection, option changes, and execution; this view only renders the
/// explicit state machine and follows the app's native Form/toolbar pattern.
package struct ImportReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    @State private var model: ImportReviewModel
    @State private var showReplaceConfirmation = false

    package init(
        sourceURL: URL,
        profileID: String,
        replaceCollection: @escaping @MainActor @Sendable (URL) async throws -> Void,
        beforeImport: @escaping @MainActor @Sendable () async throws -> Void = {},
        afterImport: @escaping @MainActor @Sendable () async -> Void = {},
        onComplete: @escaping @MainActor @Sendable () -> Void
    ) {
        _model = State(initialValue: ImportReviewModel(
            sourceURL: sourceURL,
            profileID: profileID,
            replaceCollection: replaceCollection,
            beforeImport: beforeImport,
            afterImport: afterImport,
            onComplete: onComplete
        ))
    }

    package var body: some View {
        NavigationStack {
            content
                .navigationTitle(model.navigationTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarContent }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(model.phase == .preparing || model.phase == .importing)
        .confirmationDialog(
            "Replace this collection?",
            isPresented: $showReplaceConfirmation,
            titleVisibility: .visible
        ) {
            Button("Replace Collection", role: .destructive) {
                model.startImport()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("All current decks, notes, cards, media, and settings will be replaced. Ijuka creates a temporary recovery package first.")
        }
        .task { await model.prepare() }
        .onDisappear { model.cancelAndCleanup() }
        #if os(macOS)
        .frame(minWidth: 560, idealWidth: 640, minHeight: 520)
        .presentationSizing(.fitted)
        #endif
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .preparing:
            preparingView
        case .review:
            reviewForm
        case .importing:
            importingView
        case .completed:
            completedView
        case .failed:
            failedView
        }
    }

    private var preparingView: some View {
        VStack(spacing: 18) {
            ProgressView()
                .controlSize(.large)
            VStack(spacing: 6) {
                Text("Inspecting File")
                    .amgiFont(.bodyEmphasis)
                Text("Reading \(model.sourceName)")
                    .amgiFont(.caption)
                    .foregroundStyle(palette.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Inspecting \(model.sourceName)")
    }

    private var reviewForm: some View {
        Form {
            sourceSection
            contentsSection
            optionsSection
            originalFileNote
            if let failureMessage = model.failureMessage {
                Section {
                    Label {
                        Text(failureMessage)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .foregroundStyle(palette.danger)
                }
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
    }

    private var sourceSection: some View {
        Section("File") {
            HStack(spacing: 14) {
                Image(systemName: model.format?.systemImage ?? "doc")
                    .amgiFont(.cardTitle)
                    .foregroundStyle(palette.accent)
                    .frame(width: 36, height: 44)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.sourceName)
                        .amgiFont(.bodyEmphasis)
                        .lineLimit(2)
                    if let byteCount = model.sourceByteCount {
                        Text(ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file))
                            .amgiFont(.caption)
                            .foregroundStyle(palette.textSecondary)
                    }
                }
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)

            if let format = model.format {
                LabeledContent("Type", value: format.title)
            }
        }
    }

    @ViewBuilder
    private var contentsSection: some View {
        switch model.format {
        case .deckPackage, .collectionPackage, .zippedPackage:
            packageContentsSection
        case .text:
            textContentsSection
        case .ankiJSON:
            jsonContentsSection
        case .mnemosyne:
            mnemosyneContentsSection
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder
    private var optionsSection: some View {
        switch model.format {
        case .deckPackage, .zippedPackage:
            packageOptionsSections
        case .collectionPackage:
            collectionReplacementSection
        case .text:
            textOptionsSections
        case .mnemosyne:
            mnemosyneOptionsSection
        case .ankiJSON, nil:
            EmptyView()
        }
    }

    // MARK: - Package

    @ViewBuilder
    private var packageContentsSection: some View {
        if let inspection = model.packageInspection {
            Section("Package Summary") {
                LabeledContent("Notes", value: inspection.noteCount.formatted())
                LabeledContent("Cards", value: inspection.cardCount.formatted())
                LabeledContent("Note Types", value: inspection.notetypeCount.formatted())
                LabeledContent("Media Files", value: inspection.mediaCount.formatted())
                LabeledContent("Archive Entries", value: inspection.archiveEntryCount.formatted())
                LabeledContent("Review History", value: inspection.reviewCount.formatted())
                LabeledContent("Format", value: packageFormatName(inspection.formatVersion))
                if !inspection.deckNames.isEmpty {
                    ForEach(inspection.deckNames.prefix(8), id: \.self) { deckName in
                        LabeledContent(deckName.count > 22 ? String(deckName.prefix(22)) + "…" : deckName) {
                            Image(systemName: "rectangle.stack")
                                .foregroundStyle(palette.textSecondary)
                                .accessibilityLabel("Deck included")
                        }
                    }
                    if inspection.deckNames.count > 8 {
                        Text("+ \(inspection.deckNames.count - 8) more decks")
                            .amgiFont(.caption)
                            .foregroundStyle(palette.textSecondary)
                    }
                }
            }
        }
    }

    private var packageOptionsSections: some View {
        Group {
            Section("Import Options") {
                Toggle("Include review history", isOn: Binding(
                    get: { model.packageOptions.withScheduling },
                    set: { model.setSchedulingIncluded($0) }
                ))
                Toggle("Include deck configurations", isOn: Binding(
                    get: { model.packageOptions.withDeckConfigs },
                    set: { model.setDeckConfigurationsIncluded($0) }
                ))
            }
            Section("Updates") {
                Toggle("Merge matching note types", isOn: Binding(
                    get: { model.packageOptions.mergeNotetypes },
                    set: { model.setMergeNoteTypes($0) }
                ))
                Picker("Existing notes", selection: Binding(
                    get: { model.packageOptions.updateNotes },
                    set: { model.setUpdateNotes($0) }
                )) {
                    ForEach(ImportPackageUpdateCondition.allCases, id: \.self) { condition in
                        Text(condition.label).tag(condition)
                    }
                }
                Picker("Existing note types", selection: Binding(
                    get: { model.packageOptions.updateNotetypes },
                    set: { model.setUpdateNoteTypes($0) }
                )) {
                    ForEach(ImportPackageUpdateCondition.allCases, id: \.self) { condition in
                        Text(condition.label).tag(condition)
                    }
                }
            }
        }
    }

    private var collectionReplacementSection: some View {
        Section {
            Label {
                Text("Replacing your collection deletes its current decks, notes, cards, media, and settings. A temporary recovery backup is created first.")
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .foregroundStyle(palette.danger)
        } header: {
            Text("Destructive Import")
        } footer: {
            Text("Sync should finish before you replace a collection. Ijuka cancels an active sync and creates a local recovery package first.")
        }
    }

    // MARK: - Delimited text

    @ViewBuilder
    private var textContentsSection: some View {
        if let metadata = model.csvMetadata {
            Section("Detected Columns") {
                Picker("Separator", selection: Binding(
                    get: { metadata.delimiter },
                    set: { value in Task { await model.updateTextFormat(delimiter: value) } }
                )) {
                    ForEach(ImportDelimiter.allCases, id: \.self) { delimiter in
                        Text(delimiter.label).tag(delimiter)
                    }
                }
                Toggle("File contains HTML", isOn: Binding(
                    get: { metadata.isHTML },
                    set: { value in Task { await model.updateTextFormat(isHTML: value) } }
                ))
                textPreview(metadata)
            }
        }
    }

    private func textPreview(_ metadata: CSVImportMetadata) -> some View {
        let rows = Array(metadata.preview.prefix(3))
        return Group {
            if rows.isEmpty {
                Label("No preview rows found", systemImage: "tablecells")
                    .foregroundStyle(palette.textSecondary)
            } else {
                ScrollView(.horizontal) {
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                        GridRow {
                            ForEach(columnChoices(metadata)) { choice in
                                Text(choice.shortLabel)
                                    .amgiFont(.micro, .monospaced)
                                    .foregroundStyle(palette.textSecondary)
                            }
                        }
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                            GridRow {
                                ForEach(0..<max(metadata.columnLabels.count, row.count), id: \.self) { index in
                                    Text(row.indices.contains(index) ? row[index] : "")
                                        .amgiFont(.caption, .monospaced)
                                        .lineLimit(1)
                                        .frame(minWidth: 72, alignment: .leading)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .accessibilityLabel("Preview of the first \(rows.count) rows")
            }
        }
    }

    @ViewBuilder
    private var textOptionsSections: some View {
        if let metadata = model.csvMetadata {
            Section("Note Type") {
                noteTypePicker(metadata)
                if case .global(let mapped) = metadata.notetype {
                    ForEach(Array(model.notetypeFields.enumerated()), id: \.offset) { index, fieldName in
                        Picker(fieldName, selection: Binding(
                            get: {
                                mapped.fieldColumns.indices.contains(index)
                                    ? mapped.fieldColumns[index]
                                    : 0
                            },
                            set: { model.setFieldMapping(fieldIndex: index, column: $0) }
                        )) {
                            if index > 0 {
                                Text("Ignore").tag(0)
                            }
                            ForEach(columnChoices(metadata).filter { index == 0 || $0.value > 0 }) { choice in
                                Text(choice.label).tag(choice.value)
                            }
                        }
                    }
                    if (mapped.fieldColumns.first ?? 0) == 0 {
                        Label(
                            "Map the first field to a file column before importing.",
                            systemImage: "exclamationmark.circle.fill"
                        )
                        .foregroundStyle(palette.warning)
                    }
                }
                Picker("Tags", selection: Binding(
                    get: { metadata.tagsColumn },
                    set: { model.setTagsColumn($0) }
                )) {
                    Text("None").tag(0)
                    ForEach(columnChoices(metadata)) { choice in
                        Text(choice.label).tag(choice.value)
                    }
                }
            }
            Section("Destination") {
                deckPicker(metadata)
            }
            Section("Existing Notes") {
                Picker("When matched", selection: Binding(
                    get: { metadata.duplicateResolution },
                    set: { model.setDuplicateResolution($0) }
                )) {
                    ForEach(ImportDuplicateResolution.allCases, id: \.self) { resolution in
                        Text(resolution.label).tag(resolution)
                    }
                }
                Picker("Match within", selection: Binding(
                    get: { metadata.matchScope },
                    set: { model.setMatchScope($0) }
                )) {
                    ForEach(ImportMatchScope.allCases, id: \.self) { scope in
                        Text(scope.label).tag(scope)
                    }
                }
            }
            Section("Tags to Add") {
                TextField("All imported notes", text: Binding(
                    get: { model.globalTagsText },
                    set: { model.setGlobalTags($0) }
                ))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                TextField("Updated notes only", text: Binding(
                    get: { model.updatedTagsText },
                    set: { model.setUpdatedTags($0) }
                ))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            }
        }
    }

    @ViewBuilder
    private func noteTypePicker(_ metadata: CSVImportMetadata) -> some View {
        switch metadata.notetype {
        case .global(let mapped):
            Picker("Type", selection: Binding(
                get: { mapped.id },
                set: { value in Task { await model.selectNotetype(value) } }
            )) {
                ForEach(model.notetypes) { notetype in
                    Text(notetype.name).tag(notetype.id)
                }
            }
        case .column(let column):
            LabeledContent("Type from column", value: column.formatted())
        }
    }

    @ViewBuilder
    private func deckPicker(_ metadata: CSVImportMetadata) -> some View {
        let selection = Binding<Int64>(
            get: {
                switch metadata.deck {
                case .deck(let id): id.rawValue
                case .column: -2
                case .newDeck: -1
                }
            },
            set: { value in
                if value == -1 {
                    model.setNewDeckName(model.suggestedDeckName)
                } else if value == -2 {
                    model.selectDeckColumn(1)
                } else {
                    model.selectDeck(DeckID(value))
                }
            }
        )
        Picker("Deck", selection: selection) {
            Text("New Deck").tag(Int64(-1))
            Text("Deck Column").tag(Int64(-2))
            ForEach(model.decks) { deck in
                Text(deck.name).tag(deck.id.rawValue)
            }
        }
        switch metadata.deck {
        case .newDeck(let name):
            TextField("New deck name", text: Binding(
                get: { name },
                set: { model.setNewDeckName($0) }
            ))
            if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Label("Enter a name for the new deck.", systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(palette.warning)
            }
        case .column(let column):
            Picker("Deck column", selection: Binding(
                get: { column },
                set: { model.selectDeckColumn($0) }
            )) {
                ForEach(columnChoices(metadata)) { choice in
                    Text(choice.label).tag(choice.value)
                }
            }
        case .deck:
            EmptyView()
        }
    }

    // MARK: - JSON and Mnemosyne

    @ViewBuilder
    private var jsonContentsSection: some View {
        if let summary = model.jsonSummary {
            Section("File Summary") {
                LabeledContent("Notes", value: summary.noteCount.formatted())
                LabeledContent("Scheduled Cards", value: summary.cardCount.formatted())
                LabeledContent("Note Types", value: summary.notetypeCount.formatted())
                LabeledContent("Tags Applied", value: summary.globalTagCount.formatted())
                if let deck = summary.defaultDeck, !deck.isEmpty {
                    LabeledContent("Default Deck", value: deck)
                }
            }
        }
    }

    @ViewBuilder
    private var mnemosyneContentsSection: some View {
        if let inspection = model.mnemosyneInspection {
            Section("Database Summary") {
                LabeledContent("Mnemosyne Version", value: inspection.version)
                LabeledContent("Facts", value: inspection.noteCount.formatted())
                LabeledContent("Cards", value: inspection.cardCount.formatted())
                ForEach(inspection.factViewCounts.keys.sorted(), id: \.self) { viewID in
                    LabeledContent(
                        "View \(viewID)",
                        value: inspection.factViewCounts[viewID, default: 0].formatted()
                    )
                }
            }
        }
    }

    private var mnemosyneOptionsSection: some View {
        Section("Destination") {
            Picker("Deck", selection: $model.mnemosyneDeckName) {
                Text("New Deck").tag("")
                ForEach(model.decks) { deck in
                    Text(deck.name).tag(deck.name)
                }
            }
            if model.mnemosyneDeckName.isEmpty {
                TextField("New deck name", text: $model.mnemosyneDeckName)
            }
            Text("Facts are converted to Mnemosyne-specific note types. Review history is preserved for reviewed cards.")
                .amgiFont(.caption)
                .foregroundStyle(palette.textSecondary)
        }
    }

    // MARK: - Progress and result

    private var importingView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .controlSize(.large)
            VStack(spacing: 6) {
                Text(model.format?.replacesCollection == true ? "Restoring Collection" : "Importing \(model.sourceName)")
                    .amgiFont(.bodyEmphasis)
                    .multilineTextAlignment(.center)
                Text("Keep Ijuka open until the import finishes.")
                    .amgiFont(.caption)
                    .foregroundStyle(palette.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
        .accessibilityElement(children: .combine)
    }

    private var completedView: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .amgiFont(.displayHero)
                        .foregroundStyle(palette.positive)
                        .accessibilityHidden(true)
                    Text(model.format?.replacesCollection == true ? "Collection Restored" : "Import Complete")
                        .amgiFont(.cardTitle)
                    Text(model.sourceName)
                        .amgiFont(.caption)
                        .foregroundStyle(palette.textSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }

                if let summary = model.completionSummary {
                    VStack(spacing: 0) {
                        summaryRow("New notes", value: summary.newCount, tone: palette.positive)
                        Divider()
                        summaryRow("Updated notes", value: summary.updatedCount, tone: palette.accent)
                        if summary.duplicateCount > 0 {
                            Divider()
                            summaryRow("Duplicates skipped", value: summary.duplicateCount, tone: palette.textSecondary)
                        }
                        if summary.problemCount > 0 {
                            Divider()
                            summaryRow("Needs attention", value: summary.problemCount, tone: palette.warning)
                        }
                    }
                    .padding(.horizontal, 18)
                    .background(palette.surfaceElevated, in: RoundedRectangle(cornerRadius: AmgiRadius.hero, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: AmgiRadius.hero, style: .continuous)
                            .stroke(palette.separator.opacity(0.35), lineWidth: 1)
                    }
                    .frame(maxWidth: 460)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(32)
        }
    }

    private var failedView: some View {
        ContentUnavailableView {
            Label("Can’t Import File", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(palette.danger)
        } description: {
            Text(model.failureMessage ?? "Ijuka couldn’t read this file.")
        } actions: {
            Button("Try Again") {
                Task { await model.retry() }
            }
            .buttonStyle(.borderedProminent)
            Button("Cancel") { dismiss() }
        }
    }

    private var originalFileNote: some View {
        Section {
            Label("The original file will not be changed.", systemImage: "lock.doc")
                .amgiFont(.caption)
                .foregroundStyle(palette.textSecondary)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(model.phase == .completed || model.phase == .failed ? "Done" : "Cancel") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .disabled(model.phase == .preparing || model.phase == .importing)
        }
        if model.phase == .review {
            ToolbarItem(placement: .confirmationAction) {
                if model.format?.replacesCollection == true {
                    Button("Replace", role: .destructive) {
                        showReplaceConfirmation = true
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canImport)
                } else {
                    Button("Import") {
                        model.startImport()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canImport)
                }
            }
        }
    }

    // MARK: - Formatting helpers

    private func summaryRow(_ title: String, value: Int, tone: Color) -> some View {
        HStack {
            Text(title)
                .amgiFont(.body)
            Spacer()
            Text(value.formatted())
                .amgiFont(.bodyEmphasis, .monospacedDigits)
                .foregroundStyle(tone)
        }
        .padding(.vertical, 14)
        .accessibilityElement(children: .combine)
    }

    private func columnChoices(_ metadata: CSVImportMetadata) -> [ImportColumnChoice] {
        let count = max(metadata.columnLabels.count, metadata.preview.first?.count ?? 0)
        return (1...max(1, count)).map { index in
            let label = metadata.columnLabels.indices.contains(index - 1)
                ? metadata.columnLabels[index - 1]
                : ""
            let preview = metadata.preview.first?.indices.contains(index - 1) == true
                ? metadata.preview[0][index - 1]
                : ""
            let title = !label.isEmpty ? label : (!preview.isEmpty ? preview : "Column \(index)")
            return ImportColumnChoice(value: index, shortLabel: "\(index)", label: "\(index): \(title)")
        }
    }

    private func packageFormatName(_ version: Int) -> String {
        switch version {
        case 1: "Legacy Anki 2"
        case 2: "Anki 2.1"
        case 3: "Current Anki"
        default: "Anki package"
        }
    }
}

private struct ImportColumnChoice: Identifiable, Hashable {
    let value: Int
    let shortLabel: String
    let label: String
    var id: Int { value }
}

private extension ImportPackageUpdateCondition {
    var label: String {
        switch self {
        case .ifNewer: "Update if newer"
        case .always: "Always update"
        case .never: "Don’t update"
        }
    }
}

private extension ImportDelimiter {
    var label: String {
        switch self {
        case .tab: "Tab"
        case .pipe: "Pipe (|)"
        case .semicolon: "Semicolon (;)"
        case .colon: "Colon (:)"
        case .comma: "Comma (,)"
        case .space: "Space"
        }
    }
}

private extension ImportDuplicateResolution {
    var label: String {
        switch self {
        case .update: "Update notes"
        case .preserve: "Keep existing notes"
        case .duplicate: "Create duplicates"
        }
    }
}

private extension ImportMatchScope {
    var label: String {
        switch self {
        case .notetype: "Note type"
        case .notetypeAndDeck: "Note type and deck"
        }
    }
}

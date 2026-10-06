package import SwiftUI
import AmgiAppCore
import AmgiTheme
import AmgiUI
import AnkiKit
#if os(macOS)
import AppKit
#endif

/// A format-aware export review sheet. The engine writes into a private
/// operation directory first; the system file exporter then handles Save As,
/// Files, iCloud Drive, and other Apple destinations without loading a large
/// package into memory.
package struct ExportReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette

    @State private var model: ExportReviewModel
    @State private var isPresentingFileExporter = false

    package init(
        request: ExportRequest,
        beforeExport: @escaping @MainActor @Sendable () async throws -> Void = {},
        afterExport: @escaping @MainActor @Sendable () -> Void = {},
        onCollectionFailure: @escaping @MainActor @Sendable (String, String) -> Void = { _, _ in },
        onComplete: @escaping @MainActor @Sendable () -> Void = {}
    ) {
        _model = State(initialValue: ExportReviewModel(
            request: request,
            beforeExport: beforeExport,
            afterExport: afterExport,
            onCollectionFailure: onCollectionFailure,
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
        .interactiveDismissDisabled(model.isBusy)
        .task { await model.prepare() }
        .task(id: model.fileExporterRequestID) {
            guard model.phase == .readyToSave else { return }
            // Let the state-machine update settle before presenting the system
            // Save panel. The staged file is already complete at this point.
            await Task.yield()
            model.setFileExporterPresented(true)
            isPresentingFileExporter = true
        }
        .fileExporter(
            isPresented: $isPresentingFileExporter,
            document: model.fileDocument,
            contentType: model.contentType,
            defaultFilename: model.defaultFilename
        ) { result in
            model.handleSaveResult(result)
        }
        .onDisappear { model.cleanup() }
        #if os(macOS)
        .frame(minWidth: 560, idealWidth: 640, minHeight: 520)
        .presentationSizing(.fitted)
        #endif
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(model.phase == .completed ? "Done" : "Cancel") {
                dismiss()
            }
            .disabled(model.isBusy)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .preparing:
            progressView(
                title: L10n.text("Preparing Export"),
                detail: model.sourceName ?? model.localizedScopeTitle
            )
        case .review:
            reviewForm
        case .exporting:
            progressView(
                title: L10n.format("Creating %@", [model.localizedFormatTitle(model.format)]),
                detail: model.localizedScopeTitle
            )
        case .readyToSave:
            completionForm(isCompleted: false)
        case .completed:
            completionForm(isCompleted: true)
        case .failed:
            failedView
        }
    }

    private func progressView(title: String, detail: String) -> some View {
        VStack(spacing: 18) {
            ProgressView()
                .controlSize(.large)
            VStack(spacing: 6) {
                Text(title)
                    .amgiFont(.bodyEmphasis)
                Text(detail)
                    .amgiFont(.caption)
                    .foregroundStyle(palette.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(detail)")
    }

    private var reviewForm: some View {
        Form {
            sourceSection
            formatSection
            optionsSections
            actionSection
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
        Section("Source") {
            HStack(spacing: 14) {
                Image(systemName: "tray.full.fill")
                    .amgiFont(.cardTitle)
                    .foregroundStyle(palette.accent)
                    .frame(width: 36, height: 44)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.localizedScopeTitle)
                        .amgiFont(.bodyEmphasis)
                        .lineLimit(2)
                    Text(model.localizedScopeDetail)
                        .amgiFont(.caption)
                        .foregroundStyle(palette.textSecondary)
                }
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)

            if model.allowsScopeChange {
                Picker("Export", selection: Binding(
                    get: { model.scope },
                    set: { model.selectScope($0) }
                )) {
                    ForEach(model.availableScopes, id: \.self) { scope in
                        Text(scope == .collection ? model.localizedScopeTitle : scope.title).tag(scope)
                    }
                }
            } else {
                LabeledContent("Scope", value: model.localizedScopeTitle)
            }

            if let sourceName = model.sourceName {
                LabeledContent("From", value: sourceName)
            }
            if let itemCount = model.expectedItemCount {
                let label: String = switch model.scope {
                case .collection, .deck: "Cards"
                case .notes, .cards: "Items"
                }
                LabeledContent(label, value: itemCount.formatted())
            }
        }
    }

    private var formatSection: some View {
        Section("Format") {
            Picker("File type", selection: Binding(
                get: { model.format },
                set: { model.selectFormat($0) }
            )) {
                ForEach(model.availableFormats) { format in
                    Label(model.localizedFormatTitle(format), systemImage: format.systemImage)
                        .tag(format)
                }
            }
            .pickerStyle(.menu)

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: model.format.systemImage)
                    .foregroundStyle(palette.accent)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.localizedFormatTitle(model.format))
                        .amgiFont(.bodyEmphasis)
                    Text(model.format.localizedDetail)
                        .amgiFont(.caption)
                        .foregroundStyle(palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private var optionsSections: some View {
        switch model.format {
        case .collectionPackage:
            collectionPackageOptions
        case .deckPackage:
            deckPackageOptions
        case .noteText:
            noteTextOptions
        case .cardText:
            cardTextOptions
        }
    }

    private var collectionPackageOptions: some View {
        Section {
            Toggle("Include media", isOn: Binding(
                get: { model.packageOptions.includeMedia },
                set: { model.setPackageMedia($0) }
            ))
            Toggle("Legacy Anki format", isOn: Binding(
                get: { model.packageOptions.legacy },
                set: { model.setPackageLegacy($0) }
            ))
        } header: {
            Text("Collection Package Options")
        } footer: {
            Text("A collection package includes all decks, notes, cards, scheduling, settings, and—when enabled—media.")
        }
    }

    private var deckPackageOptions: some View {
        Group {
            Section {
                Toggle("Include review history", isOn: Binding(
                    get: { model.packageOptions.includeScheduling },
                    set: { model.setPackageScheduling($0) }
                ))
                Toggle("Include deck configurations", isOn: Binding(
                    get: { model.packageOptions.includeDeckConfigurations },
                    set: { model.setPackageDeckConfigurations($0) }
                ))
                Toggle("Include media", isOn: Binding(
                    get: { model.packageOptions.includeMedia },
                    set: { model.setPackageMedia($0) }
                ))
            } header: {
                Text("Anki Package Options")
            }
            Section {
                Toggle("Legacy Anki format", isOn: Binding(
                    get: { model.packageOptions.legacy },
                    set: { model.setPackageLegacy($0) }
                ))
            } footer: {
                Text("Legacy packages are intended for older Anki versions. New exports should use the current format.")
            }
        }
    }

    private var noteTextOptions: some View {
        Group {
            Section {
                Toggle("Include HTML", isOn: Binding(
                    get: { model.noteTextOptions.includeHTML },
                    set: { model.setNoteHTML($0) }
                ))
                Toggle("Include tags", isOn: Binding(
                    get: { model.noteTextOptions.includeTags },
                    set: { model.setNoteTags($0) }
                ))
                Toggle("Include deck names", isOn: Binding(
                    get: { model.noteTextOptions.includeDeck },
                    set: { model.setNoteDeck($0) }
                ))
                Toggle("Include note type names", isOn: Binding(
                    get: { model.noteTextOptions.includeNotetype },
                    set: { model.setNoteType($0) }
                ))
                Toggle("Include note GUIDs", isOn: Binding(
                    get: { model.noteTextOptions.includeGUID },
                    set: { model.setNoteGUID($0) }
                ))
            } header: {
                Text("Note Text Options")
            } footer: {
                Text("Fields are separated by tabs. Anki's text exporter writes one note per row.")
            }
        }
    }

    private var cardTextOptions: some View {
        Section {
            Toggle("Include HTML", isOn: Binding(
                get: { model.cardTextOptions.includeHTML },
                set: { model.setCardHTML($0) }
            ))
        } header: {
            Text("Card Text Options")
        } footer: {
            Text("Each row contains the card's question and answer, separated by tabs.")
        }
    }

    private var actionSection: some View {
        Section {
            Button {
                Task { await model.exportNow() }
            } label: {
                Label(model.primaryActionTitle, systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canExport)
        } footer: {
            Text("Ijuka creates the file in a private staging location first. You’ll choose where to save it next.")
        }
    }

    private func completionForm(isCompleted: Bool) -> some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: isCompleted ? "checkmark.circle.fill" : "doc.badge.gearshape")
                        .font(.system(size: 34))
                        .foregroundStyle(palette.accent)
                        .frame(width: 42, height: 46)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(isCompleted ? "Saved" : "Ready to Save")
                            .amgiFont(.bodyEmphasis)
                        if let outputByteCount = model.outputByteCount {
                            Text(ByteCountFormatter.string(fromByteCount: outputByteCount, countStyle: .file))
                                .amgiFont(.caption)
                                .foregroundStyle(palette.textSecondary)
                        }
                        if let outputItemCount = model.outputItemCount {
                            Text("\(outputItemCount.formatted()) item\(outputItemCount == 1 ? "" : "s") exported")
                                .amgiFont(.caption)
                                .foregroundStyle(palette.textSecondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
            } header: {
                Text(isCompleted ? "Complete" : "Export Prepared")
            } footer: {
                Text(isCompleted
                    ? "Your file was saved successfully."
                    : "The export is complete. Choose a destination using the system Save panel.")
            }

            Section("Actions") {
                if let shareURL = model.shareURL {
                    ShareLink(item: shareURL) {
                        Label("Share…", systemImage: "square.and.arrow.up")
                    }
                }
                #if os(macOS)
                if let savedURL = model.savedURL {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([savedURL])
                    } label: {
                        Label("Reveal in Finder", systemImage: "folder")
                    }
                }
                #endif
                if !isCompleted {
                    Button {
                        isPresentingFileExporter = true
                    } label: {
                        Label("Save As…", systemImage: "square.and.arrow.down")
                    }
                }
            }

            if let saveFailureMessage = model.saveFailureMessage {
                Section {
                    Label {
                        Text(saveFailureMessage)
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

    private var failedView: some View {
        VStack(spacing: 18) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(palette.danger)
            VStack(spacing: 6) {
                Text("Export Failed")
                    .amgiFont(.bodyEmphasis)
                Text(model.failureMessage ?? "Ijuka couldn’t create the export.")
                    .amgiFont(.caption)
                    .foregroundStyle(palette.textSecondary)
                    .multilineTextAlignment(.center)
            }
            Button("Try Again") {
                Task { await model.retry() }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

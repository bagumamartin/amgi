// AmgiApp/Sources/Shared/ExportPackagesSheet.swift
import SwiftUI
import AnkiKit
import AnkiClients
import Dependencies
import AmgiTheme

/// Export entry point for both package kinds (browse-redesign-spec §5.7
/// amendment): **whole collection** as `.colpkg` or a **single deck** as
/// `.apkg`. Bridge/service surface already existed (`ImportExportService`);
/// this is the shared UI.
///
/// Flow: pick scope + media toggle → Export writes to a timestamped temp
/// file off-main → success row offers ShareLink. Errors render inline.
struct ExportPackagesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette

    @State private var decks: [DeckInfo] = []
    @State private var exportWholeCollection = true
    @State private var selectedDeckID: DeckID?
    @State private var includeMedia = true
    @State private var isExporting = false
    @State private var failureMessage: String?
    @State private var exportedURL: URL?

    @Dependency(\.importExportService) private var importExport
    @Dependency(\.deckClient) private var deckClient

    private static var stamp: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return formatter.string(from: Date())
    }

    var body: some View {
        NavigationStack {
            Form {
                scopeSection
                optionsSection
                resultSection
            }
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task {
            // Self-contained: the sheet owns its deck list so any caller can
            // present it without threading data through.
            decks = (try? await deckClient.fetchAll()) ?? []
            if selectedDeckID == nil { selectedDeckID = decks.first?.id }
        }
    }

    // MARK: Sections

    private var scopeSection: some View {
        Section("What to export") {
            Picker("Scope", selection: $exportWholeCollection) {
                Text("Whole collection").tag(true)
                Text("Single deck").tag(false)
            }
            .pickerStyle(.segmented)

            if exportWholeCollection {
                Text("Everything — all decks, scheduling and settings — as one .colpkg backup.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Picker("Deck", selection: $selectedDeckID) {
                    ForEach(decks) { deck in
                        Text(deck.name).tag(Optional(deck.id))
                    }
                }
            }
        }
    }

    private var optionsSection: some View {
        Section("Options") {
            Toggle("Include media", isOn: $includeMedia)
            Button {
                Task { await run() }
            } label: {
                if isExporting {
                    HStack { ProgressView(); Text("Exporting…") }
                } else {
                    Label("Export \(exportWholeCollection ? "Collection" : "Deck")",
                          systemImage: "square.and.arrow.up")
                }
            }
            .disabled(isExporting || (!exportWholeCollection && selectedDeckID == nil))
        }
    }

    @ViewBuilder
    private var resultSection: some View {
        if let exportedURL {
            Section("Done") {
                LabeledContent("File", value: exportedURL.lastPathComponent)
                ShareLink(item: exportedURL) {
                    Label("Share…", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
            }
        } else if let failureMessage {
            Section {
                Text(failureMessage)
                    .font(.callout)
                    .foregroundStyle(palette.danger)
            }
        }
    }

    // MARK: Work

    private func run() async {
        isExporting = true
        failureMessage = nil
        defer { isExporting = false }

        do {
            let service = importExport
            let media = includeMedia
            let url: URL
            switch (exportWholeCollection, selectedDeckID) {
            case (true, _):
                let path = Self.destinationURL(name: "AmgiCollection-\(Self.stamp)", ext: "colpkg").path
                try await Task.detached(priority: .userInitiated) {
                    try service.exportCollectionPackage(path, media)
                }.value
                url = URL(fileURLWithPath: path)
            case (false, .some(let deckID)):
                guard let deck = decks.first(where: { $0.id == deckID }) else { return }
                let safeName = deck.name.replacingOccurrences(of: "::", with: "-")
                let path = Self.destinationURL(name: "\(safeName)-\(Self.stamp)", ext: "apkg").path
                try await Task.detached(priority: .userInitiated) {
                    // legacy:false → modern fsrs-aware apkg; all optional
                    // sections on, gated by the single media toggle.
                    _ = try service.exportDeckPackage(
                        deckID, path, true, true, media, false
                    )
                }.value
                url = URL(fileURLWithPath: path)
            case (false, .none):
                return
            }
            exportedURL = url
        } catch {
            failureMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    private static func destinationURL(name: String, ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appending(component: "\(name).\(ext)")
    }
}

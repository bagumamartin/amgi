import AmgiReaderEPUB
import AmgiTheme
import AmgiUI
import SwiftUI
import UniformTypeIdentifiers

/// Repair sheet for a book that is still in the index but whose source file
/// is missing or no longer parses.
///
/// The two paths mirror the two faults: a corrupt-but-present file can be
/// re-read in place, while a missing file can only be fixed by pointing the
/// library at a replacement file.
struct BookRepairSheet: View {
    let bookID: String
    let title: String
    let repair: ReaderBookRepair

    let onRetry: () async -> Bool
    let onRelink: (URL) async throws -> Void
    let onDismiss: () -> Void

    @State private var isWorking = false
    @State private var failure: String?
    @State private var isChoosingFile = false

    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            Text(repair.message)
                .amgiFont(.body)
                .foregroundStyle(palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .amgiFont(.caption)
                    .foregroundStyle(palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            actions
        }
        .padding(20)
        .frame(minWidth: 380, idealWidth: 460, minHeight: 260, idealHeight: 300)
        .amgiScreenCanvas()
        .fileImporter(
            isPresented: $isChoosingFile,
            allowedContentTypes: UTType.readerDocuments,
            allowsMultipleSelection: false
        ) { result in
            handleFileSelection(result)
        }
    }
}

private extension BookRepairSheet {
    var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .amgiFont(.cardTitle)
                .foregroundStyle(palette.textSecondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(repair.title)
                    .amgiFont(.sectionHeading)
                    .foregroundStyle(palette.textPrimary)
                Text(title)
                    .amgiFont(.caption)
                    .foregroundStyle(palette.textSecondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    var actions: some View {
        VStack(spacing: 10) {
            if repair.canRetryInPlace {
                Button {
                    Task { await runRetry() }
                } label: {
                    if isWorking {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Try Again")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isWorking)
            }

            Button {
                isChoosingFile = true
            } label: {
                Text(repair.canRetryInPlace ? "Choose a Different File…" : "Choose Replacement \(repair.format.displayName)…")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(isWorking)

            Button("Remove Book", role: .destructive) {
                onDismiss()
            }
            .buttonStyle(.borderless)
            .disabled(isWorking)
        }
    }
}

private extension BookRepairSheet {
    func runRetry() async {
        isWorking = true
        failure = nil
        defer { isWorking = false }
        if await onRetry() {
            onDismiss()
        } else {
            failure = "Still can't read the file. Choose a replacement \(repair.format.displayName)."
        }
    }

    func handleFileSelection(_ result: Result<[URL], any Error>) {
        switch result {
        case .failure(let error):
            failure = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            isWorking = true
            failure = nil
            Task {
                defer { isWorking = false }
                do {
                    // A replacement picked in the Files panel is
                    // security-scoped; hold the grant across the import.
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    try await onRelink(url)
                    onDismiss()
                } catch {
                    failure = error.localizedDescription
                }
            }
        }
    }
}

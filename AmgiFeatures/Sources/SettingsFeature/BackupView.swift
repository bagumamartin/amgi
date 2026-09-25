import SwiftUI
import Combine
import AmgiTheme
import AmgiAppCore
import AmgiAppShared
import CasePaths
import SwiftNavigation
import SwiftUINavigation
import AmgiUI
import AnkiKit

/// Local `.colpkg` backups of the active profile's collection. Each backup
/// is a timestamped copy stored under `Documents/Backups for <profile>/`.
/// The user can create, share (AirDrop / Files / Mail) and delete them.
struct BackupView: View {
    let username: String

    @State private var backups: [BackupEntry] = []
    @State private var destination: Destination?

    /// One axis for all three alerts. As three flag+payload pairs these could
    /// encode states the screen can't render — a raised flag with no message,
    /// or success and error asking to show at once.
    @CasePathable
    enum Destination {
        case confirmDelete(BackupEntry)
        case success(String)
        case failure(String)
    }

    @Environment(\.palette) private var palette
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    struct BackupEntry: Identifiable {
        let id = UUID()
        let url: URL
        let date: Date
        // Precomputed once in `loadBackups()` — these used to be computed
        // properties that hit the filesystem / allocated a DateFormatter on
        // every row redraw.
        let formattedDate: String
        let fileSize: String
    }

    var body: some View {
        List {
            createSection
            if backups.isEmpty {
                emptySection
            } else {
                listSection
            }
        }
        .scrollContentBackground(.hidden)
        .amgiScreenCanvas()
        .navigationTitle("Backups")
        .navigationBarTitleDisplayMode(.inline)
        .modifier(BackupAlerts(destination: $destination, onDelete: deleteBackup))
        .onReceive(NotificationCenter.default.publisher(for: .amgiExportDidSave)) { _ in
            loadBackups()
        }
        .task { loadBackups() }
    }

    private var createSection: some View {
        Section {
            Button {
                #if os(macOS)
                openWindow(id: "main")
                #endif
                ExportRequestRouter.shared.request(
                    scope: .collection,
                    allowedFormats: [.collectionPackage],
                    sourceName: "Backups"
                )
            } label: {
                HStack(spacing: AmgiSpacing.md) {
                    SettingsIconTile(systemImage: "externaldrive.badge.plus", tone: .accent)
                    Text("Create backup now")
                        .amgiFont(.body)
                        .foregroundStyle(palette.textPrimary)
                    Spacer(minLength: AmgiSpacing.sm)
                    Image(systemName: "chevron.right")
                        .amgiFont(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(palette.textSecondary)
                }
            }
            .listRowBackground(palette.surfaceElevated)
        } footer: {
            Text("Create a collection package, then choose Files, iCloud Drive, or another Apple destination in the system Save panel.")
                .amgiFont(.caption)
                .foregroundStyle(palette.textSecondary)
        }
    }

    private var emptySection: some View {
        Section {
            Text("No backups yet.")
                .amgiFont(.body)
                .foregroundStyle(palette.textSecondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, AmgiSpacing.sm)
                .listRowBackground(palette.surfaceElevated)
        }
    }

    private var listSection: some View {
        Section {
            ForEach(backups) { entry in
                BackupRow(
                    entry: entry,
                    accent: palette.accent,
                    onDelete: { destination = .confirmDelete(entry) }
                )
                    .listRowBackground(palette.surfaceElevated)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            destination = .confirmDelete(entry)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
            }
        } header: {
            SettingsListHeader("Available backups")
        }
    }

    // MARK: - Filesystem
}

private extension BackupView {
    func backupDirectories() -> [URL] {
        guard let docs = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first else { return [] }
        let names = [
            "Backups for \(AccountStore.shared.selectedID)",
            // Read the pre-profile-ID directory as well so upgrading the app
            // never strands backups created by an earlier build.
            "Backups for \(username)",
        ]
        var directories = names.map { name in
            let directory = docs.appendingPathComponent(name, isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        }
        let recovery = AccountStore.profileDirectory(
            for: AccountStore.shared.selectedID
        ).appendingPathComponent("Recovery", isDirectory: true)
        try? FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true)
        directories.append(recovery)
        return directories
    }

    func loadBackups() {
        let files = backupDirectories().flatMap { directory in
            (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: .skipsHiddenFiles
            )) ?? []
        }
        var seen = Set<String>()
        backups = files
            .filter { $0.pathExtension.lowercased() == "colpkg" }
            .filter { seen.insert($0.standardizedFileURL.path).inserted }
            .map { url in
                let values = try? url.resourceValues(
                    forKeys: [.contentModificationDateKey, .fileSizeKey]
                )
                let date = values?.contentModificationDate ?? .distantPast
                let bytes = Int64(values?.fileSize ?? 0)
                return BackupEntry(
                    url: url,
                    date: date,
                    formattedDate: date.formatted(date: .abbreviated, time: .shortened),
                    fileSize: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
                )
            }
            .sorted { $0.date > $1.date }
    }

    func deleteBackup(_ entry: BackupEntry) {
        do {
            try FileManager.default.removeItem(at: entry.url)
            destination = nil
            loadBackups()
        } catch CocoaError.fileNoSuchFile {
            // The file was already removed by Finder or another app. The
            // user's intent is still satisfied, so refresh without showing a
            // misleading failure.
            destination = nil
            loadBackups()
        } catch {
            destination = .failure("Could not delete the backup: \(error.localizedDescription)")
        }
    }
}

private struct BackupRow: View {
    let entry: BackupView.BackupEntry
    let accent: Color
    let onDelete: () -> Void

    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: AmgiSpacing.md) {
            SettingsIconTile(systemImage: "clock.arrow.circlepath", tone: .mature)
            VStack(alignment: .leading, spacing: AmgiSpacing.xxs) {
                Text(entry.formattedDate)
                    .amgiFont(.body)
                    .foregroundStyle(palette.textPrimary)
                Text(entry.fileSize)
                    .amgiFont(.caption)
                    .foregroundStyle(palette.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ShareLink(item: entry.url) {
                Image(systemName: "square.and.arrow.up")
                    .foregroundStyle(accent)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Share backup from \(entry.formattedDate)")
            .accessibilityHint("Opens the system share sheet")
            Button {
                ImportRequestRouter.shared.request(entry.url)
            } label: {
                Image(systemName: "arrow.down.doc")
                    .foregroundStyle(accent)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Restore backup from \(entry.formattedDate)")
            .accessibilityHint("Imports this collection backup")
            .help("Restore this collection backup")

            // macOS lists do not expose swipe actions. Keep a visible,
            // native destructive affordance there; touch platforms retain the
            // familiar swipe plus the shared context/keyboard actions below.
            #if os(macOS)
            Button(role: .destructive) {
                onDelete()
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(palette.danger)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Delete backup from \(entry.formattedDate)")
            .accessibilityHint("Asks before deleting this backup")
            .help("Delete this backup")
            #endif
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Delete Backup", systemImage: "trash")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Backup from \(entry.formattedDate), \(entry.fileSize)")
        .accessibilityAction(named: "Delete backup", onDelete)
        #if os(macOS)
        .onDeleteCommand {
            onDelete()
        }
        #endif
    }
}

private struct BackupAlerts: ViewModifier {
    @Binding var destination: BackupView.Destination?
    let onDelete: (BackupView.BackupEntry) -> Void

    private var pendingDelete: BackupView.BackupEntry? {
        if case .confirmDelete(let entry) = destination { return entry }
        return nil
    }

    private var successMessage: String? {
        if case .success(let message) = destination { return message }
        return nil
    }

    private var failureMessage: String? {
        if case .failure(let message) = destination { return message }
        return nil
    }

    func body(content: Content) -> some View {
        content
            .alert(
                "Delete backup?",
                isPresented: Binding($destination.confirmDelete),
                presenting: pendingDelete
            ) { entry in
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) { onDelete(entry) }
            } message: { entry in
                Text("Delete the backup from \(entry.formattedDate)?")
            }
            .alert("Done", isPresented: Binding($destination.success)) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(successMessage ?? "")
            }
            .alert("Error", isPresented: Binding($destination.failure)) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(failureMessage ?? "")
            }
    }
}

#if DEBUG

// MARK: - Preview

#Preview {
    NavigationStack { BackupView(username: "you@example.com") }
}
#endif

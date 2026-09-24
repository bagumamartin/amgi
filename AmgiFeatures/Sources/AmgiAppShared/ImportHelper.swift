public import AnkiKit
import AnkiServices
import Dependencies
public import Foundation

@available(*, deprecated, message: "Use ExportReviewView and ExportRequestRouter for native Save As and sharing.")
public enum ImportHelper {
    /// Exports a single deck as an `.apkg` file in the temporary directory and
    /// returns the URL. The default options preserve scheduling, deck configs,
    /// and media — matching upstream Anki's "Export including media" preset.
    @available(*, unavailable, message: "Exports are routed through ExportRequestRouter and ExportReviewView.")
    public static func exportDeck(
        deckId: DeckID,
        deckName: String,
        withScheduling: Bool = true,
        withDeckConfigs: Bool = true,
        withMedia: Bool = true
    ) throws -> URL {
        let safeName = deckName
            .replacingOccurrences(of: "::", with: "-")
            .replacingOccurrences(of: "/", with: "-")
        let filename = "\(safeName).apkg"
        let tempDir = FileManager.default.temporaryDirectory
        let outPath = tempDir.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: outPath)

        @Dependency(\.importExportService) var importExportService
        _ = try importExportService.exportDeckPackage(
            deckId,
            outPath.path,
            withScheduling,
            withDeckConfigs,
            withMedia,
            false  // legacy
        )

        return outPath
    }
}

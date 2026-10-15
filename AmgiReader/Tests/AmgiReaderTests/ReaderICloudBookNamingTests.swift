import Foundation
import Testing
@testable import AmgiReader

@Suite("Readable iCloud book file names")
struct ReaderICloudBookNamingTests {
    @Test("titles become safe single file names")
    func baseNames() {
        #expect(ReaderICloudBookNaming.baseName(forTitle: "Dune") == "Dune")
        #expect(ReaderICloudBookNaming.baseName(forTitle: "AC/DC: Live") == "AC-DC- Live")
        #expect(ReaderICloudBookNaming.baseName(forTitle: "  ..hidden\ttitle  ") == "hidden title")
        #expect(ReaderICloudBookNaming.baseName(forTitle: "   ") == "Untitled")
        #expect(ReaderICloudBookNaming.baseName(forTitle: "吾輩は猫である") == "吾輩は猫である")
        let long = String(repeating: "a", count: 300)
        #expect(ReaderICloudBookNaming.baseName(forTitle: long).count
            == ReaderICloudBookNaming.maximumBaseLength)
    }

    @Test("collision suffixes still match their title")
    func matching() {
        #expect(ReaderICloudBookNaming.fileName("Dune.epub", matchesTitle: "Dune", fileExtension: "epub"))
        #expect(ReaderICloudBookNaming.fileName("Dune (3).epub", matchesTitle: "Dune", fileExtension: "epub"))
        #expect(!ReaderICloudBookNaming.fileName("Dune (x).epub", matchesTitle: "Dune", fileExtension: "epub"))
        #expect(!ReaderICloudBookNaming.fileName("Dune.pdf", matchesTitle: "Dune", fileExtension: "epub"))
        #expect(!ReaderICloudBookNaming.fileName("Dune Messiah.epub", matchesTitle: "Dune", fileExtension: "epub"))
    }

    @Test("taken names, placeholders and other books' names are skipped")
    func uniqueness() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Naming-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        try Data().write(to: folder.appendingPathComponent("Dune.epub"))
        try Data().write(to: folder.appendingPathComponent(".Dune (2).epub.icloud"))
        #expect(ReaderICloudBookNaming.availableFileName(
            forTitle: "Dune", fileExtension: "epub", in: folder
        ) == "Dune (3).epub")

        // A book keeps its own name on re-upload…
        #expect(ReaderICloudBookNaming.uploadFileName(
            forTitle: "Dune", fileExtension: "epub",
            existing: "Dune.epub", claimedByOthers: [], in: folder
        ) == "Dune.epub")
        // …but not one another book's metadata now claims.
        #expect(ReaderICloudBookNaming.uploadFileName(
            forTitle: "Dune", fileExtension: "epub",
            existing: "Dune.epub", claimedByOthers: ["Dune.epub", "Dune (3).epub"], in: folder
        ) == "Dune (4).epub")
        // A retitled book moves to a name for its new title.
        #expect(ReaderICloudBookNaming.uploadFileName(
            forTitle: "Children of Dune", fileExtension: "epub",
            existing: "Dune.epub", claimedByOthers: [], in: folder
        ) == "Children of Dune.epub")
    }
}

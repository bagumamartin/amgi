import Foundation
import Testing
@testable import ReaderFeature

/// Cover lifting from the first chapter: largest image wins, trackers and
/// escapes are skipped, malformed chapters still yield what parsed.
@Suite("EPUB cover image extractor")
struct EPUBCoverImageExtractorTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("amgi-cover-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Text", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Images", isDirectory: true),
            withIntermediateDirectories: true
        )
        return root
    }

    private func writeChapter(in root: URL, body: String) throws -> URL {
        let chapter = root.appendingPathComponent("Text/ch1.xhtml")
        try """
            <?xml version="1.0" encoding="utf-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml"><head><title>t</title></head>
            <body>\(body)</body></html>
            """.write(to: chapter, atomically: true, encoding: .utf8)
        return chapter
    }

    private func writeImage(in root: URL, name: String, byteCount: Int) throws {
        try Data(repeating: 0xAB, count: byteCount).write(
            to: root.appendingPathComponent("Images/\(name)")
        )
    }

    @Test("the largest image wins")
    func largestImageWins() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeImage(in: root, name: "small.jpg", byteCount: 100)
        try writeImage(in: root, name: "big.jpg", byteCount: 200)
        let chapter = try writeChapter(in: root, body: """
            <p><img src="../Images/small.jpg" width="200" height="300"/></p>
            <p><img src="../Images/big.jpg" width="600" height="800"/></p>
            """)

        #expect(EPUBCoverImageExtractor.firstCoverImageURL(
            chapterURL: chapter, contentRootURL: root
        )?.lastPathComponent == "big.jpg")
    }

    @Test("trackers are skipped when art exists, and yield nil alone")
    func trackersAreSkipped() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeImage(in: root, name: "tracker.gif", byteCount: 43)
        try writeImage(in: root, name: "cover.jpg", byteCount: 5000)
        let chapter = try writeChapter(in: root, body: """
            <p><img src="../Images/tracker.gif" width="1" height="1"/></p>
            <p><img src="../Images/cover.jpg" width="600" height="800"/></p>
            """)

        #expect(EPUBCoverImageExtractor.firstCoverImageURL(
            chapterURL: chapter, contentRootURL: root
        )?.lastPathComponent == "cover.jpg")

        let lonely = try writeChapter(in: root, body: """
            <p><img src="../Images/tracker.gif" width="1" height="1"/></p>
            """)
        // A lone tracker is decor, not a cover — fall through to the snapshot.
        try FileManager.default.removeItem(at: root.appendingPathComponent("Images/cover.jpg"))
        #expect(EPUBCoverImageExtractor.firstCoverImageURL(
            chapterURL: lonely, contentRootURL: root
        ) == nil)
    }

    @Test("root-absolute, encoded and versioned sources resolve")
    func exoticSourcesResolve() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeImage(in: root, name: "my cover.jpg", byteCount: 3000)
        let chapter = try writeChapter(in: root, body: """
            <p><img src="/Images/my%20cover.jpg?v=2" width="600" height="800"/></p>
            """)

        #expect(EPUBCoverImageExtractor.firstCoverImageURL(
            chapterURL: chapter, contentRootURL: root
        )?.lastPathComponent == "my cover.jpg")
    }

    @Test("a traversal escape is rejected")
    func traversalIsRejected() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.deletingLastPathComponent()
            .appendingPathComponent("evil-\(UUID().uuidString).jpg")
        try Data(repeating: 0xAB, count: 9000).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        let chapter = try writeChapter(in: root, body: """
            <p><img src="../../\(outside.lastPathComponent)" width="1200" height="1600"/></p>
            """)

        #expect(EPUBCoverImageExtractor.firstCoverImageURL(
            chapterURL: chapter, contentRootURL: root
        ) == nil)
    }

    @Test("a malformed chapter still yields what parsed before the error")
    func malformedChapterYieldsPartial() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeImage(in: root, name: "cover.jpg", byteCount: 4000)
        let chapter = root.appendingPathComponent("Text/ch1.xhtml")
        try """
            <?xml version="1.0" encoding="utf-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml"><body>
            <p><img src="../Images/cover.jpg" width="600" height="800"/></p>
            <p>unclosed garbage
            """.write(to: chapter, atomically: true, encoding: .utf8)

        #expect(EPUBCoverImageExtractor.firstCoverImageURL(
            chapterURL: chapter, contentRootURL: root
        )?.lastPathComponent == "cover.jpg")
    }

    @Test("no images, or no chapter, means no cover")
    func emptyMeansNil() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let chapter = try writeChapter(in: root, body: "<p>words only</p>")
        #expect(EPUBCoverImageExtractor.firstCoverImageURL(
            chapterURL: chapter, contentRootURL: root
        ) == nil)
        #expect(EPUBCoverImageExtractor.firstCoverImageURL(
            chapterURL: root.appendingPathComponent("Text/missing.xhtml"),
            contentRootURL: root
        ) == nil)
    }

    @Test("the scan is bounded on image-heavy chapters")
    func scanIsBounded() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var body = ""
        for i in 0..<51 {
            try writeImage(in: root, name: "img\(i).jpg", byteCount: 100 + i)
            body += "<p><img src=\"../Images/img\(i).jpg\"/></p>\n"
        }
        // The largest image sits past the scan bound: it must not win,
        // proving pathological chapters cannot blow up the reload.
        let chapter = try writeChapter(in: root, body: body)
        let picked = EPUBCoverImageExtractor.firstCoverImageURL(
            chapterURL: chapter, contentRootURL: root
        )
        #expect(picked != nil)
        #expect(picked?.lastPathComponent != "img50.jpg")
    }
}

public import Foundation
import CryptoKit

/// What the library knows about a PDF, independent of any renderer.
///
/// The renderer (PDFKit, in the app layer) produces this; the store persists
/// it. Keeping the two apart means the store can be an actor and fully tested
/// without instantiating a single PDFKit object.
public struct PDFDocumentDescriptor: Sendable, Hashable, Codable {
    /// Content hash, the same shape EPUB uses so the two libraries agree on
    /// what re-importing the same file means.
    public var bookID: String
    public var title: String
    public var author: String?
    public var language: String?

    /// Page count as the document declares it.
    public var pageCount: Int

    /// The document's own page labels, where present.
    ///
    /// A PDF is allowed to have a page-label tree, and well-made books use it:
    /// roman numerals through the front matter, then arabic, often restarting
    /// at 1 for the body. That is the numbering a reader says out loud, so it
    /// is worth reading rather than deriving from the index.
    public var pageLabels: [String?]?

    /// Outline (table of contents) entries, flattened with their page indices.
    public var outline: [PDFOutlineEntry]

    /// Whether the document carries a usable text layer.
    ///
    /// Decided by sampling rather than by trusting the absence of a font: a
    /// document with only a handful of real text pages is common, and
    /// treating it as text-bearing would produce cards full of empty strings.
    public var hasTextLayer: Bool

    /// Fraction of sampled pages that yielded text, 0...1.
    public var textLayerCoverage: Double

    public var documentFingerprint: String

    public var pageSize: PDFPageSize?

    public init(
        bookID: String,
        title: String,
        author: String? = nil,
        language: String? = nil,
        pageCount: Int,
        pageLabels: [String?]? = nil,
        outline: [PDFOutlineEntry] = [],
        hasTextLayer: Bool,
        textLayerCoverage: Double = 0,
        documentFingerprint: String,
        pageSize: PDFPageSize? = nil
    ) {
        self.bookID = bookID
        self.title = title
        self.author = author
        self.language = language
        self.pageCount = pageCount
        self.pageLabels = pageLabels
        self.outline = outline
        self.hasTextLayer = hasTextLayer
        self.textLayerCoverage = textLayerCoverage
        self.documentFingerprint = documentFingerprint
        self.pageSize = pageSize
    }

    /// The label for a page, falling back to its 1-based index.
    public func label(forPageIndex index: Int) -> String {
        guard let pageLabels, pageLabels.indices.contains(index) else {
            return String(index + 1)
        }
        return pageLabels[index] ?? String(index + 1)
    }
}

/// One entry from the document outline.
public struct PDFOutlineEntry: Sendable, Hashable, Codable, Identifiable {
    /// Stable across re-imports: derived from the entry's position and title
    /// so the same document always produces the same IDs, which is what lets a
    /// reading position survive a re-import.
    public var id: String
    public var title: String
    /// Index of the page this entry points at, 0-based.
    public var pageIndex: Int
    /// Nesting depth, 0 for top level.
    public var depth: Int

    public init(id: String, title: String, pageIndex: Int, depth: Int) {
        self.id = id
        self.title = title
        self.pageIndex = pageIndex
        self.depth = depth
    }

    /// Deterministic identifier for an outline entry.
    ///
    /// Deliberately *not* a hash of the destination: a document that keeps its
    /// structure but moves a section by a page should keep its chapter IDs, or
    /// every saved position in it would be invalidated by a repagination.
    public static func outlineID(path: [Int]) -> String {
        "outline:" + path.map(String.init).joined(separator: ".")
    }
}

/// A page's size, recorded so a crop can be rendered without reopening the
/// document and so a change in geometry is visible to the fingerprint.
public struct PDFPageSize: Sendable, Hashable, Codable {
    /// Uniform page size. Non-uniform documents record the first page only,
    /// which is what the sidebar thumbnail layout assumes anyway.
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    public var isPortrait: Bool { height > width }
    public var aspectRatio: Double {
        height > 0 ? width / height : 0
    }
}

/// Builds the fingerprint that detects "this is no longer the same PDF".
///
/// The tempting implementation is to hash the whole file, and it is the wrong
/// one: a 400-page document is tens of megabytes, and hashing it on every open
/// to answer a question that almost never changes is a bad trade. Worse, it
/// would be *too* sensitive — any byte difference at all, including a changed
/// creation timestamp, would invalidate every anchor in the book.
///
/// What actually matters is whether the *geometry and text* still line up,
/// because that is what an anchor's page index and quote are resolved
/// against. So the fingerprint samples: a handful of pages, each contributing
/// its dimensions and a slice of its text.
public enum PDFDocumentFingerprint {
    /// Pages sampled across the document.
    ///
    /// Nine is enough to notice a repagination without paying for the whole
    /// file: a print-to-PDF round trip shifts page breaks throughout, so even
    /// two well-separated samples catch it, and the extra samples guard
    /// against a document that changed only in part.
    public static let sampleCount = 9

    /// Characters of text taken from each sampled page.
    public static let sampleTextLength = 64

    /// Computes a fingerprint from samples supplied by the renderer.
    ///
    /// - Parameter samples: `(pageIndex, width, height, textPrefix)` tuples.
    ///   The renderer supplies these because it is the only layer that can read
    ///   the document; this function stays pure and therefore testable.
    public static func fingerprint(
        pageCount: Int,
        samples: [(pageIndex: Int, width: Double, height: Double, textPrefix: String)]
    ) -> String {
        var material = "pages=\(max(pageCount, 0))"
        // Sorted so a renderer that walks pages in a different order still
        // produces the same fingerprint.
        for sample in samples.sorted(by: { $0.pageIndex < $1.pageIndex }) {
            let text = String(sample.textPrefix.prefix(sampleTextLength))
            material += "|\(sample.pageIndex):\(format(sample.width))x\(format(sample.height)):\(text)"
        }
        return digest(material)
    }

    /// Which pages to sample when the renderer is walking a document.
    public static func sampleIndices(pageCount: Int) -> [Int] {
        guard pageCount > 0 else { return [] }
        if pageCount <= sampleCount { return Array(0..<pageCount) }
        // Evenly spaced, always including first and last: the two ends are
        // where a repagination shows up first and where a crop is most
        // sensitive.
        let step = Double(pageCount - 1) / Double(sampleCount - 1)
        return (0..<sampleCount).map { Int((Double($0) * step).rounded()) }
    }

    private static func format(_ value: Double) -> String {
        // Two decimals is the right resolution: enough that a sub-point
        // geometry change is caught, not so fine that float noise in the
        // renderer produces a different answer for the same document.
        String(format: "%.2f", value)
    }

    private static func digest(_ material: String) -> String {
        let bytes = SHA256.hash(data: Data(material.utf8))
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Short form for display and for log lines.
    public static func short(_ fingerprint: String) -> String {
        String(fingerprint.prefix(12))
    }
}

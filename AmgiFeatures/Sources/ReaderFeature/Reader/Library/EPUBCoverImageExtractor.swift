import Foundation
import ImageIO

/// Finds a cover candidate in an EPUB's first chapter.
///
/// Some EPUBs carry no OPF-declared cover, yet open onto a full-page cover
/// image (or title art) as their first spine item. Snapping the whole first
/// page would frame that art inside margins and running heads; lifting the
/// image itself displays full-bleed exactly like an embedded cover, through
/// the same `.epub` cover path.
///
/// Pure file I/O + SAX parsing + image-header reads — no WebKit, no store
/// access — so the model runs it once per reload for every coverless book.
/// A chapter that names no usable image yields nil and the caller falls back
/// to the first-page snapshot, then the placeholder.
enum EPUBCoverImageExtractor {
    /// Images smaller than this on their long edge are decoration (trackers,
    /// spacers, rules), never a cover.
    private static let minimumDimension: CGFloat = 60
    /// Bounds the SAX scan on pathological chapters. Covers sit near the top
    /// of the first spine item; fifty images in is far past any cover.
    private static let maxImagesScanned = 50

    /// The best cover candidate referenced by the chapter at `chapterURL`,
    /// resolved against it (`contentRootURL` for root-absolute paths) — or
    /// nil when the chapter names no usable image.
    static func firstCoverImageURL(chapterURL: URL, contentRootURL: URL) -> URL? {
        guard FileManager.default.fileExists(atPath: chapterURL.path),
              let parser = XMLParser(contentsOf: chapterURL) else {
            return nil
        }
        let scan = ImageScanDelegate(limit: maxImagesScanned)
        parser.delegate = scan
        parser.shouldResolveExternalEntities = false
        // A malformed chapter still yields what was collected before the
        // error: real-world EPUB XHTML is often imperfect XML.
        _ = parser.parse()
        guard !scan.candidates.isEmpty else { return nil }

        let chapterDirectory = chapterURL.deletingLastPathComponent()
        // Two tiers: images with known dimensions rank by area; the rest (no
        // attrs and unreadable headers) rank by file size below all of them.
        // An unknown-dimensions file is more likely an unreadable asset than
        // a cover, so it never outranks a measured image.
        var bestMeasured: (url: URL, area: CGFloat, order: Int)?
        var bestUnmeasured: (url: URL, size: Int, order: Int)?
        for (order, candidate) in scan.candidates.enumerated() {
            guard let file = resolve(
                candidate.src,
                chapterDirectory: chapterDirectory,
                contentRootURL: contentRootURL
            ), FileManager.default.fileExists(atPath: file.path) else {
                continue
            }
            let measured = pixelDimensions(of: file) ?? candidate.dimensions
            if let measured, measured.width > 0, measured.height > 0 {
                guard max(measured.width, measured.height) >= minimumDimension else { continue }
                let area = measured.width * measured.height
                if bestMeasured == nil || area > bestMeasured!.area {
                    bestMeasured = (file, area, order)
                }
            } else if bestMeasured == nil {
                // No dimensions anywhere: only trust files that at least look
                // like images. Anything else is more likely a misreferenced
                // asset than a cover.
                let imageExtensions = ["jpg", "jpeg", "png", "gif", "webp", "avif", "svg", "bmp", "tif", "tiff"]
                guard imageExtensions.contains(file.pathExtension.lowercased()) else { continue }
                let size = fileSize(of: file)
                if bestUnmeasured == nil || size > bestUnmeasured!.size {
                    bestUnmeasured = (file, size, order)
                }
            }
        }
        return bestMeasured?.url ?? bestUnmeasured?.url
    }

    // MARK: - Candidate ranking input

    static func leadingInt(_ raw: String?) -> CGFloat? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces),
              !raw.isEmpty, !raw.hasSuffix("%") else {
            return nil
        }
        let digits = raw.prefix(while: \.isNumber)
        guard !digits.isEmpty, let value = Double(digits) else { return nil }
        return CGFloat(value)
    }

    /// True pixel dimensions from the image header — no full decode — or nil
    /// when the file is not a readable image.
    static func pixelDimensions(of url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = (properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.doubleValue,
              width > 0, height > 0 else {
            return nil
        }
        return CGSize(width: width, height: height)
    }

    private static func fileSize(of url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    // MARK: - Path resolution

    /// Resolves an `<img src>` against the chapter (or the content root for
    /// root-absolute paths), contained to the content root. Remote URLs, data
    /// URIs and traversal escapes resolve to paths that fail the existence
    /// or containment checks and are skipped by the caller.
    static func resolve(
        _ src: String,
        chapterDirectory: URL,
        contentRootURL: URL
    ) -> URL? {
        var decoded = src.removingPercentEncoding ?? src
        // Some publishers version assets (?v=2) or fragment them (#cover).
        if let queryStart = decoded.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            decoded = String(decoded[..<queryStart])
        }
        guard !decoded.isEmpty else { return nil }
        let base: URL
        let relative: String
        if decoded.hasPrefix("/") {
            base = contentRootURL
            relative = String(decoded.dropFirst())
        } else {
            base = chapterDirectory
            relative = decoded
        }
        guard !relative.isEmpty else { return nil }
        let resolved = base.appendingPathComponent(relative).standardizedFileURL
        let root = contentRootURL.standardizedFileURL.path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard resolved.path == root || resolved.path.hasPrefix(prefix) else { return nil }
        return resolved
    }
}

private final class ImageScanDelegate: NSObject, XMLParserDelegate {
    struct Candidate {
        var src: String
        var width: CGFloat?
        var height: CGFloat?
        var dimensions: CGSize? {
            guard let width, let height, width > 0, height > 0 else { return nil }
            return CGSize(width: width, height: height)
        }
    }

    private let limit: Int
    private(set) var candidates: [Candidate] = []

    init(limit: Int) {
        self.limit = limit
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard candidates.count < limit else {
            parser.abortParsing()
            return
        }
        let name = elementName.lowercased()
        guard name == "img" || name.hasSuffix(":img") else { return }
        let attributes = Dictionary(
            uniqueKeysWithValues: attributeDict.map { ($0.key.lowercased(), $0.value) }
        )
        guard let src = attributes["src"], !src.isEmpty else { return }
        candidates.append(Candidate(
            src: src,
            width: EPUBCoverImageExtractor.leadingInt(attributes["width"]),
            height: EPUBCoverImageExtractor.leadingInt(attributes["height"])
        ))
    }
}

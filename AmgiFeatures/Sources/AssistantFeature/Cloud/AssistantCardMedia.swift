import AmgiCardWeb
import Foundation

/// Images belonging to card chips, kept with their original message. Only
/// filenames persist; a resumed chat reloads them from the active media folder.
struct AssistantCardMedia: Equatable, Sendable {
    let sources: [String]
    let images: [AssistantAttachment]
    let warnings: [String]

    func appendingWarnings(to context: String) -> String {
        ([context] + warnings).filter { !$0.isEmpty }.joined(separator: "\n")
    }

    static func sources(in contexts: [AssistantContext]) -> [String] {
        var seen = Set<String>()
        return contexts.flatMap { $0.imageSources ?? [] }.filter { seen.insert($0).inserted }
    }

    /// Keep image-only fields meaningful to text models, and retain their
    /// references for cloud models to receive the actual pixels.
    static func field(_ html: String) -> (text: String, sources: [String]) {
        let tags = try! NSRegularExpression(pattern: #"<img\b[^>]*>"#, options: [.caseInsensitive])
        let src = try! NSRegularExpression(pattern: #"(?<![\w:-])src\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))"#, options: [.caseInsensitive])
        let original = html as NSString
        let text = NSMutableString(string: html)
        var sources: [String] = []
        var replacements: [(NSRange, String)] = []
        for tag in tags.matches(in: html, range: NSRange(location: 0, length: original.length)) {
            let fragment = original.substring(with: tag.range)
            let ns = fragment as NSString
            var source: String?
            if let match = src.firstMatch(in: fragment, range: NSRange(location: 0, length: ns.length)) {
                for index in 1..<match.numberOfRanges where match.range(at: index).location != NSNotFound {
                    source = CardText.plainText(ns.substring(with: match.range(at: index)))
                    break
                }
            }
            let marker: String
            if let source, !source.isEmpty, source.count <= 2048, !source.lowercased().hasPrefix("data:") {
                sources.append(source)
                marker = " [Image: \(source)] "
            } else {
                marker = " [Image: embedded or missing source; image bytes unavailable] "
            }
            replacements.append((tag.range, marker))
        }
        for (range, marker) in replacements.reversed() { text.replaceCharacters(in: range, with: marker) }
        return (CardText.plainText(text as String), sources)
    }

    @concurrent static func load(sources: [String], mediaRoot: URL?, availableSlots: Int) async throws -> Self {
        var images: [AssistantAttachment] = []
        var warnings: [String] = []
        var seen = Set<URL>()
        for source in sources {
            try Task.checkCancellation()
            guard let url = URL(string: source, relativeTo: CardAssetPath.mediaBaseURL)?.absoluteURL,
                  let file = CardAssetPath.resolve(url: url, mediaRoot: mediaRoot, bundleRoot: nil),
                  url.host?.lowercased() == "media" else {
                warnings.append("Card image \(source): not attached; only local collection media can be read.")
                continue
            }
            guard seen.insert(file).inserted else { continue }
            guard images.count < max(0, availableSlots) else {
                warnings.append("Card image \(source): not attached; this message's attachment limit was reached.")
                continue
            }
            do {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values.isRegularFile == true, let size = values.fileSize, size <= AssistantAttachment.maxPDFBytes else {
                    throw AssistantAttachmentError.unreadable(source)
                }
                let data = try Data(contentsOf: file)
                images.append(try AssistantAttachment.image(data, name: source))
            } catch {
                warnings.append("Card image \(source): not attached; the local image is missing or unreadable.")
            }
        }
        return Self(sources: sources, images: images, warnings: warnings)
    }
}

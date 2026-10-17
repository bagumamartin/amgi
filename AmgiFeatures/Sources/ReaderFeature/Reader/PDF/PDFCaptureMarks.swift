import AmgiReader
import Foundation
import PDFKit

/// Draws what has been captured for cards onto the PDF's pages: each passage
/// in its capture's colour, each captured area as a box. A finished card is a
/// highlight or a solid box; a draft still waiting for its other side is a
/// paler highlight with an underline, or a dashed box — tinted either way, so
/// it is seen at a glance.
///
/// The marks are PDFKit annotations that live only in memory. The reader
/// writes the file with incremental updates built from its own records, never
/// by saving the document, so these never reach the file — and
/// `PDFPageAnnotation` skips them by name, so they never reach the
/// annotations list either.
@MainActor
final class PDFCaptureMarks {
    /// Every mark's `userName` starts with this; the rest is
    /// `<kind>-<id>`, which is how a tap finds what it landed on.
    nonisolated static let namePrefix = "amgi-capture-"

    private var painted: [(page: PDFPage, annotation: PDFAnnotation)] = []

    struct Mark {
        enum Kind: String { case card, cardDraft }
        let id: String
        let kind: Kind
        let pageIndex: Int
        let quote: String
        let contextBefore: String?
        let region: ReaderPageRegion?
        let colour: PDFAnnotationColour
    }

    /// The kind and id a mark's name carries, if it is one of these marks.
    nonisolated static func parse(_ name: String?) -> (kind: String, id: String)? {
        guard let name, name.hasPrefix(namePrefix) else { return nil }
        let rest = name.dropFirst(namePrefix.count)
        guard let dash = rest.firstIndex(of: "-") else { return nil }
        return (String(rest[..<dash]), String(rest[rest.index(after: dash)...]))
    }

    /// The marks for a book's saved cards and its drafts.
    static func marks(cards: [ReaderAnnotation], drafts: [ReaderCardDraft]) -> [Mark] {
        var marks: [Mark] = cards.compactMap { card in
            guard let page = card.anchor.cfi else { return nil }
            return Mark(
                id: card.id.uuidString, kind: .card, pageIndex: page,
                quote: card.excerpt, contextBefore: card.anchor.contextBefore, region: card.region,
                colour: PDFAnnotationColour(captureHex: card.colorHex) ?? .captureDefault
            )
        }
        for draft in drafts {
            let colour = PDFAnnotationColour(captureHex: draft.colorHex) ?? .captureDefault
            for clip in draft.frontClips + draft.backClips {
                guard let page = clip.anchor?.cfi ?? clip.region?.page else { continue }
                marks.append(Mark(
                    id: "\(draft.id.uuidString):\(clip.id.uuidString)", kind: .cardDraft, pageIndex: page,
                    quote: clip.excerpt, contextBefore: clip.anchor?.contextBefore, region: clip.region,
                    colour: colour
                ))
            }
        }
        return marks
    }

    /// Replaces whatever was drawn with `marks`.
    func paint(_ marks: [Mark], in document: PDFDocument) {
        for entry in painted { entry.page.removeAnnotation(entry.annotation) }
        painted.removeAll()
        for mark in marks {
            guard let page = document.page(at: mark.pageIndex) else { continue }
            for annotation in Self.annotations(for: mark, on: page) {
                page.addAnnotation(annotation)
                painted.append((page, annotation))
            }
        }
    }

    private static func annotations(for mark: Mark, on page: PDFPage) -> [PDFAnnotation] {
        let name = "\(namePrefix)\(mark.kind.rawValue)-\(mark.id)"
        let colour = mark.colour.platformColor
        if let region = mark.region {
            let box = page.bounds(for: .mediaBox)
            let rect = CGRect(
                x: box.minX + region.x * box.width,
                y: box.maxY - (region.y + region.height) * box.height,
                width: region.width * box.width,
                height: region.height * box.height
            )
            let annotation = PDFAnnotation(bounds: rect, forType: .square, withProperties: nil)
            let border = PDFBorder()
            border.lineWidth = 2
            if mark.kind == .cardDraft {
                border.style = .dashed
                border.dashPattern = [5, 3]
            }
            annotation.border = border
            annotation.color = colour
            annotation.interiorColor = colour.withAlphaComponent(0.10)
            annotation.userName = name
            return [annotation]
        }
        guard let selection = selection(of: mark.quote, before: mark.contextBefore, on: page) else { return [] }
        return selection.selectionsByLine().flatMap { line -> [PDFAnnotation] in
            let bounds = line.bounds(for: page)
            guard bounds.width > 0, bounds.height > 0 else { return [] }
            let tint = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
            tint.color = colour.withAlphaComponent(mark.kind == .card ? 0.45 : 0.28)
            tint.userName = name
            guard mark.kind == .cardDraft else { return [tint] }
            let rule = PDFAnnotation(bounds: bounds, forType: .underline, withProperties: nil)
            rule.color = colour
            rule.userName = name
            return [tint, rule]
        }
    }

    /// The quote on its page, matched with whitespace collapsed — a PDF's
    /// text breaks lines where the quote has spaces — and, when it occurs
    /// more than once, the occurrence its preceding context points at.
    static func selection(of quote: String, before context: String?, on page: PDFPage) -> PDFSelection? {
        let wanted = ReaderSourceAnchor.normalize(quote)
        guard !wanted.isEmpty, let text = page.string else { return nil }
        let source = text as NSString
        var collapsed: [unichar] = []
        var origin: [Int] = []
        collapsed.reserveCapacity(source.length)
        var lastWasSpace = true
        for index in 0..<source.length {
            let unit = source.character(at: index)
            let isSpace = Unicode.Scalar(unit).map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? false
            if isSpace {
                if lastWasSpace { continue }
                collapsed.append(0x20)
                lastWasSpace = true
            } else {
                collapsed.append(unit)
                lastWasSpace = false
            }
            origin.append(index)
        }
        let haystack = NSString(characters: collapsed, length: collapsed.count)
        let suffix = context.map(ReaderSourceAnchor.normalize).flatMap { $0.isEmpty ? nil : String($0.suffix(16)) }
        var best: NSRange?
        var searchFrom = 0
        while searchFrom < haystack.length {
            let found = haystack.range(of: wanted, range: NSRange(location: searchFrom, length: haystack.length - searchFrom))
            guard found.location != NSNotFound else { break }
            if best == nil { best = found }
            if let suffix {
                let before = haystack.substring(to: found.location).trimmingCharacters(in: .whitespaces)
                if before.hasSuffix(suffix) { best = found; break }
            } else {
                break
            }
            searchFrom = found.location + 1
        }
        guard let best, best.length > 0 else { return nil }
        let start = origin[best.location]
        let end = origin[best.location + best.length - 1] + 1
        return page.selection(for: NSRange(location: start, length: end - start))
    }
}

#if canImport(PDFKit)
import Foundation
import PDFKit

/// Reads a PDF with PDFKit and reports what it found.
///
/// PDFKit is Apple's own PDF implementation, and Preview is built on it, so it
/// is the closest available stand-in for "will this file look right to the user
/// when they open it in Preview, or send it through Mail and read it in
/// Preview". Using it as an oracle is what turns a set of self-consistent
/// round-trip tests into evidence of actual interoperability.
///
/// It is deliberately confined to the test target. The production module stays
/// free of PDFKit so it can remain a pure value layer — a PDFKit document object
/// is not `Sendable`, and pulling one into the store would force every
/// annotation operation across an actor boundary.
enum PDFKitProbe {
    static var isAvailable: Bool { true }

    struct Annotation: Sendable {
        /// The `/Subtype` name exactly as PDFKit reports it.
        var subtype: String?
        var contents: String?
    }

    struct Report: Sendable {
        var pageCount: Int
        var annotations: [Annotation]
        var text: String

        var annotationCount: Int { annotations.count }
    }

    enum Failure: Error, CustomStringConvertible {
        case couldNotOpen(URL)

        var description: String {
            switch self {
            case .couldNotOpen(let url): "PDFKit could not open \(url.lastPathComponent)"
            }
        }
    }

    /// Opens `url` and reports its pages, annotations and text.
    ///
    /// Hopped onto the main actor because PDFKit's document types are main-actor
    /// isolated, and swift-testing does not otherwise guarantee a test body runs
    /// there.
    @MainActor
    static func inspect(_ url: URL) throws -> Report {
        guard let document = PDFDocument(url: url) else {
            throw Failure.couldNotOpen(url)
        }
        var annotations: [Annotation] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations {
                annotations.append(Annotation(
                    subtype: annotation.type,
                    contents: annotation.contents
                ))
            }
        }
        return Report(
            pageCount: document.pageCount,
            annotations: annotations,
            text: document.string ?? ""
        )
    }
}
#else
import Foundation

/// Stand-in for platforms without PDFKit, so the round-trip suite compiles
/// everywhere and is skipped rather than failing.
enum PDFKitProbe {
    static var isAvailable: Bool { false }

    struct Annotation: Sendable {
        var subtype: String?
        var contents: String?
    }

    struct Report: Sendable {
        var pageCount: Int = 0
        var annotations: [Annotation] = []
        var text: String = ""
        var annotationCount: Int { 0 }
    }

    struct Failure: Error {}

    static func inspect(_ url: URL) throws -> Report {
        throw Failure()
    }
}
#endif

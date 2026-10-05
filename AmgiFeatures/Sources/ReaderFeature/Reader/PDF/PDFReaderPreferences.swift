import Foundation

/// PDF page navigation has different semantics from reflowable-book layout.
/// These settings keep a PDF-only change from silently switching EPUB readers.
enum PDFReaderPreferences {
    enum PageNavigation: String, CaseIterable, Identifiable {
        case paged
        case continuous

        var id: String { rawValue }

        var label: String {
            switch self {
            case .paged: "Page"
            case .continuous: "Continuous Scroll"
            }
        }
    }

    enum Keys {
        static let pageNavigation = "reader_pdf_page_navigation"
    }
}

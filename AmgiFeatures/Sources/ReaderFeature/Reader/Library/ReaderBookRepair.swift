import AmgiReader
import AmgiReaderEPUB
import AmgiReaderPDF
import Foundation

/// Which reader format a book comes from.
///
/// Carried so repair copy can name the format: "Could not read this EPUB" is
/// actively misleading next to a PDF, and the two formats fail for different
/// reasons often enough that a single message would be vague for both.
enum ReaderSourceFormat: String, Equatable, Sendable {
    case epub
    case pdf

    var displayName: String {
        switch self {
        case .epub: "EPUB"
        case .pdf: "PDF"
        }
    }

    init?(source: ReaderBookSource) {
        switch source {
        case .ankiDeck: return nil
        case .epub: self = .epub
        case .pdf: self = .pdf
        }
    }
}

/// User-facing description of why a book needs repair.
///
/// Format-neutral: the library holds EPUBs and PDFs, and a fault means the same
/// thing in both — the managed file is gone, unreadable, or not what it claims
/// to be. The differences are in the copy and in what can be done about it, so
/// they are fields here rather than two parallel types.
struct ReaderBookRepair: Equatable {
    /// What went wrong, in terms both formats share.
    enum Fault: String, Equatable, Sendable {
        /// The managed source file is absent.
        case sourceMissing
        /// The file exists but could not be read.
        case sourceUnreadable
        /// The file is not a document of the format it claims to be, or its
        /// structure is too damaged to read.
        case parseFailed
        /// The document is encrypted: readable, but not annotatable.
        ///
        /// Kept distinct from `parseFailed` because the advice is different and
        /// no amount of retrying will help. An encrypted PDF opens in Preview;
        /// telling the user to repair it is telling them to do something that
        /// cannot work.
        case encrypted
    }

    let fault: Fault
    let detail: String?
    let format: ReaderSourceFormat

    init(fault: Fault, detail: String?, format: ReaderSourceFormat) {
        self.fault = fault
        self.detail = detail
        self.format = format
    }

    init(fault: EPUBLibraryEntryFault, detail: String?) {
        self.init(
            fault: Fault(fault),
            detail: detail,
            format: .epub
        )
    }

    init(fault: PDFLibraryEntryFault, detail: String?) {
        self.init(
            fault: Fault(fault),
            detail: detail,
            format: .pdf
        )
    }

    var title: String {
        switch fault {
        case .sourceMissing: "Source file missing"
        case .sourceUnreadable: "Source file unreadable"
        case .parseFailed: "Could not read this \(format.displayName)"
        case .encrypted: "This \(format.displayName) is encrypted"
        }
    }

    var message: String {
        let trimmed = detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            switch fault {
            case .encrypted:
                return "It can be read, but not marked up. Remove the password to annotate it."
            default:
                return "This book could not be opened. Repair it to restore the original file."
            }
        }
        return trimmed
    }

    /// Whether retrying in place can help.
    ///
    /// A missing source can only be fixed by pointing at a replacement. Neither
    /// can encryption: the document is fine, the password is the obstacle, and
    /// only removing it helps — so offering "try again" would be offering a
    /// button that cannot do anything.
    var canRetryInPlace: Bool {
        fault != .sourceMissing && fault != .encrypted
    }
}

extension ReaderBookRepair.Fault {
    init(_ fault: EPUBLibraryEntryFault) {
        switch fault {
        case .sourceMissing: self = .sourceMissing
        case .sourceUnreadable: self = .sourceUnreadable
        case .parseFailed: self = .parseFailed
        }
    }

    init(_ fault: PDFLibraryEntryFault) {
        switch fault {
        case .sourceMissing: self = .sourceMissing
        case .sourceUnreadable: self = .sourceUnreadable
        case .parseFailed: self = .parseFailed
        case .encrypted: self = .encrypted
        }
    }
}

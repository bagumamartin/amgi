import Foundation
import SwiftUI

/// The colours a capture can carry.
///
/// The same six as the PDF reader's highlights (Preview's own values), so a
/// colour means one thing across both readers and both kinds of mark: a blue
/// capture in an EPUB and a blue highlight in a PDF are the same blue. What a
/// colour *stands for* is the reader's to decide — definitions in green,
/// formulas in purple — which is why it is chosen per capture and not derived
/// from the deck.
extension PDFAnnotationColour {
    /// What a book's captures start as: the colour card marks always had.
    static let captureDefault: PDFAnnotationColour = .blue

    /// Order in the picker. Blue leads because it is the default.
    static let captureChoices: [PDFAnnotationColour] = [.blue, .green, .yellow, .pink, .purple, .grey]

    /// `#RRGGBB`, as stored on drafts and marks.
    var hex: String {
        let (r, g, b) = rgb
        return String(format: "#%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }

    /// The colour a stored hex names, if it is one of ours.
    init?(captureHex hex: String?) {
        guard let hex, let match = Self.allCases.first(where: { $0.hex.caseInsensitiveCompare(hex) == .orderedSame }) else {
            return nil
        }
        self = match
    }
}

/// The colour new captures in a book take: the last one the reader chose
/// there. Choosing a colour is a decision about the captures that follow, so
/// it sticks until the reader changes it again.
enum ReaderCaptureColourMemory {
    private static func key(_ bookID: String) -> String { "reader_capture_colour_\(bookID)" }

    static func colour(forBook bookID: String?) -> PDFAnnotationColour {
        guard let bookID,
              let stored = UserDefaults.standard.string(forKey: key(bookID)),
              let colour = PDFAnnotationColour(rawValue: stored) else { return .captureDefault }
        return colour
    }

    static func remember(_ colour: PDFAnnotationColour, forBook bookID: String?) {
        guard let bookID else { return }
        UserDefaults.standard.set(colour.rawValue, forKey: key(bookID))
    }
}

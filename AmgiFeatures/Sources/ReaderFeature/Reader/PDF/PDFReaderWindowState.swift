public import Observation
public import SwiftUI

/// Lets the macOS app shell replace its section sidebar with the PDF's page
/// sidebar while a document is open.
@MainActor
@Observable
public final class PDFReaderWindowState {
    public var isActive = false

    public init() {}
}

private struct PDFReaderWindowStateEnvironmentKey: EnvironmentKey {
    static let defaultValue: PDFReaderWindowState? = nil
}

public extension EnvironmentValues {
    var pdfReaderWindowState: PDFReaderWindowState? {
        get { self[PDFReaderWindowStateEnvironmentKey.self] }
        set { self[PDFReaderWindowStateEnvironmentKey.self] = newValue }
    }
}

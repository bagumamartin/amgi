package import UniformTypeIdentifiers

/// File types the library can import and repair.
///
/// Declared in one place because three surfaces need the same answer — the
/// library's import picker, the repair sheet's relink picker, and the
/// app-level drop handler — and three copies of a file-type list is three
/// chances for the library to accept a format the reader cannot open.
///
/// Both fall back to `.data` rather than being omitted. A picker that silently
/// greys out a file the app can in fact read is worse than one that offers
/// everything and reports a clear error when the extension is wrong.
extension UTType {
    /// EPUB has no dedicated `UTType` in all SDKs; the bundle's document type is
    /// declared in Info.plist, so match on the extension.
    package static let epub = UTType(filenameExtension: "epub") ?? .data
    /// Everything the reader library accepts.
    ///
    /// PDF needs no declaration of its own — `UTType.pdf` is a system type —
    /// and shadowing it here with a same-named constant would be a trap for
    /// whoever reads this next and wonders why the two differ.
    package static let readerDocuments: [UTType] = [.epub, .pdf]
}

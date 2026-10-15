import AmgiReader
import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// A book's own file, offered to the share sheet under the book's title.
///
/// The library keeps every EPUB as `original.epub` inside an opaque book
/// folder, so sharing the stored file directly would hand AirDrop or Mail a
/// file called "original". The export copies it to a temporary file named
/// after the book instead.
struct BookShareFile: Transferable {
    let sourceURL: URL
    let title: String
    let contentType: UTType

    init?(book: ReaderBook) {
        switch book.source {
        case .epub(let url):
            sourceURL = url
            contentType = .epub
        case .pdf(let url):
            sourceURL = url
            contentType = .pdf
        case .ankiDeck:
            return nil
        }
        title = book.title
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .epub) { try $0.exportCopy() }
            .exportingCondition { $0.contentType == .epub }
        FileRepresentation(exportedContentType: .pdf) { try $0.exportCopy() }
            .exportingCondition { $0.contentType == .pdf }
    }

    private func exportCopy() throws -> SentTransferredFile {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookShare-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = ReaderICloudBookNaming.baseName(forTitle: title)
        let destination = directory
            .appendingPathComponent(name.isEmpty ? "Book" : name)
            .appendingPathExtension(contentType.preferredFilenameExtension ?? "")
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        return SentTransferredFile(destination)
    }
}

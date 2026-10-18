import AmgiAppCore
import CoreTransferable
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A photo or PDF sent with one message. Cloud models only: Apple's
/// on-device model takes text.
struct AssistantAttachment: Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case image, pdf }

    let id: UUID
    let kind: Kind
    let name: String
    let data: Data
    let mimeType: String
    /// A small JPEG for the chip.
    let thumbnail: Data?

    var dataURL: String { "data:\(mimeType);base64,\(data.base64EncodedString())" }

    /// Per message, matching Anthropic's cap on inline images.
    static let limit = 5
    static let maxPDFBytes = 24 * 1024 * 1024

    /// Images are re-encoded as JPEG no larger than providers read anyway, so
    /// a 48 MP photo doesn't upload 15 MB for no gain.
    static func image(_ data: Data, name: String) throws -> AssistantAttachment {
        guard let jpeg = downscaledJPEG(data, maxPixel: 1568, quality: 0.82) else {
            throw AssistantAttachmentError.unreadable(name)
        }
        return AssistantAttachment(
            id: UUID(), kind: .image, name: name, data: jpeg, mimeType: "image/jpeg",
            thumbnail: downscaledJPEG(data, maxPixel: 160, quality: 0.7)
        )
    }

    static func pdf(_ data: Data, name: String) throws -> AssistantAttachment {
        guard data.count <= maxPDFBytes else { throw AssistantAttachmentError.tooLarge(name) }
        guard data.starts(with: Data("%PDF".utf8)) else { throw AssistantAttachmentError.unreadable(name) }
        return AssistantAttachment(id: UUID(), kind: .pdf, name: name, data: data, mimeType: "application/pdf", thumbnail: nil)
    }

    /// From a file the user picked: PDFs as documents, anything else that
    /// decodes as an image as a photo.
    static func file(at url: URL) throws -> AssistantAttachment {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        let name = url.lastPathComponent
        if UTType(filenameExtension: url.pathExtension)?.conforms(to: .pdf) == true { return try pdf(data, name: name) }
        return try image(data, name: name)
    }

    private static func downscaledJPEG(_ data: Data, maxPixel: Int, quality: Double) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}

enum AssistantAttachmentError: LocalizedError {
    case unreadable(String)
    case tooLarge(String)
    case limit

    var errorDescription: String? {
        switch self {
        case .unreadable(let name): L10n.text("\(name) couldn't be read as a photo or PDF.")
        case .tooLarge(let name): L10n.text("\(name) is larger than 24 MB.")
        case .limit: L10n.text("You can attach up to \(AssistantAttachment.limit) files per message.")
        }
    }
}

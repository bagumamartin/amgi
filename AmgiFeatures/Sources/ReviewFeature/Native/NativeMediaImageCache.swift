import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// In-memory cache for native-card media images, keyed by resolved file
/// path. Stores decoded `CGImage`s (Sendable) so the decode can run off the
/// main actor and views only wrap the result in SwiftUI `Image`.
///
/// The previous implementation read + decoded the file synchronously in
/// `NativeCardView.body` on every evaluation — full-resolution decode on the
/// main thread inside the flip animation, repeated whenever any observed
/// session field invalidated the parent.
@MainActor
final class NativeMediaImageCache {
    static let shared = NativeMediaImageCache()

    /// Bound decoded images in memory; review cards revisit few images per
    /// session, so a small LRU-ish count limit is plenty.
    private let cache = NSCache<NSString, Box>()
    private var inFlight: [String: Task<CGImage?, Never>] = [:]

    /// Cap the longest edge so a 6000px photo doesn't decode at full size
    /// just to fit a card column.
    private let maxPixelDimension = 2048

    private final class Box {
        let image: CGImage
        init(image: CGImage) { self.image = image }
    }

    func image(at path: String) async -> CGImage? {
        if let boxed = cache.object(forKey: path as NSString) {
            return boxed.image
        }
        if let existing = inFlight[path] {
            return await existing.value
        }
        let task = Task.detached(priority: .userInitiated) { [maxPixelDimension] in
            Self.decode(path: path, maxPixelDimension: maxPixelDimension)
        }
        inFlight[path] = task
        let image = await task.value
        inFlight[path] = nil
        if let image {
            cache.setObject(Box(image: image), forKey: path as NSString)
        }
        return image
    }

    // MARK: - Decode

    nonisolated private static func utType(for filename: String) -> UTType? {
        let ext = (filename as NSString).pathExtension.lowercased()
        return switch ext {
        case "png": .png
        case "jpg", "jpeg": .jpeg
        case "gif": .gif
        case "webp": .webP
        case "svg": nil // CGImageSource cannot rasterize SVG
        default: nil
        }
    }

    nonisolated private static func decode(path: String, maxPixelDimension: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else {
            return nil
        }
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelDimension,
        ]
        // Media filenames often lack a useful extension hint; supply the
        // type explicitly so ImageIO doesn't have to sniff it.
        if let type = utType(for: path) {
            options[kCGImageSourceTypeIdentifierHint] = type.identifier as CFString
        }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

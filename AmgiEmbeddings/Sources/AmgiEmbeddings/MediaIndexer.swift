@preconcurrency import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import PDFKit
import Vision

/// Indexes only URLs explicitly supplied by Ijuka's owned-content adapters.
/// DigUp inspired window/frame selection, OCR, anchors and resumable commits;
/// inference remains our shared MLX runtime (not DigUp's llama.cpp backend).
public actor MediaIndexer {
    private let index: RetrievalIndex
    private let cache: URL
    public private(set) var failures: [String] = []
    public init(index: RetrievalIndex, cache: URL) { self.index = index; self.cache = cache }
    public func indexFile(_ url: URL, sourceID: String, title: String) async throws {
        try Task.checkCancellation()
        let fingerprint = try Self.fingerprint(url)
        let ext = url.pathExtension.lowercased()
        var kept = Set<String>()
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        if ext == "pdf" {
            guard let document = PDFDocument(url: url) else { throw MediaIndexError.unreadable }
            for pageIndex in 0..<document.pageCount {
                try await backgroundBudget()
                guard let page = document.page(at: pageIndex) else { continue }
                let id = "\(sourceID):page:\(pageIndex)"; kept.insert(id)
                if let cached = try await index.cached(id, fingerprint: fingerprint), cached.vector != nil {
                    for offset in Self.passages(cached.text).indices { kept.insert(id + ":text:\(offset)") }
                    continue
                }
                let image = try Self.render(page)
                let imageURL = try Self.write(image, to: cache.appendingPathComponent(Self.cacheName(id) + ".png"))
                defer { try? FileManager.default.removeItem(at: imageURL) }
                let text = [page.string ?? "", try Self.ocr(image)].filter { !$0.isEmpty }.joined(separator: "\n")
                var segment = RetrievalSegment(id: id, sourceID: sourceID, title: title, text: text, modality: .image, anchor: "page:\(pageIndex + 1)", sourceURL: url, fingerprint: fingerprint)
                // Text layer remains searchable without a vision download.
                segment.vector = ModelAssetManager.isInstalled(.vision) ? try await TextEmbedder.shared.embedMixed([.text(String(text.prefix(6000))), .image(imageURL)]) : nil
                try await index.upsert(segment)
                // Pages with substantial text also get bounded passage vectors.
                for (offset, passage) in Self.passages(text).enumerated() {
                    let passageID = id + ":text:\(offset)"; kept.insert(passageID)
                    try await indexText(passage, id: passageID, sourceID: sourceID, title: title, anchor: "page:\(pageIndex + 1):passage:\(offset)", url: url, fingerprint: fingerprint)
                }
            }
        } else if ["mp4", "mov", "m4v", "webm"].contains(ext) {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite && duration > 0 else { throw MediaIndexError.unreadable }
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 1024, height: 1024)
            var previousHash: UInt64?
            // No silent frame-count cap: incremental commits cover the full file.
            for seconds in stride(from: 0.0, to: duration, by: 3.0) {
                try await backgroundBudget()
                let id = "\(sourceID):frame:\(Int(seconds))"; kept.insert(id)
                if let cached = try await index.cached(id, fingerprint: fingerprint), cached.vector != nil { previousHash = cached.imageHash; continue }
                let result = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
                let hash = try Self.averageHash(result.image)
                if let previousHash, (hash ^ previousHash).nonzeroBitCount <= 4 { kept.remove(id); continue }
                previousHash = hash
                let imageURL = try Self.write(result.image, to: cache.appendingPathComponent(Self.cacheName(id) + ".png"))
                defer { try? FileManager.default.removeItem(at: imageURL) }
                let text = try Self.ocr(result.image)
                var segment = RetrievalSegment(id: id, sourceID: sourceID, title: title, text: text, modality: .video, anchor: "time:\(seconds)", sourceURL: url, fingerprint: fingerprint)
                if ModelAssetManager.isInstalled(.vision) {
                    segment.vector = try await TextEmbedder.shared.embedMixed([.videoFrame(imageURL, timestamp: seconds)])
                }
                segment.imageHash = hash
                try await index.upsert(segment)
            }
            kept.formUnion(try await audio(asset: asset, url: url, sourceID: sourceID, title: title, fingerprint: fingerprint))
        } else if ["wav", "mp3", "m4a", "aac", "aiff", "flac", "ogg"].contains(ext) {
            kept = try await audio(asset: AVURLAsset(url: url), url: url, sourceID: sourceID, title: title, fingerprint: fingerprint)
        } else if ["png", "jpg", "jpeg", "heic", "webp", "tif", "tiff", "gif"].contains(ext) {
            let id = sourceID + ":image"; kept.insert(id)
            if let cached = try await index.cached(id, fingerprint: fingerprint), cached.vector != nil { return }
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 1400]
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw MediaIndexError.unreadable }
            let flattened = try Self.flatten(image)
            let imageURL = try Self.write(flattened, to: cache.appendingPathComponent(Self.cacheName(id) + ".png"))
            defer { try? FileManager.default.removeItem(at: imageURL) }
            var segment = RetrievalSegment(id: id, sourceID: sourceID, title: title, text: try Self.ocr(flattened), modality: .image, anchor: "image", sourceURL: url, fingerprint: fingerprint)
            if ModelAssetManager.isInstalled(.vision) { segment.vector = try await TextEmbedder.shared.embedImage(imageURL) }
            try await index.upsert(segment)
        } else { return }
        try Task.checkCancellation()
        try await index.pruneSource(sourceID, keeping: kept)
    }
    private func audio(asset: AVAsset, url: URL, sourceID: String, title: String, fingerprint: String) async throws -> Set<String> {
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? MediaIndexError.unreadable }
        defer { reader.cancelReading() }
        var samples: [Float] = []; var start = 0; var kept = Set<String>()
        let window = 30 * 16000, hop = 25 * 16000
        while let buffer = output.copyNextSampleBuffer() {
            try await backgroundBudget()
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let bytes = CMBlockBufferGetDataLength(block)
            var floats = [Float](repeating: 0, count: bytes / MemoryLayout<Float>.size)
            let code = floats.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes, destination: $0.baseAddress!) }
            guard code == kCMBlockBufferNoErr else { throw MediaIndexError.unreadable }
            samples += floats
            while samples.count >= window {
                let id = "\(sourceID):audio:\(start)"; kept.insert(id)
                try await audioWindow(Array(samples.prefix(window)), start: start, id: id, sourceID: sourceID, title: title, url: url, fingerprint: fingerprint)
                samples.removeFirst(hop); start += hop
            }
        }
        guard reader.status != .failed else { throw reader.error ?? MediaIndexError.unreadable }
        if !samples.isEmpty {
            let id = "\(sourceID):audio:\(start)"; kept.insert(id)
            try await audioWindow(samples, start: start, id: id, sourceID: sourceID, title: title, url: url, fingerprint: fingerprint)
        }
        return kept
    }
    private func audioWindow(_ samples: [Float], start: Int, id: String, sourceID: String, title: String, url: URL, fingerprint: String) async throws {
        if let cached = try await index.cached(id, fingerprint: fingerprint), cached.vector != nil { return }
        var segment = RetrievalSegment(id: id, sourceID: sourceID, title: title, text: title, modality: .audio, anchor: "time:\(Double(start) / 16000)-\(Double(start + samples.count) / 16000)", sourceURL: url, fingerprint: fingerprint)
        if ModelAssetManager.isInstalled(.audio) { segment.vector = try await TextEmbedder.shared.embedAudio(samples: samples) }
        try await index.upsert(segment)
    }
    public func indexText(_ text: String, id: String, sourceID: String, title: String, anchor: String = "", url: URL? = nil, fingerprint: String) async throws {
        if let cached = try await index.cached(id, fingerprint: fingerprint), cached.vector != nil { return }
        try await backgroundBudget()
        var segment = RetrievalSegment(id: id, sourceID: sourceID, title: title, text: text, anchor: anchor, sourceURL: url, fingerprint: fingerprint)
        if ModelAssetManager.isModelInstalled {
            do { segment.vector = try await TextEmbedder.shared.embed(text, prefix: .passage) }
            catch is CancellationError { throw CancellationError() }
            catch { failures.append("\(title) [\(anchor)]: \(error.localizedDescription)") }
        }
        try await index.upsert(segment)
    }
    /// Bounded, overlapping passages; never silently truncate an entire source.
    public nonisolated static func passages(_ text: String, width: Int = 1800, overlap: Int = 200) -> [String] {
        guard !text.isEmpty else { return [] }
        let chars = Array(text); var result: [String] = []; var start = 0
        while start < chars.count {
            let end = min(chars.count, start + width)
            result.append(String(chars[start..<end]))
            if end == chars.count { break }
            start += max(1, width - overlap)
        }
        return result
    }
    private func backgroundBudget() async throws {
        try Task.checkCancellation()
        while ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical || ProcessInfo.processInfo.isLowPowerModeEnabled {
            try await Task.sleep(for: .seconds(2))
        }
        await Task.yield()
    }
    public nonisolated static func fingerprint(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 1 << 20), !data.isEmpty { try Task.checkCancellation(); hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private nonisolated static func cacheName(_ id: String) -> String { SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined() }
    private nonisolated static func ocr(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate; request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
    private nonisolated static func flatten(_ image: CGImage) throws -> CGImage {
        let maxSize = 1400.0, scale = min(1, maxSize / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * scale)), height = max(1, Int(Double(image.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw MediaIndexError.unreadable }
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height)); context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else { throw MediaIndexError.unreadable }; return result
    }
    private nonisolated static func render(_ page: PDFPage) throws -> CGImage {
        guard let ref = page.pageRef else { throw MediaIndexError.unreadable }
        let bounds = ref.getBoxRect(.cropBox), scale = min(2, 1400 / max(bounds.width, bounds.height))
        let width = max(1, Int(bounds.width * scale)), height = max(1, Int(bounds.height * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw MediaIndexError.unreadable }
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.concatenate(ref.getDrawingTransform(.cropBox, rect: CGRect(x: 0, y: 0, width: width, height: height), rotate: 0, preserveAspectRatio: true)); context.drawPDFPage(ref)
        guard let result = context.makeImage() else { throw MediaIndexError.unreadable }; return result
    }
    private nonisolated static func write(_ image: CGImage, to url: URL) throws -> URL {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { throw MediaIndexError.unreadable }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw MediaIndexError.unreadable }; return url
    }
    private nonisolated static func averageHash(_ image: CGImage) throws -> UInt64 {
        var pixels = [UInt8](repeating: 0, count: 64)
        return try pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 8, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { throw MediaIndexError.unreadable }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 8, height: 8))
            let bytes = buffer.bindMemory(to: UInt8.self)
            let mean = bytes.reduce(0) { $0 + Int($1) } / 64
            return bytes.enumerated().reduce(UInt64(0)) { $0 | (Int($1.element) >= mean ? UInt64(1) << $1.offset : 0) }
        }
    }
}
enum MediaIndexError: Error { case unreadable }

import Foundation
import OSLog

/// A running log of what the EPUB reader did, for diagnosing bugs seen on a
/// device: every turn, jump, reload, page report and page-picture swap, with
/// the state that decided it.
///
/// Written as JSON lines to `Documents/ReaderTelemetry/epub.log` in the app's
/// container (pull it with `xcrun devicectl device copy from --domain-type
/// appDataContainer`), and mirrored to the unified log under the
/// `reader.epub` category. Debug builds only; a release build records
/// nothing.
enum ReaderTelemetry {
    private static let logger = Logger(subsystem: "com.bagumamartin.ijuka", category: "reader.epub")
    private static let queue = DispatchQueue(label: "reader.telemetry", qos: .utility)
    private static let start = Date()
    /// Keeps the file to the last session or so of reading.
    private static let maxBytes = 4 * 1024 * 1024

    static var fileURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("ReaderTelemetry", isDirectory: true)
            .appendingPathComponent("epub.log")
    }

    /// Records one event. `fields` values are stringified; keep them small.
    static func log(_ event: String, _ fields: [String: Any] = [:]) {
        #if DEBUG
        let elapsed = Date().timeIntervalSince(start)
        var record: [String: Any] = ["t": (elapsed * 1000).rounded() / 1000, "event": event]
        for (key, value) in fields { record[key] = "\(value)" }
        let summary = fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        logger.debug("\(event, privacy: .public) \(summary, privacy: .public)")
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
        queue.async { append(data) }
        #endif
    }

    /// Marks the start of a reading session, so one file can hold several.
    static func beginSession(_ fields: [String: Any]) {
        log("session.begin", fields)
    }

    private static func append(_ line: Data) {
        guard let url = fileURL else { return }
        let manager = FileManager.default
        try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? manager.attributesOfItem(atPath: url.path)[.size]) as? Int, size > maxBytes {
            let old = url.deletingPathExtension().appendingPathExtension("previous.log")
            try? manager.removeItem(at: old)
            try? manager.moveItem(at: url, to: old)
        }
        if !manager.fileExists(atPath: url.path) {
            manager.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line + Data([0x0A]))
    }
}

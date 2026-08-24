import Foundation
import AnkiBackend
import AnkiKit
import AnkiProtoBridge
import MCP

/// Collection-config access (escape hatch for advanced agent workflows:
/// per-deck limits, app-specific conf blobs like deck icons) and media
/// tools.
///
/// Config writes follow the app's own discipline: fetch-fresh → patch →
/// write immediately. The Darwin notification makes the running app
/// reload right after, so its next blob write starts from current state.
/// Residual risk is only a same-instant human+agent edit of the SAME key.
enum ConfigMediaTools {
    static var tools: [AmgiTool] {
        [
            AmgiTool(
                name: "get_config_json",
                description: """
                    Reads a collection-config value as raw JSON (col.conf escape \
                    hatch). Returns null-ish text when the key was never set.
                    """,
                inputSchema: Schema.object(
                    ["key": Schema.string("Config key, e.g. \"amgi.deckIcons\"")],
                    required: ["key"]
                ),
                minimumTier: .readOnly
            ) { ctx, args in
                let key = try args.requireString("key")
                let json: Data?
                do {
                    json = try ctx.backend().invoke(.configGetRaw(key: key))
                } catch let error as BackendError where error.kind == .notFoundError {
                    json = nil
                }
                guard let json else { return "(unset)" }
                return String(decoding: json, as: UTF8.self)
            },
            AmgiTool(
                name: "set_config_json",
                description: """
                    Writes a collection-config value from raw JSON. For blob keys \
                    (e.g. amgi.deckIcons) ALWAYS get first and merge — the whole blob \
                    is replaced last-writer-wins.
                    """,
                inputSchema: Schema.object(
                    [
                        "key": Schema.string("Config key"),
                        "value_json": Schema.string("Raw JSON document"),
                    ],
                    required: ["key", "value_json"]
                ),
                minimumTier: .safeWrite,
                mutates: true
            ) { ctx, args in
                let key = try args.requireString("key")
                let raw = try args.rawJSONString("value_json")
                // Validate before dispatch so agents get a precise error
                // instead of a backend proto failure.
                do {
                    _ = try JSONSerialization.jsonObject(with: Data(raw.utf8))
                } catch {
                    throw ToolError.badArg("value_json", "invalid JSON: \(error.localizedDescription)")
                }
                try ctx.backend().invoke(.configSetRawNoUndo(key: key, json: Data(raw.utf8)))
                return "set config '\(key)'"
            },
            AmgiTool(
                name: "add_media_file",
                description: """
                    Copies a media file into the collection's media folder. Returns the \
                    canonical filename to reference in note fields (<img src="…"> / \
                    [sound:…]).
                    """,
                inputSchema: Schema.object(
                    [
                        "file_path": Schema.string("Absolute path of the source file"),
                        "desired_name": Schema.string("Optional target filename"),
                    ],
                    required: ["file_path"]
                ),
                minimumTier: .safeWrite,
                mutates: true
            ) { ctx, args in
                let path = try args.requireString("file_path")
                let desiredName = args.optionalString("desired_name")
                    ?? (path as NSString).lastPathComponent
                let fm = FileManager.default
                guard fm.fileExists(atPath: path) else {
                    throw ToolError.notFound("file \(path)")
                }
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                let canonical = try ctx.backend().invoke(.addMediaFile(desiredName: desiredName, data: data))
                return "stored as '\(canonical)' (\(data.count) bytes)"
            },
            AmgiTool(
                name: "check_media",
                description: "Runs the media integrity check; reports missing/unused files.",
                inputSchema: .object([:]),
                minimumTier: .readOnly
            ) { ctx, _ in
                let result = try ctx.backend().invoke(.checkMedia)
                if result.missing.isEmpty && result.unused.isEmpty {
                    return "media OK — nothing missing or unused"
                }
                var lines = [String]()
                if !result.missing.isEmpty {
                    lines.append("missing files (\(result.missing.count)): \(result.missing.prefix(30).joined(separator: ", "))")
                }
                if !result.unused.isEmpty {
                    lines.append("unused files (\(result.unused.count)): \(result.unused.prefix(30).joined(separator: ", "))")
                }
                if result.haveTrash { lines.append("(media trash contains recoverable files)") }
                return lines.joined(separator: "\n")
            },
        ]
    }
}

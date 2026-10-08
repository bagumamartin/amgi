import AnkiKit
import Foundation
import Observation

/// App-side authority for MCP configuration. Owns `mcp.json` (written
/// next to the profiles so the unsandboxed helper reads it directly),
/// detects installed helper binaries, and renders per-client
/// registration snippets.
///
/// The helper process itself lives in the AnkiBridge package
/// (`ijuka-mcp` executable); this store only manages its configuration.
@MainActor
@Observable
final class MCPManager {
    static let shared = MCPManager()

    /// External clients require a standalone helper. The App Store helper
    /// inherits the app sandbox and cannot be launched directly by clients.
    private static func realHomeDirectory() -> String {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return String(cString: dir)
        }
        return NSHomeDirectory()
    }

    private static var candidatePaths: [String] {
        var paths: [String] = []
        paths.append("\(realHomeDirectory())/bin/ijuka-mcp")
        paths.append("/usr/local/bin/ijuka-mcp")
        return paths
    }

    private(set) var settings: MCPSettings

    init() {
        settings = MCPSettings.load(from: Self.configURL.path)
    }

    static var configURL: URL {
        CollectionLayout.rootDirectory().appendingPathComponent("mcp.json")
    }

    func update(_ mutate: (inout MCPSettings) -> Void) {
        mutate(&settings)
        persist()
    }

    private func persist() {
        let url = Self.configURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(settings).write(to: url, options: .atomic)
        } catch {
            NSLog("MCPManager: failed to write \(url.path): \(error)")
        }
    }

    // MARK: - Helper binary discovery

    /// First existing helper binary, preferring an explicit install over
    /// a Debug build product that may vanish with `.build`.
    var detectedHelperPath: String? {
        if let override = UserDefaults.standard.string(forKey: "ijuka.mcp.helperPath"),
           FileManager.default.fileExists(atPath: override) {
            return override
        }
        for candidate in Self.candidatePaths where FileManager.default.fileExists(atPath: candidate) {
            return candidate
        }
        return nil
    }

    // MARK: - Registration snippets

    struct ConnectionSnippet: Identifiable {
        let label: String
        let text: String
        var id: String { label }
    }

    /// Register the standalone helper over stdio.
    /// Every MCP client speaks this (Claude Desktop/Code, Cursor, Codex,
    /// Zed, Gemini, Qwen, Hermes, …). Prefer the installed standalone helper
    /// so older cached Python launchers cannot select the App Store helper.
    var connectionSnippets: [ConnectionSnippet] {
        let helperPath = detectedHelperPath
        let command = helperPath ?? "uvx"
        let arguments = helperPath == nil ? ["ijuka-mcp"] : []
        let encodedArguments = String(data: try! JSONEncoder().encode(arguments), encoding: .utf8)!
        let encodedCommand = String(data: try! JSONEncoder().encode(command), encoding: .utf8)!
        return [
            .init(
                label: "Command / Parameters",
                text: "Command: \(command)\nParameters: \(arguments.joined(separator: " "))"
            ),
            .init(
                label: "JSON configuration",
                text: """
                {
                  "mcpServers": {
                    "ijuka": {
                      "command": \(encodedCommand),
                      "args": \(encodedArguments)
                    }
                  }
                }
                """
            ),
        ]
    }
}

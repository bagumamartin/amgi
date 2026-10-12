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

    /// Use uvx even when a standalone helper is installed: some clients
    /// restrict STDIO commands to uvx/npx. The launcher resolves the native
    /// helper afresh whenever a client starts it.
    var connectionSnippets: [ConnectionSnippet] {
        [
            .init(
                label: "Command / Parameters",
                text: "Command: uvx\nParameters: ijuka-mcp"
            ),
            .init(
                label: "JSON configuration",
                text: """
                {
                  "mcpServers": {
                    "ijuka": {
                      "command": "uvx",
                      "args": ["ijuka-mcp"]
                    }
                  }
                }
                """
            ),
        ]
    }
}

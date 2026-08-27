import AnkiKit
import Foundation
import Observation

/// App-side authority for MCP configuration. Owns `mcp.json` (written
/// next to the profiles so the unsandboxed helper reads it directly),
/// detects installed helper binaries, and renders per-client
/// registration snippets.
///
/// The helper process itself lives in the AnkiBridge package
/// (`amgi-mcp` executable); this store only manages its configuration.
@MainActor
@Observable
final class MCPManager {
    static let shared = MCPManager()

    /// Where clients look for the helper, in priority order:
    /// 1. User override (`defaults write amgi.mcp.helperPath …`)
    /// 2. Bundled with the app — `Amgi.app/Contents/Helpers/amgi-mcp`.
    ///    This is the normal case for end users: installing the app is
    ///    all that's needed, and the path survives app updates.
    /// 3. PATH installs (~/bin, /usr/local/bin) — developer convenience
    ///    from scripts/install-mcp-helper.sh.
    private static func realHomeDirectory() -> String {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return String(cString: dir)
        }
        return NSHomeDirectory()
    }

    private static var candidatePaths: [String] {
        var paths: [String] = []
        // The bundled helper lives inside whichever .app bundle is
        // running — DerivedData for DEBUG, /Applications for RELEASE.
        // Bundle.main resolves correctly for both.
        let contents = Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
        paths.append(contents.appendingPathComponent("Helpers/amgi-mcp").path)
        // Fallback layout in case the copy phase destination changes.
        paths.append(contents.appendingPathComponent("MacOS/amgi-mcp").path)
        paths.append("\(realHomeDirectory())/bin/amgi-mcp")
        paths.append("/usr/local/bin/amgi-mcp")
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
        if let override = UserDefaults.standard.string(forKey: "amgi.mcp.helperPath"),
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

    /// The one industry-standard registration: `uvx amgi-mcp` over stdio.
    /// Every MCP client speaks this (Claude Desktop/Code, Cursor, Codex,
    /// Zed, Gemini, Qwen, Hermes, …). The PyPI shim finds the bundled
    /// helper itself, so no absolute paths and no per-client formats.
    var connectionSnippets: [ConnectionSnippet] {
        [
            .init(
                label: "Command / Parameters",
                text: "Command: uvx\nParameters: amgi-mcp"
            ),
            .init(
                label: "JSON configuration",
                text: """
                {
                  "mcpServers": {
                    "amgi": {
                      "command": "uvx",
                      "args": ["amgi-mcp"]
                    }
                  }
                }
                """
            ),
        ]
    }
}

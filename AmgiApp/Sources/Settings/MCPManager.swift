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

    /// Local streamable-HTTP endpoint served by the bundled helper
   /// (`amgi-mcp --http`, supervised by the app). URL-only agent apps
   /// use this instead of the command path.
    var localHTTPEndpoint: (url: String, token: String)? {
        let fileURL = CollectionLayout.rootDirectory()
            .appendingPathComponent("mcp.http.json")
        guard let data = FileManager.default.contents(atPath: fileURL.path),
              let ep = try? JSONDecoder().decode(
                HTTPEndpoint.self, from: data) else { return nil }
        return ("http://127.0.0.1:\(ep.port)/mcp", ep.token)
    }

    struct HTTPEndpoint: Codable {
        var port: Int
        var token: String
    }

    /// JSON body for clients whose UI takes a URL + headers object.
    func localHTTPJSON() -> String? {
        guard let endpoint = localHTTPEndpoint else { return nil }
        return """
                "amgi": {
                  "url": "\(endpoint.url)",
                  "headers": {
                    "Authorization": "Bearer \(endpoint.token)"
                  }
                }
                """
    }

    // MARK: - Registration snippets

    enum MCPClient: String, CaseIterable, Identifiable {
        case claudeDesktop = "Claude Desktop"
        case claudeCode = "Claude Code"
        case cursor = "Cursor"
        case codex = "Codex CLI"
        case generic = "Any other app"

        var id: String { rawValue }

        var iconName: String {
            switch self {
            case .claudeDesktop: return "message.fill"
            case .claudeCode: return "terminal"
            case .cursor: return "cursorarrow.click.2"
            case .codex: return "chevron.left.forwardslash.chevron.right"
            case .generic: return "server.rack"
            }
        }

        /// Plain-language setup steps shown under each disclosure.
        var steps: [String] {
            switch self {
            case .claudeDesktop:
                return [
                    "Open Claude Desktop, then choose Settings (⌘,) → Developer → Edit Config. A folder with claude_desktop_config.json opens.",
                    "Open that file with TextEdit.",
                    "Replace the file's contents with the text below (or add the \"mcpServers\" part inside the existing braces).",
                    "Save the file, quit Claude completely (⌘Q), and reopen it. Amgi appears under Connected Servers.",
                ]
            case .claudeCode:
                return [
                    "Open the Terminal app (from Applications → Utilities).",
                    "Paste the command below and press Return.",
                    "Restart Claude Code if it was open. Done — ask it about your decks.",
                ]
            case .cursor:
                return [
                    "In Cursor, open Cursor Settings → MCP & Integrations (some versions call it Tools & MCP).",
                    "Choose “Add Custom MCP server”. The file mcp.json opens.",
                    "If the file is empty, replace its contents with the text below. If it already has content, add the \"amgi\" entry inside mcpServers.",
                    "Save, then restart Cursor once.",
                ]
            case .codex:
                return [
                    "Open the Terminal app.",
                    "Paste the command below and press Return.",
                    "Start a new Codex session — Amgi's tools are available immediately.",
                ]
            case .generic:
                return [
                    "In the client's MCP settings, choose STDIO (standard input/output) as the connection type — not SSE or HTTP.",
                    "Quick trial: set Command to uvx (use /opt/homebrew/bin/uvx if the client needs an absolute path) and Parameters to amgi-mcp — no install needed. For multi-client or daily use this can hit the uv cache lock (10 s timeout) — see below.",
                    "Daily / multi-client (recommended): run once in Terminal: uv tool install amgi-mcp — then set Command to amgi-mcp (or the direct path below) with no Arguments. This is persistent, fastest, and avoids the lock.",
                    "Bundled helper (also persistent): paste the Command path below with no Arguments — works without uv at all.",
                    "If your client only offers a JSON option instead of fields, copy the matching JSON block below.",
                ]
            }
        }
    }

    struct ConnectionSnippet: Identifiable {
        let label: String
        let text: String
        var id: String { label }
    }

    /// Everything the user pastes for this client, each with its own
    /// Copy button. JSON clients get a complete ready-to-save file
    /// body; CLI clients get the whole command; generic form-based UIs
    /// get the command path plus a universal JSON body.
    func connectionSnippets(for client: MCPClient, helperPath: String) -> [ConnectionSnippet] {
        let jsonBody = """
                {
                  "mcpServers": {
                    "amgi": {
                      "command": "\(helperPath)"
                    }
                  }
                }
                """
        switch client {
        case .claudeDesktop:
            return [.init(label: "claude_desktop_config.json", text: jsonBody)]
        case .cursor:
            return [.init(label: ".cursor/mcp.json", text: jsonBody)]
        case .claudeCode:
            return [.init(label: "Terminal command", text: "claude mcp add amgi -- \(helperPath)")]
        case .codex:
            return [.init(label: "Terminal command", text: "codex mcp add amgi -- \(helperPath)")]
        case .generic:
            let uvxJson = """
                {
                  "mcpServers": {
                    "amgi": {
                      "command": "uvx",
                      "args": ["amgi-mcp"]
                    }
                  }
                }
                """
            let toolJson = """
                {
                  "mcpServers": {
                    "amgi": {
                      "command": "amgi-mcp"
                    }
                  }
                }
                """
            return [
                .init(label: "Command (bundled helper)", text: helperPath),
                .init(label: "Via uvx — trial, no install (Command: uvx, Parameters: amgi-mcp)", text: uvxJson),
                .init(label: "Via uv tool install — daily / multi-client (run: uv tool install amgi-mcp, then Command: amgi-mcp)", text: toolJson),
                .init(label: "JSON — bundled helper", text: jsonBody),
            ]
        }
    }

    /// Universal JSON body shared by several clients.
    func jsonConfiguration(helperPath: String) -> String {
        // Generic now exposes 4 snippets; the bundled-helper JSON is the canonical one.
        connectionSnippets(for: .generic, helperPath: helperPath)
            .first { $0.label.contains("bundled helper") }!.text
    }
}

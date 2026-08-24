import Foundation
import AnkiBackend
import AnkiKit
import AnkiProtoBridge
import MCP
import Logging

/// amgi-mcp — Model Context Protocol server over Amgi's Rust engine.
///
/// Spawned by AI clients (Claude Desktop, Claude Code, Cursor, Codex) as
/// a plain subprocess speaking stdio JSON-RPC. Never touches the GUI app:
/// it opens its own `AnkiBackend` against the same `collection.anki2`,
/// which is why tools keep working while the app is quit or force-quit.
///
/// Lifecycle contract:
///   - stdout carries ONLY protocol frames (all diagnostics → stderr).
///   - Mutating tools gate on tier + optional app-running policy, then
///     post a Darwin notification so a running app refreshes instantly;
///     cross-device propagation rides the app's normal sync cycle.
@main
struct AmgiMCPMain {
    static let version = "1.0.0"

    static func main() async {
        LoggingSystem.bootstrap { label in
            StreamLogHandler.standardError(label: label)
        }
        let log = Logger(label: "amgi-mcp")

        do {
            let options = try parseArguments()
            // Converge any pre-group-root data into the canonical Mac
            // root BEFORE resolving paths/mcp.json (no-op elsewhere or
            // when AMGI_COLLECTION_ROOT overrides).
            CollectionLayout.migrateIntoCanonicalRoot(environment: options.environment)
            let settings = MCPSettings.load(from: options.configPath)
            guard settings.enabled else {
                log.info("MCP disabled in \(options.configPath); exiting")
                return
            }

            let paths = CollectionPaths.resolve(
                preferredProfile: options.profile ?? settings.profileID,
                environment: options.environment
            )

            // The collection opens lazily on first tool call — rslib's
            // exclusive lock means Amgi.app may hold it right now, and
            // the server must stay useful the moment that frees up.
            let engine = EngineHolder(paths: paths)
            let context = EngineContext(engine: engine, settings: settings, paths: paths)
            let registry = ToolCatalog.tools(for: settings.tier)

            if options.environment["AMGI_MCP_HTTP"] == "1" {
                let port = Int(options.environment["AMGI_MCP_HTTP_PORT"] ?? "")
                    ?? LocalHTTPServer.defaultPort
                try await LocalHTTPServer.run(port: port, context: context, registry: registry)
                return
            }

            let server = Server(
                name: "amgi",
                version: version,
                capabilities: .init(tools: .init(listChanged: false))
            )

            await server.withMethodHandler(ListTools.self) { _ in
                ListTools.Result(tools: ToolCatalog.definitions(for: settings.tier))
            }

            await server.withMethodHandler(CallTool.self) { params in
                await dispatch(toolNamed: params.name, arguments: params.arguments, context: context, registry: registry)
            }

            try await server.start(transport: StdioTransport())
            log.info(
                "serving profile '\(paths.profileID)' tier=\(settings.tier.rawValue) tools=\(registry.count) (collection opens lazily)"
            )
            try await runUntilTerminated()
        } catch {
            FileHandle.standardError.write(Data("amgi-mcp: fatal: \(error)\n".utf8))
            exit(1)
        }
    }

    // MARK: - Dispatch

    static func dispatch(
        toolNamed name: String?,
        arguments: [String: MCP.Value]?,
        context: EngineContext,
        registry: [AmgiTool]
    ) async -> CallTool.Result {
        await ToolDispatcher.dispatch(toolNamed: name, arguments: arguments,
                                      context: context, registry: registry)
    }

    static func textResult(_ text: String) -> CallTool.Result { ToolDispatcher.textResult(text) }
    static func errorResult(_ text: String) -> CallTool.Result { ToolDispatcher.errorResult(text) }



    // MARK: - Arguments

    struct Options {
        var configPath: String
        var profile: String?
        var environment: [String: String]
    }

    static func parseArguments() throws -> Options {
        var environment = ProcessInfo.processInfo.environment
        let arguments = CommandLine.arguments
        var rootOverride: String?
        var profile: String?

        var index = 1
        while index < arguments.count {
            switch arguments[index] {
            case "--profile":
                index += 1
                guard index < arguments.count else { throw UsageError("--profile needs a value") }
                profile = arguments[index]
            case "--root":
                index += 1
                guard index < arguments.count else { throw UsageError("--root needs a value") }
                rootOverride = arguments[index]
            case "--config":
                index += 1
                guard index < arguments.count else { throw UsageError("--config needs a value") }
                environment["AMGI_MCP_CONFIG"] = arguments[index]
            case "--http":
                environment["AMGI_MCP_HTTP"] = "1"
            case "--port":
                index += 1
                guard index < arguments.count, Int(arguments[index]) != nil else {
                    throw UsageError("--port needs a number")
                }
                environment["AMGI_MCP_HTTP_PORT"] = arguments[index]
            case "--help", "-h":
                printUsage()
                exit(0)
            case "--version":
                // stdout is protocol-clean here: no server was started.
                print("amgi-mcp \(version)")
                exit(0)
            default:
                throw UsageError("unrecognized argument \(arguments[index])")
            }
            index += 1
        }

        if let rootOverride {
            // Reroute the whole layout chain (profiles, media, backups)
            // through the CollectionLayout override seam.
            environment["AMGI_COLLECTION_ROOT"] = rootOverride
        }

        // Config resolution order: --config/env > default next to profiles.
        let configPath =
            environment["AMGI_MCP_CONFIG"]
            ?? CollectionLayout.rootDirectory(environment: environment)
                .appendingPathComponent("mcp.json").path

        return Options(configPath: configPath, profile: profile, environment: environment)
    }

    struct UsageError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    static func printUsage() {
        FileHandle.standardError.write(
            Data(
                """
                amgi-mcp \(version) — Amgi MCP server (macOS)
                usage: amgi-mcp [--profile <id>] [--root <dir>] [--config <path>] [--http [--port <n>]]
                  --profile  Profile id to expose (default: app's active profile)
                  --root     Override collection root (AMGI_COLLECTION_ROOT)
                  --config   Settings JSON path (default: <root>/mcp.json)
                  --http     Also serve Streamable HTTP on 127.0.0.1 (for URL-based clients)
                  --port     Port for --http (default \(LocalHTTPServer.defaultPort))

                """.utf8
            )
        )
    }

    // MARK: - Lifetime

    /// Parks until the owning client terminates the process (stdio close
    /// or SIGTERM/SIGINT under their default dispositions — both paths
    /// kill us outright, which is safe: every engine write is a committed
    /// SQLite transaction, so crash-style shutdown loses nothing).
    static func runUntilTerminated() async throws {
        while true {
            try await Task.sleep(for: .seconds(3600))
        }
    }
}

import Foundation
import AnkiBackend
import AnkiKit
import MCP

/// Shared tool-call pipeline for every transport (stdio + local HTTP):
/// tier is enforced at registration time, write gates per call, engine
/// access resolves bridged-or-direct per call.
enum ToolDispatcher {
    static func dispatch(
        toolNamed name: String?,
        arguments: [String: MCP.Value]?,
        context: EngineContext,
        registry: [AmgiTool]
    ) async -> CallTool.Result {
        guard let tool = registry.first(where: { $0.name == name }) else {
            return errorResult("unknown or disabled tool '\(name ?? "")'")
        }
        let args = ToolArgs(arguments)

        // The app owns policy. Re-read its tiny JSON file for every call so
        // disabling MCP, lowering the tier, or changing write/snapshot gates
        // takes effect even in MCP clients that keep this process for days.
        let liveSettings: MCPSettings
        do {
            liveSettings = try MCPSettings.loadStrict(from: context.configPath)
        } catch {
            return errorResult(
                "MCP settings are malformed; refusing the call until Amgi rewrites them. (\(error.localizedDescription))"
            )
        }
        guard liveSettings.enabled else {
            return errorResult("The agent server is switched off in Amgi settings.")
        }
        guard tool.minimumTier <= liveSettings.tier else {
            return errorResult(
                "tool '\(tool.name)' is disabled by the current \(liveSettings.tier.rawValue) tier"
            )
        }
        // Write gates are enforced per-call (not just at registration) so
        // policy flips mid-session still apply without a client restart.
        if tool.mutates {
            if liveSettings.blockWritesWhileAppRunning && AppRunningCheck.isAmgiRunning {
                return errorResult(
                    "writes are blocked while Amgi.app is running (blockWritesWhileAppRunning=true). Quit the app or change the setting."
                )
            }
        }

        // A direct-mode collection is a request-scoped lease. The final
        // concurrent request closes it, so a long-lived but idle MCP client
        // can never block Amgi.app from launching.
        context.engine.beginToolCall()
        defer { context.engine.endToolCall() }

        do {
            // Resolve once and pin the whole tool call to that route. A tool
            // may issue several engine RPCs; mixing direct and bridged calls
            // inside one logical operation can produce inconsistent reads or
            // split a mutation across two owners during app startup.
            let caller = try context.engine.caller()
            let callContext = EngineContext(
                engine: context.engine,
                settings: liveSettings,
                configPath: context.configPath,
                paths: context.paths,
                caller: caller
            )
            if tool.destructive && liveSettings.snapshotsBeforeDestructive {
                do {
                    let snapshot = try caller.snapshot(paths: context.paths)
                    FileHandle.standardError.write(Data("snapshot: \(snapshot.path)\n".utf8))
                } catch {
                    return errorResult(
                        "pre-destructive snapshot failed — refusing to proceed: \(error.localizedDescription)"
                    )
                }
            }
            let output = try await tool.run(callContext, args)
            if tool.mutates && !caller.isBridged {
                ChangeNotifier.postCollectionChanged()
            }
            return textResult(output)
        } catch let error as BackendError {
            return errorResult("engine error: \(error.localizedDescription)")
        } catch {
            return errorResult(error.localizedDescription)
        }
    }

    static func textResult(_ text: String) -> CallTool.Result {
        CallTool.Result(
            content: [.text(text: text, annotations: nil, _meta: nil)],
            isError: false
        )
    }

    static func errorResult(_ text: String) -> CallTool.Result {
        CallTool.Result(
            content: [.text(text: text, annotations: nil, _meta: nil)],
            isError: true
        )
    }
}

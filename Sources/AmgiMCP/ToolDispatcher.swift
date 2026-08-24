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

        // Write gates are enforced per-call (not just at registration) so
        // policy flips mid-session still apply without a client restart.
        if tool.mutates {
            if tool.destructive && context.settings.snapshotsBeforeDestructive {
                do {
                    let snapshot = try Snapshotter.snapshot(
                        collectionPath: context.paths.collectionPath,
                        profileDirectory: context.paths.directory
                    )
                    FileHandle.standardError.write(Data("snapshot: \(snapshot.path)\n".utf8))
                } catch {
                    return errorResult("pre-destructive snapshot failed — refusing to proceed: \(error.localizedDescription)")
                }
            }
            if context.settings.blockWritesWhileAppRunning && AppRunningCheck.isAmgiRunning {
                return errorResult(
                    "writes are blocked while Amgi.app is running (blockWritesWhileAppRunning=true). Quit the app or change the setting."
                )
            }
        }

        do {
            let output = try await tool.run(context, args)
            if tool.mutates {
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

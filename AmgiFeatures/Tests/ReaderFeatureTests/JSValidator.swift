import Foundation

/// Syntax-checks a JavaScript snippet.
///
/// The reader's CSP is assembled by string interpolation, so the failure mode
/// that matters is "is this still valid JS". A string assertion cannot catch
/// an unbalanced quote.
///
/// Uses `node --check` when a JavaScript runtime is on `PATH`, and otherwise
/// falls back to `Tools/JSsyntaxCheck.swift`, which parses the source with
/// JavaScriptCore — present on every macOS the test suite runs on. If neither
/// is available the check reports that it was skipped rather than silently
/// passing, so a green run always means the script was actually parsed.
enum JSValidator {
    enum Outcome: Equatable {
        case valid
        case invalid(String)
        case skipped(reason: String)
    }

    static func check(_ source: String) -> Outcome {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("amgi-jscheck-\(UUID().uuidString).js")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard (try? source.write(to: temporary, atomically: true, encoding: .utf8)) != nil else {
            return .invalid("could not write the temporary script")
        }

        if let node = locateNode() {
            let result = run(
                executable: node,
                arguments: ["--check", temporary.path]
            )
            return result.status == 0
                ? .valid
                : .invalid(result.output)
        }

        // JavaScriptCore fallback. Wrapping in a function body parses without
        // executing, so a missing `window` is not reported as a failure.
        let tool = repositoryRoot()
            .appendingPathComponent("Tools/JSsyntaxCheck.swift")
        guard FileManager.default.fileExists(atPath: tool.path) else {
            return .skipped(reason: "neither node nor Tools/JSsyntaxCheck.swift is available")
        }
        let result = run(
            executable: swiftExecutable(),
            arguments: [tool.path, temporary.path]
        )
        if result.status == 0 { return .valid }
        if result.output.contains("SYNTAX ERROR") { return .invalid(result.output) }
        // The checker itself failed (e.g. no swift toolchain) — not evidence
        // about the script under test.
        return .skipped(reason: result.output.isEmpty ? "checker failed" : result.output)
    }

    private struct RunResult {
        var status: Int32
        var output: String
    }

    private static func run(executable: String, arguments: [String]) -> RunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return RunResult(status: -1, output: "\(error)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return RunResult(
            status: process.terminationStatus,
            output: String(data: data, encoding: .utf8) ?? ""
        )
    }

    private static func swiftExecutable() -> String {
        let candidates = [
            "/usr/bin/swift",
            "/opt/homebrew/bin/swift",
            "/usr/local/bin/swift",
        ]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
            ?? "swift"
    }

    private static func repositoryRoot() -> URL {
        // …/AmgiFeatures/Tests/ReaderFeatureTests/JSValidator.swift
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ReaderFeatureTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // AmgiFeatures
            .deletingLastPathComponent()   // repository root
    }

    private static func locateNode() -> String? {
        let candidates = [
            "/usr/bin/node",
            "/usr/local/bin/node",
            "/opt/homebrew/bin/node",
        ]
        if let hit = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return hit
        }
        // Fall back to PATH for version managers (nvm, asdf, mise).
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", "node"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let path, !path.isEmpty,
              FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
    }
}

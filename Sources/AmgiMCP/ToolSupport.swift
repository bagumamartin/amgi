import Foundation
import AnkiBackend
import AnkiKit
import MCP

/// Everything a tool handler needs: the (lazily opened) engine, the
/// resolved paths, and the active settings snapshot (fixed for the
/// process lifetime — the app rewrites `mcp.json` and users restart
/// their MCP client to apply changes, matching how MCP clients cache
/// server configs).
struct EngineContext: Sendable {
    let engine: EngineHolder
    let settings: MCPSettings
    let paths: CollectionPaths

    /// Convenience for handlers: resolves bridged-or-direct engine access.
    func backend() throws -> EngineCaller {
        try engine.caller()
    }
}

/// Typed extraction over the SDK's JSON `Value` arguments, with
/// tool-shaped error messages (agents read these and self-correct).
struct ToolArgs: Sendable {
    let raw: [String: MCP.Value]

    init(_ raw: [String: MCP.Value]?) {
        self.raw = raw ?? [:]
    }

    func requireString(_ key: String) throws -> String {
        guard let value = raw[key] else { throw ToolError.missingArg(key) }
        switch value {
        case .string(let s): return s
        default: throw ToolError.badArg(key, "expected string")
        }
    }

    func optionalString(_ key: String) -> String? {
        switch raw[key] {
        case .string(let s): return s
        default: return nil
        }
    }

    func requireInt(_ key: String) throws -> Int {
        guard let value = raw[key] else { throw ToolError.missingArg(key) }
        switch value {
        case .int(let i): return i
        case .double(let d): return Int(d)
        case .string(let s) where Int(s) != nil: return Int(s)!
        default: throw ToolError.badArg(key, "expected integer")
        }
    }

    func optionalInt(_ key: String, default fallback: Int) -> Int {
        (try? requireInt(key)) ?? fallback
    }

    func requireBool(_ key: String) throws -> Bool {
        guard let value = raw[key] else { throw ToolError.missingArg(key) }
        switch value {
        case .bool(let b): return b
        default: throw ToolError.badArg(key, "expected boolean")
        }
    }

    func stringArray(_ key: String) throws -> [String] {
        switch raw[key] {
        case nil, .null: return []
        case .array(let items):
            return try items.map { item in
                guard case .string(let s) = item else {
                    throw ToolError.badArg(key, "expected array of strings")
                }
                return s
            }
        case .string(let s):
            // Tolerate a single bare string for convenience.
            return s.isEmpty ? [] : [s]
        default:
            throw ToolError.badArg(key, "expected array of strings")
        }
    }

    /// Field map (`{Front: "...", Back: "..."}`) as an ordered-free dict.
    func fieldMap(_ key: String) throws -> [String: String] {
        guard let value = raw[key] else { throw ToolError.missingArg(key) }
        guard case .object(let obj) = value else {
            throw ToolError.badArg(key, "expected object of field name → text")
        }
        var out: [String: String] = [:]
        for (name, item) in obj {
            guard case .string(let s) = item else {
                throw ToolError.badArg(key, "field '\(name)' must be a string")
            }
            out[name] = s
        }
        return out
    }

    /// Raw JSON text for pass-through config values (validated by caller).
    func rawJSONString(_ key: String) throws -> String {
        try requireString(key)
    }
}

enum ToolError: LocalizedError, Sendable {
    case missingArg(String)
    case badArg(String, String)
    case notFound(String)
    case blocked(String)

    var errorDescription: String? {
        switch self {
        case .missingArg(let key): return "missing required argument: \(key)"
        case .badArg(let key, let why): return "invalid argument '\(key)': \(why)"
        case .notFound(let what): return "not found: \(what)"
        case .blocked(let why): return "blocked: \(why)"
        }
    }
}

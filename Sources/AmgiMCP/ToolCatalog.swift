import AnkiKit
import MCP

/// One MCP tool: its client-visible definition plus the tier/mutation
/// metadata the dispatcher gates on, and the handler itself. Handlers
/// return plain text (Markdown-ish) — agents render it natively.
struct AmgiTool: Sendable {
    let name: String
    let description: String
    let inputSchema: MCP.Value
    /// Minimum capability tier required to register this tool.
    let minimumTier: ToolTier
    /// Mutating calls pass through the write gate and post the
    /// collection-changed Darwin notification on success.
    let mutates: Bool
    /// Destructive calls additionally trigger a pre-call snapshot when
    /// `snapshotsBeforeDestructive` is enabled.
    let destructive: Bool
    let run: @Sendable (EngineContext, ToolArgs) async throws -> String

    init(
        name: String,
        description: String,
        inputSchema: MCP.Value,
        minimumTier: ToolTier,
        mutates: Bool = false,
        destructive: Bool = false,
        run: @escaping @Sendable (EngineContext, ToolArgs) async throws -> String
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.minimumTier = minimumTier
        self.mutates = mutates
        self.destructive = destructive
        self.run = run
    }
}

/// JSON-Schema fragments for tool inputs, in the SDK's `Value` form.
enum Schema {
    static func object(_ properties: [String: MCP.Value], required: [String] = []) -> MCP.Value {
        var body: [String: MCP.Value] = [
            "type": .string("object"),
            "properties": .object(properties),
        ]
        if !required.isEmpty {
            body["required"] = .array(required.map { .string($0) })
        }
        return .object(body)
    }

    static func string(_ description: String) -> MCP.Value {
        .object(["type": .string("string"), "description": .string(description)])
    }

    static func int(_ description: String) -> MCP.Value {
        .object(["type": .string("integer"), "description": .string(description)])
    }

    static func bool(_ description: String) -> MCP.Value {
        .object(["type": .string("boolean"), "description": .string(description)])
    }

    static func arrayOfStrings(_ description: String) -> MCP.Value {
        .object([
            "type": .string("array"),
            "description": .string(description),
            "items": .object(["type": .string("string")]),
        ])
    }

    static func objectOfStrings(_ description: String) -> MCP.Value {
        .object([
            "type": .string("object"),
            "description": .string(description),
            "additionalProperties": .object(["type": .string("string")]),
        ])
    }

    static func intArray(_ description: String) -> MCP.Value {
        .object([
            "type": .string("array"),
            "description": .string(description),
            "items": .object(["type": .string("integer")]),
        ])
    }
}

enum ToolCatalog {
    static var allTools: [AmgiTool] {
        DeckTools.tools + SearchTools.tools + NoteTools.tools
            + RenderStatsTools.tools + ConfigMediaTools.tools
    }

    /// Tools visible at a given tier, ordered by group for stable listing.
    static func tools(for tier: ToolTier) -> [AmgiTool] {
        allTools.filter { tier >= $0.minimumTier }
    }

    static func definitions(for tier: ToolTier) -> [MCP.Tool] {
        tools(for: tier).map {
            MCP.Tool(name: $0.name, description: $0.description, inputSchema: $0.inputSchema)
        }
    }
}

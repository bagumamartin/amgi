import Foundation
import FoundationModels
import ManifoldKit
import OSLog

/// Apple's native tool selector chooses an intent; it never executes an app
/// action. Intent handoff ends this stream and Manifold's existing dispatch
/// loop validates, approves, executes and persists the call exactly once.
/// ManifoldKit itself remains unmodified.
final class AssistantFoundationBackend: InferenceBackend, @unchecked Sendable {
    private let loader = FoundationBackend()
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var activeID: UUID?
    var isModelLoaded: Bool { loader.isModelLoaded }
    var isGenerating: Bool { lock.withLock { activeID != nil } }
    var manifest: ModelManifest? { loader.manifest }
    let capabilities = BackendCapabilities(
        supportedParameters: [.temperature], maxContextTokens: 4096,
        requiresPromptTemplate: false, supportsSystemPrompt: true,
        supportsToolCalling: true, cancellationStyle: .cooperative,
        memoryStrategy: .external, maxOutputTokens: 4096,
        supportsStreaming: true, maxAdvertisedToolCount: 3
    )
    func loadModel(from url: URL, plan: ModelLoadPlan) async throws { try await loader.loadModel(from: url, plan: plan) }
    func generate(prompt: String, systemPrompt: String?, config: GenerationConfig, hints: GenerationRuntimeHints) throws -> GenerationStream {
        guard isModelLoaded else { throw InferenceError.inferenceFailure("Apple's model is not loaded") }
        guard config.toolChoice == .auto || config.toolChoice == .none else {
            throw InferenceError.inferenceFailure("This Apple adapter supports automatic native tool selection only")
        }
        let id = UUID()
        try lock.withLock {
            guard activeID == nil else { throw InferenceError.alreadyGenerating }
            activeID = id
        }
        do {
            let box = NativeIntentBox(history: hints.history)
            let tools = try (config.toolChoice == .none ? [] : config.tools).map { try NativeIntentTool(definition: $0, box: box) }
            let turn = try Self.lower(history: hints.history, fallback: prompt)
            let instructions = [systemPrompt, turn.system].compactMap { $0 }.joined(separator: "\n\n")
            let seed = LanguageModelSession(tools: tools, instructions: instructions)
            let session = LanguageModelSession(tools: tools, transcript: Transcript(entries: Array(seed.transcript) + turn.entries))
            let (events, continuation) = AsyncThrowingStream.makeStream(of: GenerationEvent.self)
            let stream = GenerationStream(events)
            let work = Task { [self] in
                defer {
                    lock.withLock { if activeID == id { activeID = nil; task = nil } }
                }
                do {
                    var options = GenerationOptions()
                    options.temperature = Double(config.temperature)
                    options.maximumResponseTokens = config.maxOutputTokens
                    var count = 0
                    let (nativeCompletion, nativeResult) = AsyncThrowingStream.makeStream(of: Int.self)
                    let response = Task {
                        do {
                            var emitted = 0
                            for try await partial in session.streamResponse(to: turn.prompt, options: options) {
                                try Task.checkCancellation()
                                if !box.calls.isEmpty { break }
                                if partial.content.count > emitted {
                                    await MainActor.run { stream.setPhase(.streaming) }
                                    continuation.yield(.token(String(partial.content.dropFirst(emitted))))
                                    emitted = partial.content.count
                                }
                            }
                            nativeResult.yield(emitted); nativeResult.finish()
                        } catch { nativeResult.finish(throwing: error) }
                    }
                    // Throwing from a native Tool alone can trigger SDK error
                    // recovery before any partial response is yielded. Cancel
                    // that native pass immediately; the outer app turn remains
                    // alive and dispatches its selected intent through Manifold.
                    box.onIntent {
                        response.cancel()
                        // Do not wait for SDK cancellation acknowledgement to
                        // make the selected intent available for review.
                        nativeResult.yield(0); nativeResult.finish()
                    }
                    defer { response.cancel() }
                    do {
                        try await withTaskCancellationHandler {
                            for try await emitted in nativeCompletion { count = emitted; break }
                        } onCancel: {
                            response.cancel(); nativeResult.finish(throwing: CancellationError())
                        }
                    } catch {
                        if box.calls.isEmpty { throw error }
                    }
                    try Task.checkCancellation()
                    guard count > 0 || !box.calls.isEmpty else {
                        throw InferenceError.inferenceFailure("Apple's model returned an empty response. Check that the device is unlocked and Apple Intelligence is ready.")
                    }
                    for call in box.calls { continuation.yield(.toolCall(call)) }
                    await MainActor.run { stream.setPhase(.done) }
                    continuation.finish()
                } catch {
                    await MainActor.run { stream.setPhase(Task.isCancelled ? .done : .failed(error.localizedDescription)) }
                    continuation.finish(throwing: error)
                }
            }
            lock.withLock { if activeID == id { task = work } else { work.cancel() } }
            continuation.onTermination = { [weak self] _ in self?.cancel(id) }
            return stream
        } catch { cancel(id); throw error }
    }
    private func cancel(_ id: UUID) {
        let current = lock.withLock { () -> Task<Void, Never>? in
            guard activeID == id else { return nil }
            activeID = nil; defer { task = nil }; return task
        }
        current?.cancel()
    }
    func stopGeneration() { if let id = lock.withLock({ activeID }) { cancel(id) } }
    func unloadModel() { stopGeneration(); loader.unloadModel() }
    func resetConversation() { stopGeneration(); loader.resetConversation() }
    func secureWipe() { stopGeneration(); loader.secureWipe() }

    struct Turn { var prompt: String; var entries: [Transcript.Entry]; var system: String? }
    static func lower(history: [StructuredMessage], fallback: String) throws -> Turn {
        var source = history
        let prompt: String
        if source.last?.role == "user" {
            prompt = try text(source.removeLast().parts)
        } else if source.last?.role == "tool" {
            // Preserve real native tool-call/output entries. Recasting a result
            // as a fresh user question makes the selector repeat the lookup.
            prompt = "Continue the pending user request. The tools above already ran. Use their results; call another tool only when a further step is needed."
        } else if source.isEmpty { prompt = fallback }
        else { throw InferenceError.inferenceFailure("No pending user request or tool result") }
        var systems: [String] = [], entries: [Transcript.Entry] = []
        var names: [String: String] = [:]
        for message in source {
            let content = try text(message.parts)
            if message.role == "system" { systems.append(content); continue }
            if message.role == "user" {
                entries.append(.prompt(.init(segments: [.text(.init(content: content))])))
            } else if message.role == "assistant" {
                // Saved Manifold messages interleave text, calls and results
                // inside one assistant message. Preserve their exact order.
                for part in message.parts {
                    switch part {
                    case .text(let text):
                        if !text.isEmpty { entries.append(.response(.init(assetIDs: [], segments: [.text(.init(content: text))]))) }
                    case .toolCall(let call):
                        names[call.id] = call.toolName
                        entries.append(.toolCalls(.init([.init(id: call.id, toolName: call.toolName, arguments: try GeneratedContent(json: call.arguments))])))
                    case .toolResult(let result):
                        entries.append(try output(result, names: names))
                    case .thinking: break
                    default: throw InferenceError.inferenceFailure("This Apple adapter accepts text and retrieved context only")
                    }
                }
            } else if message.role == "tool" {
                for part in message.parts {
                    guard case .toolResult(let result) = part else { continue }
                    entries.append(try output(result, names: names))
                }
            } else { throw InferenceError.inferenceFailure("Unsupported conversation role") }
        }
        return Turn(prompt: prompt, entries: entries, system: systems.isEmpty ? nil : systems.joined(separator: "\n"))
    }
    private static func output(_ result: ToolResult, names: [String: String]) throws -> Transcript.Entry {
        guard let name = names[result.callId] else { throw InferenceError.inferenceFailure("Tool history was trimmed without its request. Start a new chat to continue safely.") }
        let quoted = "<untrusted_tool_result>" + result.content + "</untrusted_tool_result>"
        return .toolOutput(.init(id: result.callId, toolName: name, segments: [.text(.init(content: quoted))]))
    }
    private static func text(_ parts: [MessagePart]) throws -> String {
        try parts.compactMap { part -> String? in
            switch part {
            case .text(let text): return text
            case .thinking, .toolCall, .toolResult: return nil
            default: throw InferenceError.inferenceFailure("This Apple adapter accepts text and retrieved context only")
            }
        }.joined(separator: "\n")
    }

}

final class NativeIntentBox: @unchecked Sendable {
    private static let log = Logger(subsystem: "com.bagumamartin.ijuka", category: "AssistantNativeAdapter")
    private struct Signature: Hashable { let name: String; let arguments: JSONSchemaValue }
    private let lock = NSLock()
    private var stored: [ToolCall] = []
    private var intentHandler: (@Sendable () -> Void)?
    private let completed: [Signature: String]
    init(history: [StructuredMessage] = []) {
        var calls: [String: ToolCall] = [:], results: [Signature: String] = [:]
        // Only this pending turn may reuse a result. A new user question must
        // refetch, even when it asks the same question as an earlier turn.
        let start = history.lastIndex(where: { $0.role == "user" }).map { $0 + 1 } ?? 0
        for message in history.dropFirst(start) {
            for part in message.parts {
                if case .toolCall(let call) = part { calls[call.id] = call }
                if case .toolResult(let result) = part, let call = calls[result.callId],
                   let args = try? JSONDecoder().decode(JSONSchemaValue.self, from: Data(call.arguments.utf8)) {
                    results[Signature(name: call.toolName, arguments: args)] = result.content
                }
            }
        }
        completed = results
    }
    var calls: [ToolCall] { lock.withLock { stored } }
    func append(_ call: ToolCall) {
        let notify = lock.withLock { () -> (@Sendable () -> Void)? in
            guard stored.isEmpty else { return nil }
            Self.log.notice("Native tool intent selected; handing off to shared dispatcher")
            stored.append(call); return intentHandler
        }
        notify?()
    }
    func onIntent(_ handler: @escaping @Sendable () -> Void) {
        let ready = lock.withLock { intentHandler = handler; return !stored.isEmpty }
        if ready { handler() }
    }
    func completedOutput(name: String, arguments: String) -> String? {
        guard let args = try? JSONDecoder().decode(JSONSchemaValue.self, from: Data(arguments.utf8)) else { return nil }
        let result = completed[Signature(name: name, arguments: args)]
        if result != nil { Self.log.notice("Replayed completed native tool output within pending turn") }
        return result
    }
}
struct NativeIntentTool: FoundationModels.Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String
    let name: String
    let description: String
    let parameters: GenerationSchema
    let box: NativeIntentBox
    init(definition: ToolDefinition, box: NativeIntentBox) throws {
        name = definition.name; description = definition.description; self.box = box
        parameters = try GenerationSchema(root: Self.schema(definition.parameters, name: definition.name), dependencies: [])
    }
    func call(arguments: GeneratedContent) async throws -> String {
        // Native Foundation Models may reselect a completed intent. Replaying
        // its already-committed result does not emit or execute another call.
        if let result = box.completedOutput(name: name, arguments: arguments.jsonString) { return result }
        box.append(ToolCall(id: UUID().uuidString, toolName: name, arguments: arguments.jsonString))
        throw CancellationError()
    }
    private static func schema(_ value: JSONSchemaValue, name: String) throws -> DynamicGenerationSchema {
        guard case .object(let object) = value, case .string(let type)? = object["type"] else { throw SchemaError.invalid }
        if case .array(let values)? = object["enum"] {
            let names = values.compactMap { if case .string(let string) = $0 { return string }; return nil }
            guard names.count == values.count else { throw SchemaError.invalid }
            return DynamicGenerationSchema(name: name, anyOf: names)
        }
        switch type {
        case "object":
            guard case .object(let properties)? = object["properties"] else { throw SchemaError.invalid }
            let required: Set<String>
            if case .array(let values)? = object["required"] { required = Set(values.compactMap { if case .string(let value) = $0 { return value }; return nil }) }
            else { required = [] }
            return try DynamicGenerationSchema(name: name, properties: properties.sorted { $0.key < $1.key }.map { key, value in
                let description: String?
                if case .object(let object) = value, case .string(let text)? = object["description"] { description = text }
                else { description = nil }
                return .init(name: key, description: description, schema: try schema(value, name: name + "_" + key), isOptional: !required.contains(key))
            })
        case "array":
            guard let item = object["items"] else { throw SchemaError.invalid }
            return try DynamicGenerationSchema(arrayOf: schema(item, name: name + "_item"))
        case "string": return DynamicGenerationSchema(type: String.self)
        case "integer": return DynamicGenerationSchema(type: Int.self)
        case "number": return DynamicGenerationSchema(type: Double.self)
        case "boolean": return DynamicGenerationSchema(type: Bool.self)
        default: throw SchemaError.invalid
        }
    }
    private enum SchemaError: Error { case invalid }
}

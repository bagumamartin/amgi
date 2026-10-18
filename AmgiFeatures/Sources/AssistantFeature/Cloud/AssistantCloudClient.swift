import AmgiAppCore
import Foundation

enum AssistantCloudError: LocalizedError {
    case notConnected(AssistantProvider)
    case http(Int, String?)
    case provider(code: String?, message: String)
    case interrupted

    var errorDescription: String? {
        switch self {
        case .notConnected(let provider):
            return L10n.text("\(provider.title) isn't connected. Connect it in Settings › AI Assistant.")
        case .http(let status, let message):
            switch status {
            case 401: return L10n.text("The provider rejected the credentials. Reconnect it in Settings.")
            case 429: return message ?? L10n.text("The provider's rate limit was reached. Try again shortly.")
            default: return message ?? L10n.text("The provider returned an error (HTTP \(status)).")
            }
        case .provider(let code, let message):
            switch code {
            case "subscription_sharing_usage_limit_exceeded":
                return L10n.text("You've reached your ChatGPT plan's limit for now. Try again later or switch models.")
            case "subscription_sharing_usage_unavailable":
                return L10n.text("Your ChatGPT plan can't be used here right now. Try another model or an API key.")
            default: return message
            }
        case .interrupted:
            return L10n.text("The connection dropped before the reply finished.")
        }
    }
}

enum CloudErrorText {
    static func message(in data: Data) -> String? {
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return text?.isEmpty == false ? String(text!.prefix(300)) : nil
        }
        return json["error"]?["message"]?.string ?? json["error"]?.string ?? json["message"]?.string
    }
}

/// A function the model may call, described as JSON Schema.
struct CloudTool: Sendable {
    let name: String
    let description: String
    let parameters: JSONValue
}

struct CloudToolCall: Sendable, Hashable {
    let id: String
    let name: String
    let arguments: String
}

/// A finished exchange from an earlier turn, replayed as plain text plus
/// the files it carried.
struct CloudHistoryTurn: Sendable {
    let prompt: String
    let attachments: [AssistantAttachment]
    let reply: String
    /// The `<context>` blocks attached to this message, replayed with it.
    var context = ""
}

/// One request/stream cycle. `items` are the provider's own output, kept to
/// replay on the next round (reasoning, tool calls).
struct CloudRound: Sendable {
    var text = ""
    var calls: [CloudToolCall] = []
    var items: [JSONValue] = []
}

enum CloudStreamEvent: Sendable {
    case text(String)
    case finished(CloudRound)
}

/// A conversation with one cloud model, in that provider's wire format.
/// Built per turn from the chat's history; tool rounds append to it.
struct CloudConversation: Sendable {
    let model: AssistantModel
    let instructions: String
    let tools: [CloudTool]
    private(set) var input: [JSONValue] = []
    /// OpenAI: whether to ask for replayable reasoning. Dropped after a
    /// model rejects it.
    var includeReasoning = true

    init(
        model: AssistantModel, instructions: String, tools: [CloudTool], history: [CloudHistoryTurn],
        prompt: String, attachments: [AssistantAttachment], context: String = ""
    ) {
        self.model = model
        self.instructions = instructions
        self.tools = tools
        for turn in history {
            input.append(userMessage(turn.prompt, turn.attachments, context: turn.context))
            input.append(assistantText(turn.reply))
        }
        input.append(userMessage(prompt, attachments, context: context))
    }

    private var isAnthropic: Bool { model.provider == .anthropic }

    // MARK: Messages

    /// Files first, then the attached context as its own text part, then
    /// what the user typed — so the context reads as material the message
    /// is about, not as part of what they said.
    private func userMessage(_ text: String, _ attachments: [AssistantAttachment], context: String = "") -> JSONValue {
        var parts: [JSONValue] = []
        for attachment in attachments {
            switch (isAnthropic, attachment.kind) {
            case (true, .image):
                parts.append(["type": "image", "source": ["type": "base64", "media_type": .string(attachment.mimeType), "data": .string(attachment.data.base64EncodedString())]])
            case (true, .pdf):
                parts.append(["type": "document", "title": .string(attachment.name), "source": ["type": "base64", "media_type": "application/pdf", "data": .string(attachment.data.base64EncodedString())]])
            case (false, .image):
                parts.append(["type": "input_image", "image_url": .string(attachment.dataURL)])
            case (false, .pdf):
                parts.append(["type": "input_file", "filename": .string(attachment.name), "file_data": .string(attachment.dataURL)])
            }
        }
        func textPart(_ value: String) -> JSONValue {
            isAnthropic ? ["type": "text", "text": .string(value)] : ["type": "input_text", "text": .string(value)]
        }
        if !context.isEmpty { parts.append(textPart(context)) }
        parts.append(textPart(text))
        return ["role": "user", "content": .array(parts)]
    }

    private func assistantText(_ text: String) -> JSONValue {
        isAnthropic
            ? ["role": "assistant", "content": [["type": "text", "text": .string(text.isEmpty ? "…" : text)]]]
            : ["role": "assistant", "content": .string(text)]
    }

    /// Records the model's output and what the tools answered.
    mutating func append(_ round: CloudRound, results: [(CloudToolCall, String)]) {
        if isAnthropic {
            input.append(["role": "assistant", "content": .array(round.items)])
            input.append(["role": "user", "content": .array(results.map { call, output in
                ["type": "tool_result", "tool_use_id": .string(call.id), "content": .string(output)]
            })])
        } else {
            input.append(contentsOf: round.items)
            for (call, output) in results {
                input.append(["type": "function_call_output", "call_id": .string(call.id), "output": .string(output)])
            }
        }
    }

    /// Without the reasoning items a model refused on replay.
    mutating func dropReasoning() {
        includeReasoning = false
        input.removeAll { $0["type"]?.string == "reasoning" }
    }

    // MARK: Request

    func request(_ credential: AssistantProviderStore.Credential) throws -> URLRequest {
        var request: URLRequest
        var body: [String: JSONValue]
        if isAnthropic {
            request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            if case .apiKey(let key) = credential { request.setValue(key, forHTTPHeaderField: "x-api-key") }
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body = [
                "model": .string(model.slug),
                "system": .string(instructions),
                "messages": .array(input),
                "max_tokens": 8192,
                "stream": true,
            ]
            if !tools.isEmpty {
                body["tools"] = .array(tools.map { ["name": .string($0.name), "description": .string($0.description), "input_schema": $0.parameters] })
            }
        } else {
            request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
            switch credential {
            case .apiKey(let token), .bearer(let token): request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            body = [
                "model": .string(model.slug),
                "instructions": .string(instructions),
                "input": .array(input),
                "stream": true,
                // Required by Sign in with ChatGPT, and keeps chats off
                // OpenAI's servers for API keys too.
                "store": false,
            ]
            if includeReasoning { body["include"] = ["reasoning.encrypted_content"] }
            if !tools.isEmpty {
                body["tools"] = .array(tools.map {
                    ["type": "function", "name": .string($0.name), "description": .string($0.description), "parameters": $0.parameters, "strict": false]
                })
                body["parallel_tool_calls"] = false
            }
        }
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONValue.object(body).data()
        return request
    }
}

/// Streams one round off the main actor and hands events back in order.
enum AssistantCloudClient {
    static func stream(_ request: URLRequest, provider: AssistantProvider) -> AsyncThrowingStream<CloudStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard status == 200 else {
                        var data = Data()
                        for try await byte in bytes { data.append(byte); if data.count > 64_000 { break } }
                        throw AssistantCloudError.http(status, CloudErrorText.message(in: data))
                    }
                    var parser = provider == .anthropic ? StreamParser.anthropic() : StreamParser.openAI()
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        guard payload != "[DONE]", let event = JSONValue.parse(payload) else { continue }
                        if let text = try parser.consume(event) { continuation.yield(.text(text)) }
                        if parser.isFinished { break }
                    }
                    guard parser.isFinished else { throw AssistantCloudError.interrupted }
                    continuation.yield(.finished(parser.round))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Reads one provider's SSE events into text deltas and a ``CloudRound``.
private struct StreamParser {
    enum Format { case openAI, anthropic }
    let format: Format
    var round = CloudRound()
    var isFinished = false
    // Anthropic content blocks by index, and tool input JSON as it arrives.
    private var blocks: [Int: JSONValue] = [:]
    private var partialInput: [Int: String] = [:]

    static func openAI() -> StreamParser { StreamParser(format: .openAI) }
    static func anthropic() -> StreamParser { StreamParser(format: .anthropic) }

    /// Returns visible text to append, if the event carried any.
    mutating func consume(_ event: JSONValue) throws -> String? {
        switch format {
        case .openAI: try consumeOpenAI(event)
        case .anthropic: try consumeAnthropic(event)
        }
    }

    private mutating func consumeOpenAI(_ event: JSONValue) throws -> String? {
        switch event["type"]?.string {
        case "response.output_text.delta":
            let delta = event["delta"]?.string ?? ""
            round.text += delta
            return delta
        case "response.output_item.done":
            guard let item = event["item"] else { return nil }
            switch item["type"]?.string {
            case "function_call":
                let call = CloudToolCall(id: item["call_id"]?.string ?? "", name: item["name"]?.string ?? "", arguments: item["arguments"]?.string ?? "{}")
                round.calls.append(call)
                // Items aren't stored server-side; send them back whole,
                // without the ids that would point at a stored copy.
                round.items.append(item.removing("id").removing("status"))
            case "reasoning":
                if item["encrypted_content"]?.string != nil { round.items.append(item) }
            case "message":
                round.items.append(item.removing("id").removing("status"))
            default: break
            }
            return nil
        case "response.completed", "response.incomplete":
            isFinished = true
            return nil
        case "response.failed":
            let error = event["response"]?["error"]
            throw AssistantCloudError.provider(code: error?["code"]?.string, message: error?["message"]?.string ?? L10n.text("The model couldn't finish this reply."))
        case "error":
            throw AssistantCloudError.provider(code: event["code"]?.string ?? event["error"]?["code"]?.string,
                                               message: event["message"]?.string ?? event["error"]?["message"]?.string ?? L10n.text("The model returned an error."))
        default:
            return nil
        }
    }

    private mutating func consumeAnthropic(_ event: JSONValue) throws -> String? {
        switch event["type"]?.string {
        case "content_block_start":
            guard let index = event["index"].flatMap(Self.int), let block = event["content_block"] else { return nil }
            blocks[index] = block
            return nil
        case "content_block_delta":
            guard let index = event["index"].flatMap(Self.int), let delta = event["delta"] else { return nil }
            switch delta["type"]?.string {
            case "text_delta":
                let text = delta["text"]?.string ?? ""
                round.text += text
                blocks[index] = .object(["type": "text", "text": .string((blocks[index]?["text"]?.string ?? "") + text)])
                return text
            case "input_json_delta":
                partialInput[index, default: ""] += delta["partial_json"]?.string ?? ""
            default: break
            }
            return nil
        case "message_stop":
            for index in blocks.keys.sorted() {
                guard var block = blocks[index]?.object else { continue }
                if block["type"]?.string == "tool_use" {
                    let arguments = partialInput[index].flatMap { $0.isEmpty ? nil : $0 } ?? "{}"
                    block["input"] = JSONValue.parse(arguments) ?? [:]
                    round.calls.append(CloudToolCall(id: block["id"]?.string ?? "", name: block["name"]?.string ?? "", arguments: arguments))
                } else if block["type"]?.string == "text", (block["text"]?.string ?? "").isEmpty {
                    continue
                } else if block["type"]?.string != "text" {
                    continue
                }
                round.items.append(.object(block))
            }
            isFinished = true
            return nil
        case "error":
            throw AssistantCloudError.provider(code: event["error"]?["type"]?.string, message: event["error"]?["message"]?.string ?? L10n.text("The model returned an error."))
        default:
            return nil
        }
    }

    private static func int(_ value: JSONValue) -> Int? {
        if case .number(let number) = value { Int(number) } else { nil }
    }
}

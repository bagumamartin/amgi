import Foundation
import Testing
@testable import AssistantFeature

@Suite("Assistant contexts")
struct AssistantContextTests {
    @Test("legacy single-scope chats decode as one context")
    func legacyReaderScope() throws {
        let json = #"{"kind":"reader","title":"Dune","reference":"Source book:1","deckID":null,"noteID":null}"#
        let context = try JSONDecoder().decode(AssistantContext.self, from: Data(json.utf8))
        #expect(context.type == .book)
        #expect(context.subtitle.isEmpty)
    }

    @Test("the same item keeps one identity after it is resolved")
    func stableIdentity() {
        var card = AssistantContext.card(noteID: 42, deckID: 7)
        let id = card.id
        card.title = "What is mitosis?"
        card.reference = "Front: What is mitosis?"
        #expect(card.id == id)
        #expect(AssistantContext.collection.id == "collection")
        #expect(AssistantContext.deck(id: 3, name: "Bio::Cells").title == "Cells")
        #expect(AssistantContext.deck(id: 3, name: "Bio::Cells").subtitle == "Bio")
    }

    @Test("an empty selection makes no passage")
    func passage() {
        #expect(AssistantContext.passage("  \n ", bookID: "b", bookTitle: "Dune") == nil)
        let passage = AssistantContext.passage("Fear is the mind-killer.", bookID: "b", bookTitle: "Dune")
        #expect(passage?.type == .passage)
        #expect(passage?.reference == "Fear is the mind-killer.")
    }

    @Test("reader contexts hide the global entry")
    func readerDetection() {
        #expect([AssistantContext.page(bookID: "b", bookTitle: "T", page: 2, text: "")].isReader)
        #expect(![AssistantContext.collection].isReader)
    }

    @Test("instructions carry every attached context, bounded on device")
    func instructions() {
        let chapter = AssistantContext.chapter(bookID: "b", bookTitle: "Dune", chapterID: 1, title: "Arrakis", text: String(repeating: "spice ", count: 2_000))
        let onDevice = AssistantInstructions.make([chapter, .collection], cloud: false)
        #expect(onDevice.contains("title=\"Arrakis\""))
        #expect(onDevice.contains("kind=\"collection\""))
        #expect(onDevice.count < 4_000)
        let cloud = AssistantInstructions.make([chapter], cloud: true)
        #expect(cloud.count > 10_000)
        #expect(AssistantInstructions.make([], cloud: true).contains("Nothing is attached"))
    }
}

@Suite("Assistant markdown")
struct AssistantMarkdownTests {
    @Test("splits headings, lists, code and paragraphs")
    func blocks() {
        let blocks = AssistantMarkdown.blocks("""
        ## Plan
        Start small.

        - one
        - two
        1. first
        ```
        let x = 1
        """)
        #expect(blocks.count == 4)
        #expect(blocks[0] == .heading(2, "Plan"))
        #expect(blocks[1] == .paragraph("Start small."))
        if case .list(let items) = blocks[2] {
            #expect(items.map(\.marker) == ["•", "•", "1."])
        } else {
            Issue.record("expected a list")
        }
        // A fence still open mid-stream renders as code.
        #expect(blocks[3] == .code("let x = 1"))
    }

    @Test("a hashtag is not a heading")
    func hashtag() {
        #expect(AssistantMarkdown.blocks("#tag") == [.paragraph("#tag")])
    }
}

@Suite("Assistant cloud requests")
struct AssistantCloudRequestTests {
    private let image = AssistantAttachment(id: UUID(), kind: .image, name: "p.jpg", data: Data([1, 2, 3]), mimeType: "image/jpeg", thumbnail: nil)
    private let pdf = AssistantAttachment(id: UUID(), kind: .pdf, name: "notes.pdf", data: Data("%PDF".utf8), mimeType: "application/pdf", thumbnail: nil)

    private func body(_ conversation: CloudConversation, _ credential: AssistantProviderStore.Credential) throws -> JSONValue {
        let request = try conversation.request(credential)
        return try JSONDecoder().decode(JSONValue.self, from: request.httpBody ?? Data())
    }

    @Test("OpenAI: unstored, streamed, files as input parts")
    func openAI() throws {
        let conversation = CloudConversation(
            model: AssistantModel(provider: .chatGPT, slug: "gpt-x", name: "GPT"), instructions: "be kind",
            tools: AssistantCloudTools.make(canFixCard: false), history: [], prompt: "hi", attachments: [image, pdf]
        )
        let request = try conversation.request(.bearer("token"))
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/responses")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token")
        let json = try body(conversation, .bearer("token"))
        #expect(json["store"] == .bool(false))
        #expect(json["stream"] == .bool(true))
        let parts = json["input"]?.array?.last?["content"]?.array ?? []
        #expect(parts.map { $0["type"]?.string } == ["input_image", "input_file", "input_text"])
        #expect(json["tools"]?.array?.contains { $0["name"]?.string == "fixThisCard" } == false)
    }

    @Test("Anthropic: images and documents as content blocks, tool results as user turn")
    func anthropic() throws {
        var conversation = CloudConversation(
            model: AssistantModel(provider: .anthropic, slug: "claude-x", name: "Claude"), instructions: "be kind",
            tools: AssistantCloudTools.make(canFixCard: true), history: [CloudHistoryTurn(prompt: "a", attachments: [], reply: "b")],
            prompt: "hi", attachments: [image, pdf]
        )
        var round = CloudRound()
        round.calls = [CloudToolCall(id: "tu_1", name: "findNotes", arguments: #"{"question":"x"}"#)]
        round.items = [["type": "tool_use", "id": "tu_1", "name": "findNotes", "input": ["question": "x"]]]
        conversation.append(round, results: [(round.calls[0], "NO_RESULTS")])
        let request = try conversation.request(.apiKey("sk-ant"))
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-ant")
        let json = try body(conversation, .apiKey("sk-ant"))
        let messages = json["messages"]?.array ?? []
        #expect(messages.map { $0["role"]?.string } == ["user", "assistant", "user", "assistant", "user"])
        let parts = messages[2]["content"]?.array ?? []
        #expect(parts.map { $0["type"]?.string } == ["image", "document", "text"])
        #expect(messages[4]["content"]?.array?.first?["type"]?.string == "tool_result")
        #expect(json["tools"]?.array?.contains { $0["name"]?.string == "fixThisCard" } == true)
    }

    @Test("reasoning items can be dropped for models that refuse them")
    func dropReasoning() throws {
        var conversation = CloudConversation(
            model: AssistantModel(provider: .openAI, slug: "gpt-x", name: "GPT"), instructions: "", tools: [], history: [], prompt: "hi", attachments: []
        )
        var round = CloudRound()
        round.items = [["type": "reasoning", "encrypted_content": "abc"], ["type": "function_call", "call_id": "c", "name": "n", "arguments": "{}"]]
        round.calls = [CloudToolCall(id: "c", name: "n", arguments: "{}")]
        conversation.append(round, results: [(round.calls[0], "ok")])
        conversation.dropReasoning()
        let json = try body(conversation, .apiKey("k"))
        #expect(json["include"] == nil)
        #expect(json["input"]?.array?.contains { $0["type"]?.string == "reasoning" } == false)
    }
}

@Suite("ChatGPT sign-in helpers")
struct ChatGPTAuthHelperTests {
    @Test("base64url has no padding or unsafe characters")
    func base64URL() {
        let encoded = ChatGPTAuth.base64URL(Data([0xfb, 0xff, 0xfe]))
        #expect(!encoded.contains("+") && !encoded.contains("/") && !encoded.contains("="))
        #expect(JWT.decode(encoded) == Data([0xfb, 0xff, 0xfe]))
    }

    @Test("parses a JWT's header and claims")
    func parse() throws {
        let header = ChatGPTAuth.base64URL(Data(#"{"alg":"RS256","kid":"k"}"#.utf8))
        let payload = ChatGPTAuth.base64URL(Data(#"{"sub":"user","scope":"openid"}"#.utf8))
        let jwt = try JWT.parse("\(header).\(payload).\(ChatGPTAuth.base64URL(Data([1])))")
        #expect(jwt.header["kid"] as? String == "k")
        #expect(jwt.payload["sub"] as? String == "user")
    }
}

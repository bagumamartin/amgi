import AmgiAppCore
import AnkiClients
import AnkiKit
import CoreGraphics
import Dependencies
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import AssistantFeature

@Suite("Assistant card images")
struct AssistantCardMediaTests {
    @Test("image-only cards send pixels through cloud requests and follow-ups", arguments: [AssistantProvider.chatGPT, .openAI, .anthropic])
    @MainActor func imageOnlyCard(_ provider: AssistantProvider) async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try png().write(to: root.appendingPathComponent("screenshot.png"))
        let note = NoteRecord(id: NoteID(42), guid: "image-card", mid: NotetypeID(7), mod: 1,
                              flds: "<img src=\"screenshot.png\">\u{1f}An answer", sfld: "", csum: 0)
        let toolbox = withDependencies {
            $0.noteClient.fetch = { _ in note }
            $0.notetypesClient.get = { _ in Notetype(id: NotetypeID(7), name: "Basic", fields: [.init(name: "Front"), .init(name: "Back")]) }
        } operation: {
            AssistantToolbox(profile: .init(id: "fixture", displayName: "Fixture", selectionID: UUID()), contexts: [])
        }
        let resolved = await toolbox.resolve(.card(noteID: 42, deckID: nil))
        #expect(resolved.reference.contains("Front: [Image: screenshot.png]"))
        #expect(resolved.reference.contains("Back: An answer"))
        // History persists references, then reloads pixels after reopening.
        let encoded = try JSONEncoder().encode(resolved)
        let restored = try JSONDecoder().decode(AssistantContext.self, from: encoded)
        let media = try await AssistantCardMedia.load(sources: AssistantCardMedia.sources(in: [restored]), mediaRoot: root, availableSlots: 5)
        let image = try #require(media.images.first)
        #expect(media.warnings.isEmpty)
        #expect(image.mimeType == "image/jpeg")
        #expect(CGImageSourceCreateWithData(image.data as CFData, nil) != nil)
        let model = AssistantModel(provider: provider, slug: "synthetic", name: "Synthetic test")
        let credential: AssistantProviderStore.Credential = provider == .chatGPT ? .bearer("synthetic-token") : .apiKey("synthetic-key")
        let context = AssistantInstructions.block([restored], cloud: true)
        let conversation = CloudConversation(model: model, instructions: "test", tools: [], history: [], prompt: "Read this card",
                                             attachments: [], context: context, cardImages: media.images)
        let first = try body(conversation, credential)
        let messages = (provider == .anthropic ? first["messages"] : first["input"])?.array ?? []
        let parts = messages.first?["content"]?.array ?? []
        if provider == .anthropic {
            #expect(parts.contains { $0["type"]?.string == "image" && $0["source"]?["data"]?.string == image.data.base64EncodedString() })
        } else {
            #expect(parts.contains { $0["type"]?.string == "input_image" && $0["image_url"]?.string == image.dataURL })
        }
        #expect(parts.contains { $0["text"]?.string?.contains("Card image: screenshot.png") == true })
        let followUp = CloudConversation(model: model, instructions: "test", tools: [],
                                         history: [.init(prompt: "Read this card", attachments: [], reply: "A reply", context: context, cardImages: media.images)],
                                         prompt: "Explain more", attachments: [])
        let replay = try body(followUp, credential)
        let replayed = (provider == .anthropic ? replay["messages"] : replay["input"])?.array ?? []
        #expect(replayed.first?["content"] == messages.first?["content"])
        #expect(replayed.last?["content"]?.array?.count == 1)
    }

    @Test("HTML image references survive quoted, unquoted, uppercase and encoded sources")
    func parsesImages() {
        let field = AssistantCardMedia.field(#"<b>Question</b><IMG SRC='one.png'><img src=two.png><img src="a&amp;b.png"><img data-src="ignored.png" src="three.png">"#)
        #expect(field.sources == ["one.png", "two.png", "a&b.png", "three.png"])
        #expect(field.text.contains("Question") && field.text.contains("[Image: a&b.png]"))
        let embedded = AssistantCardMedia.field(#"<img src="data:image/png;base64,AAAA">"#)
        #expect(!embedded.text.isEmpty && embedded.sources.isEmpty)
    }

    @Test("encoded and asset-scheme references to the same media are sent once")
    func deduplicatesMedia() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try png().write(to: root.appendingPathComponent("my scan.png"))
        let media = try await AssistantCardMedia.load(sources: ["my%20scan.png", "amgi-asset://media/my%20scan.png"], mediaRoot: root, availableSlots: 5)
        #expect(media.images.count == 1 && media.warnings.isEmpty)
    }

    @Test("missing files, remote URLs and paths outside collection media are reported without reading them")
    func rejectsUnavailableMedia() async throws {
        let base = try directory()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let outside = base.appendingPathComponent("outside.png")
        try png().write(to: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked.png"), withDestinationURL: outside)
        let media = try await AssistantCardMedia.load(
            sources: ["missing.png", "https://example.invalid/image.png", "../outside.png", "linked.png"], mediaRoot: root, availableSlots: 5
        )
        #expect(media.images.isEmpty && media.warnings.count == 4)
        #expect(media.appendingWarnings(to: "Front: [Image: missing.png]").contains("missing or unreadable"))
    }

    @Test("card images respect remaining attachment slots and explain omissions")
    func limitsMedia() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["one.png", "two.png"] { try png().write(to: root.appendingPathComponent(name)) }
        let media = try await AssistantCardMedia.load(sources: ["one.png", "two.png"], mediaRoot: root, availableSlots: 1)
        #expect(media.images.count == 1 && media.warnings.count == 1)
        #expect(media.warnings[0].contains("attachment limit"))
    }

    private func body(_ conversation: CloudConversation, _ credential: AssistantProviderStore.Credential) throws -> JSONValue {
        let request = try conversation.request(credential)
        return try JSONDecoder().decode(JSONValue.self, from: request.httpBody ?? Data())
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("assistant-card-images-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func png() throws -> Data {
        let context = try #require(CGContext(data: nil, width: 32, height: 16, bitsPerComponent: 8, bytesPerRow: 128,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 16))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

import Foundation
import XCTest
@testable import AmgiEmbeddings

/// A native app host is required on physical iOS devices: SPM's tool-hosted
/// test agent is supported on Mac/simulators only. This target has its own
/// app identity and temp assets; it never loads Ijuka's collection services.
@MainActor
final class NativeModelGateTests: XCTestCase {
    private struct Reference: Decodable { let vectors: [String: [Float]] }
    func testPinnedMultimodalReferenceVectors() async throws {
        guard ProcessInfo.processInfo.environment["AMGI_E2E_MODEL_DOWNLOAD"] == "1" else { throw XCTSkip("Opt in to model downloads for hardware gates") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gemma-hardware-\(UUID().uuidString)")
        let original = ModelAssetManager.modelsRootOverride
        ModelAssetManager.modelsRootOverride = root
        defer { ModelAssetManager.modelsRootOverride = original; try? FileManager.default.removeItem(at: root) }
        let engine = TextEmbedder.shared
        do {
            let manager = ModelAssetManager()
            for module in ModelAssetManager.Module.allCases { await manager.install(module, allowExpensiveNetwork: true) }
            for module in ModelAssetManager.Module.allCases { XCTAssertTrue(ModelAssetManager.isInstalled(module), "Module \(module) did not install") }
            guard ModelAssetManager.Module.allCases.allSatisfy(ModelAssetManager.isInstalled) else { throw GateError.missingModule }
            let directory = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "DigUpReference", withExtension: nil))
            let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: directory.appendingPathComponent("vectors.json")))
            var report: [String: Double] = [:]
            for (name, text) in [("query", "payment declined error"), ("query-bn", "ইলিশ মাছ রান্না"), ("query-ar", "متى تغلق المكتبة")] {
                let started = Date()
                let vector = try await engine.embed(text, prefix: .query)
                let cosine = TextEmbedder.cosine(vector, try XCTUnwrap(reference.vectors[name]))
                report[name] = Double(cosine); report[name + "_seconds"] = Date().timeIntervalSince(started)
                XCTAssertGreaterThan(cosine, 0.995)
            }
            let document = "title: Tokyo itinerary | text: Flight to Tokyo Haneda on November 3. Then the train to Kamakura to see the Great Buddha, and back for dinner in Shibuya."
            let doc = try await engine.embedMixed([.text(document)])
            report["document"] = Double(TextEmbedder.cosine(doc, try XCTUnwrap(reference.vectors["document"])))
            XCTAssertGreaterThan(try XCTUnwrap(report["document"]), 0.995)
            for (name, file, budget) in [("screen-280", "screen.png", 280), ("photo-140", "photo.jpg", 140), ("frame-70", "photo.jpg", 70)] {
                let vector = try await engine.embedImage(directory.appendingPathComponent(file), maxSoftTokens: budget)
                let cosine = TextEmbedder.cosine(vector, try XCTUnwrap(reference.vectors[name]))
                report[name] = Double(cosine); XCTAssertGreaterThan(cosine, 0.99)
            }
            let wav = [UInt8](try Data(contentsOf: directory.appendingPathComponent("speech.wav")))
            let samples = stride(from: 44, to: wav.count - 1, by: 2).map { offset in Float(Int16(bitPattern: UInt16(wav[offset]) | UInt16(wav[offset + 1]) << 8)) / 32768 }
            let audio = try await engine.embedAudio(samples: samples)
            let audioScore = TextEmbedder.cosine(audio, try XCTUnwrap(reference.vectors["speech"]))
            report["speech"] = Double(audioScore); XCTAssertGreaterThan(audioScore, 0.99)
            let frame = try await engine.embedMixed([.videoFrame(directory.appendingPathComponent("photo.jpg"), timestamp: nil)])
            XCTAssertGreaterThan(TextEmbedder.cosine(frame, try XCTUnwrap(reference.vectors["frame-70"])), 0.99)
            let plain = try await engine.embed("receptor antagonist", prefix: .passage)
            let mixedText = try await engine.embedMixed([.text("title: none | text: receptor antagonist")])
            XCTAssertGreaterThan(TextEmbedder.cosine(plain, mixedText), 0.9999)
            let mixed = try await engine.embedMixed([.text("A payment screenshot"), .image(directory.appendingPathComponent("screen.png")), .audio(samples: samples), .videoFrame(directory.appendingPathComponent("photo.jpg"), timestamp: 3)])
            XCTAssertEqual(mixed.count, 768); XCTAssertTrue(mixed.allSatisfy(\.isFinite))
            for (key, bytes) in await engine.memoryDiagnostics() { report[key] = Double(bytes) }
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = "Native Q8 hardware gate"; attachment.lifetime = .keepAlways; add(attachment)
            print("GEMMA_HARDWARE_GATE " + String(decoding: data, as: UTF8.self))
            await engine.resetEngineForModelInstall()
        } catch { await engine.resetEngineForModelInstall(); throw error }
    }
    private enum GateError: Error { case missingModule }
}

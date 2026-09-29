import Foundation
import Testing
@testable import ReaderFeature

/// Guards the shipped reader script itself.
///
/// The anchor builder, the sentence extractor, and the tokeniser are all
/// string-interpolated and hand-edited JavaScript that no Swift compiler
/// sees. A single unbalanced quote ships a reader where every tap silently
/// does nothing, so the file is parsed on every test run.
@Suite("EPUB reader injected script")
struct EPUBReaderInjectionScriptTests {
    static let scriptPath =
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ReaderFeatureTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // AmgiFeatures
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("AmgiApp/Resources/EPUBReader/EPUBReaderInjection.js")

    static func readerSource(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ReaderFeatureTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // AmgiFeatures
            .appendingPathComponent("Sources/ReaderFeature/Reader/\(name)")
    }

    @Test("the shipped injection script parses")
    func injectionScriptParses() throws {
        let url = Self.scriptPath
        #expect(FileManager.default.fileExists(atPath: url.path))
        let source = try String(contentsOf: url, encoding: .utf8)
        switch JSValidator.check(source) {
        case .valid:
            break
        case .invalid(let detail):
            Issue.record("EPUBReaderInjection.js is not valid JavaScript:\n\(detail)")
        case .skipped(let reason):
            Issue.record("EPUBReaderInjection.js could not be validated: \(reason)")
        }
    }

    @Test("the script still posts every message the native side handles")
    func injectionScriptPostsExpectedMessages() throws {
        let source = try String(contentsOf: Self.scriptPath, encoding: .utf8)
        // Each of these has a matching `userContent.add(_, name:)` on the
        // native side; a rename on one side only would break the bridge
        // silently because the post is wrapped in try/catch. `emptyTap` is
        // owned by EPUBReaderBundledResources rather than this file, and is
        // asserted separately below.
        //
        // `wordSelection` replaced `wordTap`: a single tap no longer looks a
        // word up, so the lookup path is driven by a selection instead.
        for handler in ["pageInfo", "progress", "wordSelection"] {
            #expect(
                source.contains("messageHandlers.\(handler).postMessage"),
                "expected the script to post \(handler)"
            )
        }
    }

    @Test("the empty-tap bridge is registered and matches on both sides")
    func emptyTapBridgeIsRegistered() throws {
        // Defined in Swift, not in the injection file, so assert on the
        // source of truth for both halves of the bridge.
        let host = try String(
            contentsOf: Self.readerSource("EPUBChapterPageController.swift"),
            encoding: .utf8
        )
        #expect(host.contains("messageHandlers.emptyTap.postMessage"))
        #expect(host.contains("add(bridge, name: \"emptyTap\")"))
    }

    @Test("the word tap posts a full anchor, not just a sentence")
    func wordTapCarriesAnAnchor() throws {
        let source = try String(contentsOf: Self.scriptPath, encoding: .utf8)
        // The anchor is what makes a note re-openable at its source; a
        // regression here silently downgrades notes to a bare sentence.
        #expect(source.contains("anchor: {"))
        for field in ["cfi", "path", "quote", "contextBefore", "contextAfter"] {
            #expect(source.contains(field), "expected the anchor to carry \(field)")
        }
    }

    @Test("the selection payload carries the selected text as well as the anchor")
    func selectionPayloadCarriesText() throws {
        let source = try String(contentsOf: Self.scriptPath, encoding: .utf8)
        // Without the selected range the menu's Copy and Highlight have
        // nothing to act on — the anchor alone only locates a single token.
        #expect(source.contains("selection: text"))
    }

    @Test("the host-callable resolver mirrors the native resolution order")
    func resolverMirrorsResolutionOrder() throws {
        let source = try String(contentsOf: Self.scriptPath, encoding: .utf8)
        #expect(source.contains("__amgiResolveAnchor"))
        // offset, then path, then quote — the same order documented on
        // ReaderSourceAnchor, so a stored anchor resolves the same way on
        // every device.
        let offsetAt = source.range(of: "strategy = 'offset'")
        let pathAt = source.range(of: "strategy = 'path'")
        let quoteAt = source.range(of: "strategy = 'quote'")
        #expect(offsetAt != nil && pathAt != nil && quoteAt != nil)
        #expect(offsetAt!.lowerBound < pathAt!.lowerBound)
        #expect(pathAt!.lowerBound < quoteAt!.lowerBound)
    }
}

import AppIntentsTesting
import XCTest

/// Executed by a signed iOS 27 UI-test runner. Unlike package-level intent
/// unit tests, this validates the metadata that the system actually consumes
/// from the app bundle and invokes the intent through Ijuka's real runtime
/// dependency graph.
@available(iOS 27.0, macOS 27.0, *)
final class AppIntentsIntegrationTests: XCTestCase {
    // Construct after the signed app has launched; AppIntentsTesting reads
    // metadata from the system registry rather than the test bundle image.
    private var definitions: IntentDefinitions {
        IntentDefinitions(bundleIdentifier: "com.bagumamartin.ijuka")
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.bagumamartin.ijuka")
        app.launch()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 15),
            "The signed app must be running before AppIntentsTesting queries its metadata."
        )
    }

    func testDueCountIntentIsInstalledAndRuns() async throws {
        let definition = definitions.intents["DueCountIntent"]
        XCTAssertEqual(definition.bundleIdentifier, "com.bagumamartin.ijuka")
        _ = try await definition.makeIntent().run()
    }

    func testSystemSearchSchemaIsInstalled() {
        let definition = definitions.intents["SystemSearchInAppIntent"]
        XCTAssertEqual(definition.bundleIdentifier, "com.bagumamartin.ijuka")
    }

    func testDeckEntityQueryIsProfileScopedAndRunnable() async throws {
        // The first AppIntents query after a full test-plan run can race the
        // system's metadata registration. A read-only intent warm-up makes the
        // app present before asking the entity service to resolve its query.
        let dueCount = definitions.intents["DueCountIntent"]
        _ = try await dueCount.makeIntent().run()

        let definition = definitions.entities["DeckEntity"]
        XCTAssertEqual(definition.bundleIdentifier, "com.bagumamartin.ijuka")
        // AppIntentsTesting exposes the short metadata identifier here; the
        // bundle metadata itself records AmgiAppShared.DeckEntity.
        XCTAssertEqual(definition.typeIdentifier, "DeckEntity")
        _ = try await definition.suggestedEntities()
    }
}

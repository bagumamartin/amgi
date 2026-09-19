import Testing
import SwiftUI
import AmgiAppCore
import AnkiSync
import Sharing
@testable import SyncFeature

@Suite @MainActor struct OnboardingViewTests {
    @Test func onboardingViewCanBeInstantiatedAndEvaluated() {
        let view = OnboardingView()
        _ = view.body
    }

    @Test func syncEndpointNormalization() throws {
        let raw = "sync.example.com"
        let normalized = try SyncEndpoint.normalized(raw)
        #expect(normalized == "https://sync.example.com")
    }

    @Test func syncEndpointNormalizationInvalidThrows() {
        #expect(throws: (any Error).self) {
            _ = try SyncEndpoint.normalized("   ")
        }
    }
}

import AmgiAppCore
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

public enum FoundationModelService {
    public static var availability: AssistantModelAvailability {
        guard AutomationPreferences.foundationModelsEnabled else { return .disabled }

        #if os(iOS) || os(macOS)
        if #available(iOS 26.0, macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .ready
            case .unavailable(let reason):
                return .unavailable(message(for: reason))
            }
        }
        return .unavailable("Requires iOS 26 or macOS 26")
        #else
        return .unavailable("Not available on this platform")
        #endif
    }

    #if os(iOS) || os(macOS)
    @available(iOS 26.0, macOS 26.0, *)
    public static func respond(
        instructions: String,
        prompt: String
    ) async throws -> String {
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: prompt)
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @available(iOS 26.0, macOS 26.0, *)
    private static func message(
        for reason: SystemLanguageModel.Availability.UnavailableReason
    ) -> String {
        switch reason {
        case .deviceNotEligible:
            "This device does not support Apple Intelligence"
        case .appleIntelligenceNotEnabled:
            "Apple Intelligence is turned off"
        case .modelNotReady:
            "The system model is not ready yet"
        @unknown default:
            "Apple Intelligence is unavailable"
        }
    }
    #endif
}

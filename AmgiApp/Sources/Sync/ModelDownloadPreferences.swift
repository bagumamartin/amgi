// AmgiApp/Sources/Sync/ModelDownloadPreferences.swift
import Foundation

/// Consent + network policy for the e5 model download (AmgiEmbeddings).
/// The download only ever starts after explicit consent; the policy governs
/// automatic retries and future version upgrades.
enum ModelDownloadPreferences {
    enum Policy: String, CaseIterable, Identifiable, Sendable {
        case wifiOnly = "Wi-Fi Only"
        case any = "Any Network"

        var id: String { rawValue }
    }

    static let consentGivenKey = "model_pref_consent_given"
    static let policyKey = "model_pref_network_policy"
    static let lastPromptAtKey = "model_pref_last_prompt_at"

    static var consentGiven: Bool {
        UserDefaults.standard.bool(forKey: consentGivenKey)
    }

    static func setConsentGiven(_ value: Bool = true) {
        UserDefaults.standard.set(value, forKey: consentGivenKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastPromptAtKey)
    }

    static var policy: Policy {
        Policy(rawValue: UserDefaults.standard.string(forKey: policyKey) ?? "") ?? .wifiOnly
    }

    static func setPolicy(_ policy: Policy) {
        UserDefaults.standard.set(policy.rawValue, forKey: policyKey)
    }
}

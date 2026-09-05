import Foundation

/// Consent + network policy for the e5 model download (AmgiEmbeddings).
/// The download only ever starts after explicit consent; the policy governs
/// automatic retries and future version upgrades.
///
/// `package`: the Maintenance screen (SettingsFeature) reads the policy and
/// offers the picker + delete there.
package enum ModelDownloadPreferences {
    package enum Policy: String, CaseIterable, Identifiable, Sendable {
        case wifiOnly = "Wi-Fi Only"
        case any = "Any Network"

        package var id: String { rawValue }
    }

    package static let consentGivenKey = "model_pref_consent_given"
    package static let policyKey = "model_pref_network_policy"
    package static let lastPromptAtKey = "model_pref_last_prompt_at"

    package static var consentGiven: Bool {
        UserDefaults.standard.bool(forKey: consentGivenKey)
    }

    package static func setConsentGiven(_ value: Bool = true) {
        UserDefaults.standard.set(value, forKey: consentGivenKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastPromptAtKey)
    }

    package static var policy: Policy {
        Policy(rawValue: UserDefaults.standard.string(forKey: policyKey) ?? "") ?? .wifiOnly
    }

    package static func setPolicy(_ policy: Policy) {
        UserDefaults.standard.set(policy.rawValue, forKey: policyKey)
    }
}

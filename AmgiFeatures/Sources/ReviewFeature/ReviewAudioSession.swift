import Foundation
#if os(iOS)
import AVFoundation
#endif

/// Applies the appropriate AVAudioSession category for card audio playback
/// based on the `playAudioInSilentMode` review preference.
///
/// - When `playInSilent` is true, uses `.playback` so cards with audio still
///   play even when the device's silent switch is engaged.
/// - When false, uses `.ambient` so the OS silent switch / other-app audio
///   is respected (the default iOS behavior).
///
/// macOS has no AVAudioSession; audio plays with the system-default policy,
/// so `apply` is a no-op there.
@MainActor
enum ReviewAudioSession {
    static func apply(playInSilent: Bool) {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        let category: AVAudioSession.Category = playInSilent ? .playback : .ambient
        do {
            try session.setCategory(category, mode: .default, options: [.mixWithOthers])
            try session.setActive(true, options: [])
        } catch {
            // Audio category failures are non-fatal — a card whose audio cannot
            // play due to category mismatch will still render correctly.
        }
        #endif
    }
}

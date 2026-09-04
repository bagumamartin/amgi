// AmgiApp/Sources/Review/GraduationHaptics.swift
#if os(iOS)
import CoreHaptics
import UIKit

/// A long continuous "got it right" haptic (Duolingo-style), fired only when an
/// answer graduates a card. On hardware that supports CoreHaptics this plays a
/// sustained `hapticContinuous` event; otherwise (or on any engine failure) it
/// falls back to the current short medium impact so no phone is left silent.
@MainActor
enum GraduationHaptics {
    private static var engine: CHHapticEngine?

    static func play() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else {
            fallback()
            return
        }
        do {
            let engine = try makeWorkingEngine()
            let event = CHHapticEvent(
                eventType: .hapticContinuous,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.75),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.4),
                ],
                relativeTime: 0,
                duration: 0.4
            )
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            fallback()
        }
    }

    /// Returns the retained engine, or a fresh one if the old one stopped
    /// (e.g. after the app backgrounded). A retained engine avoids the startup
    /// latency of creating one per answer.
    private static func makeWorkingEngine() throws -> CHHapticEngine {
        if let engine, (try? engine.start()) != nil {
            return engine
        }
        let fresh = try CHHapticEngine()
        try fresh.start()
        engine = fresh
        return fresh
    }

    private static func fallback() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred(intensity: 0.6)
    }
}
#endif

import CoreGraphics
import Foundation

/// What one frame draws: the pose with ambient motion applied, how open the
/// eyes are from blinking, and the head's vertical offset.
struct HeadFrame: Equatable, Sendable {
    var pose: HeadPose
    var blink: Double = 1
    var bob: Double = 0
}

/// Turns (mood, gaze, time) into frames.
///
/// A reference type held in `@State` and deliberately *not* observable: it is
/// advanced from inside `TimelineView`, and publishing from there would
/// invalidate the view that is already redrawing. Everything except blink
/// scheduling, gaze smoothing and the mood hand-off is a pure function of
/// time, so frames never depend on the frame rate.
@MainActor
final class AssistantHeadEngine {
    private var mood: AssistantMood?
    private var script = HeadScript(steps: [])
    private var scriptStart: TimeInterval = 0
    /// The pose on screen when the mood last changed, blended out over the
    /// new script's first transition. Makes any switch continuous.
    private var handoff: (pose: HeadPose, start: TimeInterval, duration: Double)?
    private var lastScripted: HeadPose = .neutral

    private var nextBlink: TimeInterval = 0
    private var blinkStart: TimeInterval = -.infinity
    private var blinkSerial = 0
    private var pendingDouble = false

    private var gaze = CGPoint.zero
    private var lastTime: TimeInterval?
    /// A mood asked for but not yet shown. Activities must hold for
    /// ``settle`` first: a turn flicks between thinking, working and
    /// responding many times a second, and following every flick reads as
    /// a head swinging like a pendulum. Reactions show at once.
    private var requested: (mood: AssistantMood, since: TimeInterval)?
    static let settle: TimeInterval = 0.45

    func frame(mood: AssistantMood, gaze target: CGPoint?, at now: TimeInterval) -> HeadFrame {
        if self.mood == nil {
            begin(mood, at: now)
        } else if mood != self.mood {
            if requested?.mood != mood { requested = (mood, now) }
            if !mood.isActivity || now - (requested?.since ?? now) >= Self.settle {
                begin(mood, at: now)
                requested = nil
            }
        } else {
            requested = nil
        }

        var pose = script.pose(at: now - scriptStart)
        if let handoff {
            let progress = (now - handoff.start) / handoff.duration
            if progress >= 1 {
                self.handoff = nil
            } else {
                pose = .mix(handoff.pose, pose, easeOut(progress))
            }
        }
        lastScripted = pose

        let dt = lastTime.map { min(max(now - $0, 0), 0.1) } ?? 0
        lastTime = now
        let goal = target ?? .zero
        // Unhurried: a person turns their head to something, they don't
        // snap to it.
        let follow = 1 - exp(-dt * 4)
        gaze.x += (goal.x - gaze.x) * follow
        gaze.y += (goal.y - gaze.y) * follow

        return HeadFrame(
            pose: Self.ambient(pose, gaze: gaze, script: script, at: now),
            blink: blinkOpenness(at: now),
            bob: Self.bob(script.ambient, at: now)
        )
    }

    /// The first scripted pose with no motion — for Reduce Motion and for
    /// snapshots.
    static func still(mood: AssistantMood, gaze: CGPoint?) -> HeadFrame {
        let pose = mood.script.steps.first?.pose ?? .neutral
        let target = gaze ?? .zero
        return HeadFrame(pose: applyGaze(pose, CGPoint(x: target.x * pose.attention, y: target.y * pose.attention)))
    }

    private func begin(_ next: AssistantMood, at now: TimeInterval) {
        let wasRunning = mood != nil
        mood = next
        script = next.script
        scriptStart = now
        if wasRunning {
            handoff = (lastScripted, now, max(script.steps.first?.transition ?? 0.4, 0.15))
            // Blink through the change, the animator's trick: the lids
            // cover the frames where the eyes reshape.
            if blinkStart + 0.6 < now { nextBlink = now }
        } else {
            lastScripted = script.pose(at: 0)
            nextBlink = now + 1.4
        }
    }

    // MARK: Blinks

    private func blinkOpenness(at now: TimeInterval) -> Double {
        guard let rhythm = script.blink else { return 1 }
        if now >= nextBlink {
            blinkStart = nextBlink
            blinkSerial += 1
            if pendingDouble {
                pendingDouble = false
                nextBlink = blinkStart + rhythm.duration + interval(rhythm)
            } else if Self.noise(Double(blinkSerial) * 1.7) * 0.5 + 0.5 < rhythm.doubleChance {
                pendingDouble = true
                nextBlink = blinkStart + rhythm.duration + 0.09
            } else {
                nextBlink = blinkStart + rhythm.duration + interval(rhythm)
            }
        }
        let progress = (now - blinkStart) / rhythm.duration
        guard progress >= 0, progress < 1 else { return 1 }
        // Lids drop faster than they lift.
        let closing = progress < 0.4 ? progress / 0.4 : 1 - (progress - 0.4) / 0.6
        return 1 - easeInOut(closing)
    }

    private func interval(_ rhythm: HeadScript.Blink) -> Double {
        let unit = Self.noise(Double(blinkSerial) * 3.1 + 0.5) * 0.5 + 0.5
        return lerp(rhythm.minInterval, rhythm.maxInterval, unit)
    }

    // MARK: Ambient motion

    private static func ambient(_ pose: HeadPose, gaze: CGPoint, script: HeadScript, at t: TimeInterval) -> HeadPose {
        let motion = script.ambient
        var pose = applyGaze(pose, CGPoint(x: gaze.x * pose.attention, y: gaze.y * pose.attention))
        pose.yaw += smoothNoise(t, interval: 3.3, seed: 1) * motion.drift
        pose.pitch += smoothNoise(t, interval: 2.6, seed: 2) * motion.drift * 0.7
        pose.roll += smoothNoise(t, interval: 4.1, seed: 3) * motion.drift * 0.45
        if motion.shake > 0 {
            let w = t * motion.shakeRate * 2 * .pi
            pose.roll += (sin(w) + sin(w * 1.71) * 0.4) * motion.shake
        }
        if motion.talk > 0 {
            // Two noise rates: syllables riding on slower phrases, with a
            // floor so the mouth closes between words.
            let syllable = smoothNoise(t, interval: 0.11, seed: 41) * 0.5 + 0.5
            let phrase = smoothNoise(t, interval: 0.9, seed: 43) * 0.5 + 0.5
            let level = max(0, syllable * (0.4 + 0.6 * phrase) - 0.18) / 0.82
            pose.mouth.open = clamp(pose.mouth.open + level * motion.talk, 0, 1)
        }
        let dartX = saccade(t, seed: 11) * motion.saccade
        let dartY = saccade(t, seed: 23) * motion.saccade * 0.6
        pose.left.x += dartX; pose.right.x += dartX
        pose.left.y += dartY; pose.right.y += dartY
        return pose
    }

    /// `gaze` is in −1…1, x toward the viewer's right, y downward — the
    /// same orientation as a `UnitPoint` mapped around its centre.
    private static func applyGaze(_ pose: HeadPose, _ gaze: CGPoint) -> HeadPose {
        var pose = pose
        let x = clamp(gaze.x, -1, 1), y = clamp(gaze.y, -1, 1)
        pose.yaw += x * 22
        pose.pitch -= y * 16
        pose.left.x += x * 5; pose.right.x += x * 5
        pose.left.y -= y * 4; pose.right.y -= y * 4
        return pose
    }

    private static func bob(_ motion: HeadScript.Ambient, at t: TimeInterval) -> Double {
        guard motion.bob > 0 else { return 0 }
        let wave = sin(t * motion.bobRate * 2 * .pi)
        return motion.hop ? abs(wave) * motion.bob : wave * motion.bob
    }

    // MARK: Noise

    /// Deterministic hash to −1…1.
    static func noise(_ x: Double) -> Double {
        let raw = sin(x * 127.1 + 311.7) * 43_758.5453
        return (raw - raw.rounded(.down)) * 2 - 1
    }

    /// Smoothly interpolated value noise in −1…1.
    private static func smoothNoise(_ t: Double, interval: Double, seed: Double) -> Double {
        let progress = t / interval
        let step = progress.rounded(.down)
        let blend = smoothstep(0, 1, progress - step)
        return lerp(noise(step * 3 + seed), noise((step + 1) * 3 + seed), blend)
    }

    /// Eyes hold, then dart quickly to a new spot — how real eyes move.
    private static func saccade(_ t: Double, seed: Double) -> Double {
        let interval = 1.9
        let step = (t / interval).rounded(.down)
        let progress = (t - step * interval) / 0.12
        return lerp(noise((step - 1) * 2 + seed), noise(step * 2 + seed), smoothstep(0, 1, progress))
    }
}

func easeOut(_ t: Double) -> Double {
    let x = clamp(t, 0, 1)
    return 1 - pow(1 - x, 3)
}

/// What the assistant head is doing or feeling.
///
/// Two kinds, one type, so every surface takes a single value:
/// - **Activities** loop for as long as the work lasts — set `.thinking` when
///   a request goes out, `.responding` while tokens stream, `.idle` after.
/// - **Reactions** are held moods — `.happy` on a correct answer, `.confused`
///   on an error. They still breathe, blink and glance; they just don't
///   wander off into another face.
///
/// Changing the value blends from whatever is on screen, so callers can
/// switch freely without waiting for anything to settle.
public enum AssistantMood: String, CaseIterable, Identifiable, Sendable {
    // Activities
    case idle
    case listening
    case thinking
    case searching
    case responding
    case sleeping

    // Reactions
    case happy
    case laughing
    case celebrating
    case curious
    case surprised
    case skeptical
    case suspicious
    case confused
    case determined
    case proud
    case wink
    case shy
    case sleepy
    case sad

    public var id: String { rawValue }

    public var isActivity: Bool {
        switch self {
        case .idle, .listening, .thinking, .searching, .responding, .sleeping: true
        default: false
        }
    }
}

/// A looping sequence of poses plus the ambient life layered on top.
struct HeadScript: Sendable {
    struct Step: Sendable {
        var pose: HeadPose
        /// Seconds the pose is held once reached.
        var hold: Double
        /// Seconds spent travelling into this pose from the previous one.
        var transition: Double = 0.45
    }

    struct Blink: Sendable {
        var minInterval: Double = 2.4
        var maxInterval: Double = 5.2
        var duration: Double = 0.16
        /// Chance that a blink is immediately followed by a second.
        var doubleChance: Double = 0.18
    }

    struct Ambient: Sendable {
        /// Degrees of slow head wander.
        var drift: Double = 2
        /// Face units of quick eye darts.
        var saccade: Double = 1.2
        /// Degrees of fast roll jitter (laughing) and its frequency in Hz.
        var shake: Double = 0
        var shakeRate: Double = 6
        /// Face units of vertical bob and its frequency in Hz. `hop` makes
        /// it bounce off a floor instead of swinging through centre.
        var bob: Double = 0
        var bobRate: Double = 1
        var hop = false
        /// 0…1 of extra mouth opening, flickering at syllable rate — speech.
        var talk: Double = 0
    }

    var steps: [Step]
    var blink: Blink? = Blink()
    var ambient = Ambient()

    var cycleDuration: Double {
        steps.reduce(0) { $0 + $1.transition + $1.hold }
    }

    /// The scripted pose `elapsed` seconds in, looping.
    func pose(at elapsed: Double) -> HeadPose {
        guard let first = steps.first else { return .neutral }
        guard steps.count > 1, cycleDuration > 0 else { return first.pose }
        var t = elapsed.truncatingRemainder(dividingBy: cycleDuration)
        if t < 0 { t += cycleDuration }
        for (index, step) in steps.enumerated() {
            if t < step.transition {
                let previous = steps[(index + steps.count - 1) % steps.count].pose
                return .mix(previous, step.pose, easeInOut(t / step.transition))
            }
            t -= step.transition
            if t < step.hold { return step.pose }
            t -= step.hold
        }
        return steps[steps.count - 1].pose
    }
}

func easeInOut(_ t: Double) -> Double {
    let x = clamp(t, 0, 1)
    return x * x * x * (x * (x * 6 - 15) + 10)
}

// MARK: - The expression library

extension AssistantMood {
    var script: HeadScript {
        switch self {
        case .idle: Self.idleScript
        case .listening: Self.listeningScript
        case .thinking: Self.thinkingScript
        case .searching: Self.searchingScript
        case .responding: Self.respondingScript
        case .sleeping: Self.sleepingScript
        case .happy: Self.happyScript
        case .laughing: Self.laughingScript
        case .celebrating: Self.celebratingScript
        case .curious: Self.curiousScript
        case .surprised: Self.surprisedScript
        case .skeptical: Self.skepticalScript
        case .suspicious: Self.suspiciousScript
        case .confused: Self.confusedScript
        case .determined: Self.determinedScript
        case .proud: Self.proudScript
        case .wink: Self.winkScript
        case .shy: Self.shyScript
        case .sleepy: Self.sleepyScript
        case .sad: Self.sadScript
        }
    }

    private typealias Step = HeadScript.Step

    private static func eye(
        y: Double = 6, width: Double = 19, height: Double = 44, tilt: Double = 0,
        lid: Double = 0, slant: Double = 0, smile: Double = 0, open: Double = 1,
        bend: Double = 0, spread: Double = 18
    ) -> EyePose {
        EyePose(
            x: -spread, y: y, width: width, height: height, tilt: tilt,
            lid: lid, slant: slant, smile: smile, open: open, bend: bend
        )
    }

    private static func mouth(
        x: Double = 0, y: Double = -40, width: Double = 18, curve: Double = 0.25,
        open: Double = 0, skew: Double = 0, wave: Double = 0
    ) -> MouthPose {
        MouthPose(x: x, y: y, width: width, curve: curve, open: open, skew: skew, wave: wave)
    }

    // Activities

    /// Mostly attending to where the caller points it (the content beside
    /// it), with the occasional glance back at the viewer — never an
    /// arbitrary turn away to one side.
    private static let idleScript: HeadScript = {
        let resting = mouth()
        return HeadScript(steps: [
            Step(pose: .face(mouth: resting), hold: 4.6, transition: 0.7),
            // Reading along: a small nod down the content, eyes leading.
            Step(pose: .face(pitch: -4, look: (1, -2), mouth: resting), hold: 2.2, transition: 0.8),
            Step(pose: .face(mouth: resting), hold: 3.4, transition: 0.7),
            // A glance at you, a hint of a smile, then back to it.
            Step(pose: .face(pitch: 2, roll: 3, mouth: mouth(curve: 0.4), attention: 0), hold: 1.3, transition: 0.55),
        ], ambient: .init(drift: 1.4, saccade: 0.7))
    }()

    private static let listeningScript: HeadScript = {
        let attentive = eye(width: 21, height: 47)
        let rapt = mouth(width: 12, curve: 0.1, open: 0.12)
        return HeadScript(steps: [
            Step(pose: .face(pitch: 5, roll: 7, eye: attentive, mouth: rapt), hold: 1.1),
            Step(pose: .face(pitch: -1, roll: 6, eye: attentive, mouth: mouth(width: 14, curve: 0.3)), hold: 0.5, transition: 0.35),
            Step(pose: .face(pitch: 5, roll: 7, eye: attentive, mouth: rapt), hold: 1.6, transition: 0.35),
        ], ambient: .init(drift: 1.5, saccade: 0.8))
    }()

    /// Eyes up and off to one side, held — the way people look away to
    /// recall something. It drifts once, slowly; it doesn't swing.
    private static let thinkingScript: HeadScript = {
        let pondering = eye(height: 40, lid: 0.12)
        return HeadScript(steps: [
            Step(
                pose: .face(pitch: 14, yaw: -10, roll: 4, look: (-5, 7), eye: pondering,
                            mouth: mouth(x: -4, width: 11, curve: -0.05, skew: 0.5), attention: 0.3),
                hold: 2.6, transition: 0.6
            ),
            Step(
                pose: .face(pitch: 16, yaw: -4, roll: 2, look: (-1, 8), eye: eye(height: 40, lid: 0.22, slant: 0.15),
                            mouth: mouth(x: -2, width: 10, curve: 0, wave: 0.3), attention: 0.3),
                hold: 2.2, transition: 1.1
            ),
        ], blink: .init(minInterval: 3, maxInterval: 6), ambient: .init(drift: 0.8, saccade: 0.4))
    }()

    /// Reading down results: the head stays put and dips line by line while
    /// the eyes run across. Small, steady, on the content.
    private static let searchingScript: HeadScript = {
        let scanning = eye(width: 20, height: 42)
        let intent = mouth(width: 13, curve: 0)
        return HeadScript(steps: [
            Step(pose: .face(pitch: -4, yaw: -3, look: (-5, -2), eye: scanning, mouth: intent), hold: 0.6, transition: 0.3),
            Step(pose: .face(pitch: -4, yaw: 4, look: (5, -2), eye: scanning, mouth: intent), hold: 0.5, transition: 0.45),
            Step(pose: .face(pitch: -8, yaw: -3, look: (-5, -4), eye: scanning, mouth: intent), hold: 0.6, transition: 0.35),
            Step(pose: .face(pitch: -8, yaw: 4, look: (5, -4), eye: scanning, mouth: mouth(width: 11, open: 0.08)), hold: 0.5, transition: 0.45),
        ], blink: .init(minInterval: 2.5, maxInterval: 4.5), ambient: .init(drift: 0.5, saccade: 0.3))
    }()

    private static let respondingScript: HeadScript = {
        let speaking = mouth(width: 19, curve: 0.3)
        return HeadScript(steps: [
            Step(pose: .face(eye: eye(smile: 0.12), mouth: speaking), hold: 0.5, transition: 0.3),
            Step(pose: .face(pitch: 2, eye: eye(height: 46), mouth: speaking), hold: 0.45, transition: 0.3),
            Step(pose: .face(pitch: 3, roll: 3, eye: eye(smile: 0.18), mouth: mouth(width: 21, curve: 0.45)), hold: 0.6, transition: 0.3),
            Step(pose: .face(roll: -2, eye: eye(height: 45), mouth: speaking), hold: 0.5, transition: 0.3),
        ], blink: .init(minInterval: 2.5, maxInterval: 4.5),
           ambient: .init(drift: 1, saccade: 0.6, bob: 0.5, bobRate: 1.2, talk: 0.42))
    }()

    private static let sleepingScript = HeadScript(steps: [
        Step(
            pose: .face(pitch: -12, roll: 6, look: (0, -3), eye: eye(width: 21, open: 0, bend: -0.12),
                        mouth: mouth(x: 2, width: 8, curve: 0, open: 0.14)),
            hold: 1
        ),
    ], blink: nil, ambient: .init(drift: 1, saccade: 0, bob: 1.4, bobRate: 0.25))

    // Reactions

    private static let happyScript: HeadScript = {
        let beaming = eye(width: 21, height: 40, smile: 0.6)
        let grin = mouth(width: 26, curve: 0.85, open: 0.28)
        return HeadScript(steps: [
            Step(pose: .face(pitch: 6, roll: 5, eye: beaming, mouth: grin), hold: 2.0),
            Step(pose: .face(pitch: 7, roll: -4, eye: beaming, mouth: grin), hold: 2.0, transition: 0.6),
        ], blink: .init(minInterval: 3, maxInterval: 6), ambient: .init(drift: 1.5, saccade: 0.5, bob: 0.8, bobRate: 1))
    }()

    private static let laughingScript = HeadScript(steps: [
        Step(
            pose: .face(pitch: 10, eye: eye(width: 23, height: 40, tilt: 6, open: 0.16, bend: 0.22),
                        mouth: mouth(width: 30, curve: 0.9, open: 0.5)),
            hold: 1
        ),
    ], blink: nil, ambient: .init(drift: 1, saccade: 0, shake: 4, shakeRate: 6, bob: 2.2, bobRate: 3, hop: true, talk: 0.25))

    private static let celebratingScript: HeadScript = {
        let delighted = eye(width: 22, height: 42, smile: 0.7)
        let cheer = mouth(width: 28, curve: 1, open: 0.55)
        return HeadScript(steps: [
            Step(pose: .face(pitch: 12, roll: 8, eye: delighted, mouth: cheer), hold: 0.45, transition: 0.2),
            Step(pose: .face(pitch: 12, roll: -8, eye: delighted, mouth: cheer), hold: 0.45, transition: 0.2),
        ], blink: nil, ambient: .init(drift: 0.5, saccade: 0, bob: 4, bobRate: 2.2, hop: true))
    }()

    private static let curiousScript: HeadScript = {
        let ooh = mouth(x: 3, width: 9, curve: 0, open: 0.24)
        return HeadScript(steps: [
            Step(
                pose: .face(
                    pitch: 5, yaw: 10, roll: 13, look: (3, 2),
                    eye: eye(width: 20, height: 49), right: eye(height: 40, lid: 0.1).mirrored, mouth: ooh
                ),
                hold: 2.4
            ),
            Step(
                pose: .face(
                    pitch: 4, yaw: 6, roll: 10, look: (2, 1),
                    eye: eye(width: 20, height: 48), right: eye(height: 41, lid: 0.08).mirrored,
                    mouth: mouth(x: 2, width: 12, curve: 0.2, skew: 0.3)
                ),
                hold: 1.6, transition: 0.7
            ),
        ], ambient: .init(drift: 1.5, saccade: 1.2))
    }()

    private static let surprisedScript = HeadScript(steps: [
        Step(
            pose: .face(pitch: 9, eye: eye(y: 9, width: 25, height: 52),
                        mouth: mouth(y: -43, width: 15, curve: 0, open: 0.5)),
            hold: 1, transition: 0.18
        ),
    ], blink: .init(minInterval: 4, maxInterval: 7), ambient: .init(drift: 1, saccade: 1.4))

    private static let skepticalScript = HeadScript(steps: [
        Step(
            pose: .face(
                yaw: -12, roll: -6, look: (-3, 0),
                eye: eye(height: 46), right: eye(height: 42, lid: 0.48, slant: -0.1).mirrored,
                mouth: mouth(x: 2, width: 17, curve: 0, skew: -0.75)
            ),
            hold: 1
        ),
    ], ambient: .init(drift: 1.2, saccade: 0.8))

    private static let suspiciousScript: HeadScript = {
        let narrowed = eye(width: 22, lid: 0.5, slant: 0.15)
        return HeadScript(steps: [
            Step(pose: .face(yaw: 18, look: (7, 0), eye: narrowed, mouth: mouth(x: 3, width: 14, curve: -0.2, skew: 0.3)),
                 hold: 1.6, transition: 0.7),
            Step(pose: .face(yaw: -14, look: (-7, 0), eye: narrowed, mouth: mouth(x: -3, width: 14, curve: -0.2, skew: -0.3)),
                 hold: 1.6, transition: 0.7),
        ], blink: .init(minInterval: 3.5, maxInterval: 6), ambient: .init(drift: 0.8, saccade: 0.4))
    }()

    private static let confusedScript: HeadScript = {
        let big = eye(height: 48, tilt: -6)
        let small = eye(height: 34, tilt: 12, lid: 0.2)
        let squiggle = mouth(width: 20, curve: -0.1, wave: 1)
        return HeadScript(steps: [
            Step(pose: .face(yaw: -8, roll: -13, eye: big, right: small.mirrored, mouth: squiggle), hold: 1.8, transition: 0.6),
            Step(pose: .face(yaw: 8, roll: 11, eye: small, right: big.mirrored, mouth: squiggle), hold: 1.8, transition: 0.6),
        ], ambient: .init(drift: 1.2, saccade: 1))
    }()

    private static let determinedScript = HeadScript(steps: [
        Step(
            pose: .face(pitch: -5, eye: eye(width: 20, height: 42, lid: 0.32, slant: 0.5),
                        mouth: mouth(width: 17, curve: -0.35)),
            hold: 1
        ),
    ], blink: .init(minInterval: 3.5, maxInterval: 6.5), ambient: .init(drift: 0.8, saccade: 0.5))

    private static let proudScript = HeadScript(steps: [
        Step(
            pose: .face(pitch: 14, roll: -3, eye: eye(width: 21, height: 30, smile: 0.4, bend: 0.12),
                        mouth: mouth(width: 22, curve: 0.6, skew: 0.35)),
            hold: 1
        ),
    ], ambient: .init(drift: 1.2, saccade: 0.4))

    private static let winkScript = HeadScript(steps: [
        Step(
            pose: .face(
                pitch: 5, roll: 9, eye: eye(smile: 0.45),
                right: eye(width: 21, open: 0, bend: 0.2).mirrored,
                mouth: mouth(x: 2, width: 22, curve: 0.75, open: 0.1, skew: 0.45)
            ),
            hold: 1.4, transition: 0.2
        ),
        Step(pose: .face(pitch: 4, roll: 5, eye: eye(smile: 0.35), mouth: mouth(width: 20, curve: 0.55)),
             hold: 1.8, transition: 0.3),
    ], blink: nil, ambient: .init(drift: 1, saccade: 0.6))

    private static let shyScript: HeadScript = {
        let bashful = eye(width: 17, height: 38, smile: 0.35)
        return HeadScript(steps: [
            Step(pose: .face(pitch: -14, yaw: 20, roll: 9, look: (6, -3), eye: bashful,
                             mouth: mouth(x: 3, width: 9, curve: 0.45)), hold: 2.2),
            Step(pose: .face(pitch: -6, yaw: 6, roll: 6, look: (1, 0), eye: bashful,
                             mouth: mouth(x: 1, width: 12, curve: 0.55)), hold: 0.8, transition: 0.4),
        ], ambient: .init(drift: 1, saccade: 0.6))
    }()

    private static let sleepyScript: HeadScript = {
        let heavy = eye(width: 22, height: 40, lid: 0.6)
        let slack = mouth(width: 11, curve: -0.1, open: 0.08)
        return HeadScript(steps: [
            Step(pose: .face(pitch: -10, roll: 4, eye: heavy, mouth: slack), hold: 3.2),
            // A yawn: eyes squeeze shut, jaw drops, head tips back.
            Step(
                pose: .face(pitch: 6, roll: 2, eye: eye(width: 22, open: 0, bend: 0.1),
                            mouth: mouth(y: -42, width: 13, curve: 0, open: 0.75)),
                hold: 0.9, transition: 0.6
            ),
            Step(pose: .face(pitch: -10, roll: 4, eye: heavy, mouth: slack), hold: 2.4, transition: 0.8),
        ], blink: .init(minInterval: 2.5, maxInterval: 4.5, duration: 0.45, doubleChance: 0),
           ambient: .init(drift: 3, saccade: 0.3, bob: 0.8, bobRate: 0.3))
    }()

    private static let sadScript = HeadScript(steps: [
        Step(
            pose: .face(pitch: -14, roll: -4, eye: eye(y: 2, height: 40, lid: 0.22, slant: -0.55),
                        mouth: mouth(y: -43, width: 17, curve: -0.8)),
            hold: 1
        ),
    ], blink: .init(minInterval: 3, maxInterval: 6, duration: 0.24), ambient: .init(drift: 1, saccade: 0.4))
}

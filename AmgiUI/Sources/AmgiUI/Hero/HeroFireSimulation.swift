import Foundation

// MARK: - Randomness

/// SplitMix64: small, fast, seedable. Live flames seed it from the system so
/// no two launches burn alike; previews seed it fixed so they hold still.
struct HeroRandom: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Smooth random noise: random values on a lattice, eased between, so motion
/// wanders without ever repeating the way summed sines do.
struct HeroNoise: Sendable {
    private let values: [Double]

    init<G: RandomNumberGenerator>(using rng: inout G) {
        values = (0..<256).map { _ in Double.random(in: -1...1, using: &rng) }
    }

    /// −1…1.
    func callAsFunction(_ x: Double) -> Double {
        let floor = x.rounded(.down)
        let i = Int(floor) & 255
        let u = x - floor
        let eased = u * u * (3 - 2 * u)
        return values[i] + (values[(i + 1) & 255] - values[i]) * eased
    }

    /// Broad motion with finer flutter on top. Roughly −1…1.
    func fbm(_ x: Double) -> Double {
        0.6 * self(x) + 0.3 * self(x * 2.13 + 17.3) + 0.1 * self(x * 4.71 + 41.9)
    }
}

// MARK: - Simulation

/// One spark, in points relative to the flame's tip.
struct HeroSpark: Sendable {
    var x: Double
    var y: Double
    var vx: Double
    var vy: Double
    var age: Double
    var life: Double
    var size: Double
    var seed: Double
}

/// Everything the flame, its light and its sparks need for one frame.
struct HeroFireFrame: Sendable {
    var t: Double
    var noise: HeroNoise
    /// Signed: positive blows left → right, negative right → left, ~0 calm.
    var wind: Double
    /// How far the flame's root and tip lean. The tip lags the root and
    /// overshoots it, which is what makes a change of wind whip through.
    var baseLean: Double
    var tipLean: Double
    /// ~1: the flame's height, breathing and fluttering.
    var height: Double
    /// ~1: the strength of the light it throws, low-passed so it never flickers.
    var glow: Double
    /// Where that light pools, trailing the flame.
    var glowLean: Double
    /// 1 at a tap, easing to 0.
    var burst: Double
    var sparks: [HeroSpark]
}

/// A small, stateful fire: wind with a mind of its own, a flame that answers
/// it through springs, and sparks with momentum.
///
/// The wind picks a new target every one to five seconds — a calm spell, a
/// breeze from either side, now and then a hard gust — and eases towards it
/// on a soft spring, with turbulence on top. The flame's root follows the
/// wind briskly; its tip follows the root on a looser, underdamped spring,
/// so a reversal sweeps the flame upright and over rather than flipping it.
/// Sparks are particles: launched from the tip, pushed by the same wind,
/// lifted by heat that fades as they cool, jostled by turbulence and slowed
/// by drag — so they rise in still air, stream with a breeze and curve when
/// it turns.
///
/// Not observable on purpose: it advances from inside `TimelineView`
/// closures, and mutating it must not invalidate any view.
@MainActor
final class HeroFireSimulation {
    /// Sparks per second, set by the background from the chip's mood.
    var sparkRate = 5.0

    private var rng: HeroRandom
    private let noise: HeroNoise
    private var t = 0.0
    private var lastDate: Date?

    private var wind = 0.0
    private var windVelocity = 0.0
    private var target = 0.0
    private var hold = 0.0
    private var gusty = 0.0
    private var baseLean = 0.0
    private var baseVelocity = 0.0
    private var tipLean = 0.0
    private var tipVelocity = 0.0
    private var glow = 1.0
    private var glowLean = 0.0
    private var sparks: [HeroSpark] = []
    private var spawnDebt = 0.0
    private var flaredAt: Double?

    init(seed: UInt64? = nil) {
        var rng = HeroRandom(state: seed ?? UInt64.random(in: 0...UInt64.max))
        noise = HeroNoise(using: &rng)
        self.rng = rng
        // Start mid-scene rather than dead calm with no sparks.
        for _ in 0..<120 { step(1.0 / 60) }
    }

    /// Steps to `date` and returns the frame. The emblem and the background
    /// both ask each frame; the second ask for the same moment is free.
    func advance(to date: Date) -> HeroFireFrame {
        if let lastDate {
            let dt = date.timeIntervalSince(lastDate)
            if dt > 0 {
                // After a pause (scrolled away, backgrounded) resume gently
                // instead of fast-forwarding.
                var remaining = min(dt, 0.1)
                while remaining > 0 {
                    let slice = min(remaining, 1.0 / 60)
                    step(slice)
                    remaining -= slice
                }
                self.lastDate = date
            }
        } else {
            lastDate = date
        }
        return frame
    }

    /// Runs the fire forward without a clock, for previews and snapshots.
    func prewarm(_ seconds: Double) {
        var elapsed = 0.0
        while elapsed < seconds {
            step(1.0 / 60)
            elapsed += 1.0 / 60
        }
    }

    /// A tap: the flame flares and throws a spray of sparks.
    func flare() {
        flaredAt = t
        for _ in 0..<14 {
            sparks.append(HeroSpark(
                x: tipLean * 3 + random(-2, 2),
                y: random(-1, 1),
                vx: gusty * 34 + random(-26, 26),
                vy: -random(16, 42),
                age: 0,
                life: random(0.8, 1.6),
                size: random(0.9, 1.6),
                seed: random(0, 200)
            ))
        }
    }

    var frame: HeroFireFrame {
        let burst = flaredAt.map { start -> Double in
            let p = (t - start) / 1.1
            return p < 1 ? (1 - p) * (1 - p) : 0
        } ?? 0
        let flutter = 0.07 * noise.fbm(t * 2.6) + 0.035 * noise(t * 7.5 + 2)
        return HeroFireFrame(
            t: t,
            noise: noise,
            wind: gusty,
            baseLean: baseLean,
            tipLean: tipLean,
            height: 1 + flutter - 0.12 * min(abs(tipLean), 1),
            glow: glow,
            glowLean: glowLean,
            burst: burst,
            sparks: sparks
        )
    }

    // MARK: Stepping

    private func step(_ dt: Double) {
        t += dt

        hold -= dt
        if hold <= 0 {
            target = nextTarget()
            hold = random(1.2, 4.8)
        }
        spring(&wind, &windVelocity, toward: target, stiffness: 2.2, damping: 0.85, dt: dt)
        gusty = wind + noise.fbm(t * 0.9 + 3) * (0.08 + 0.18 * abs(wind))

        spring(&baseLean, &baseVelocity, toward: gusty, stiffness: 20, damping: 1, dt: dt)
        spring(&tipLean, &tipVelocity, toward: baseLean * 1.15, stiffness: 7, damping: 0.42, dt: dt)

        let glowTarget = 1 + 0.06 * noise(t * 0.45 + 9)
        glow += (glowTarget - glow) * min(1, dt * 1.5)
        glowLean += (tipLean - glowLean) * min(1, dt * 1.2)

        // Sparks come in fits, not on a metronome.
        spawnDebt += sparkRate * dt * max(0, 0.7 + 0.9 * noise(t * 1.7 + 5))
        while spawnDebt >= 1 {
            spawnDebt -= 1
            sparks.append(HeroSpark(
                x: tipLean * 3 + random(-1.5, 1.5),
                y: random(-1, 1),
                vx: gusty * 20 + random(-6, 6),
                vy: -random(6, 16),
                age: 0,
                life: random(1, 2.4),
                size: random(0.5, 1.2),
                seed: random(0, 200)
            ))
        }

        let airX = gusty * 34
        for i in sparks.indices {
            var s = sparks[i]
            s.age += dt
            let cooling = max(0, 1 - s.age / s.life)
            let turbulenceX = noise(s.seed + s.age * 2.3) * 14
            let turbulenceY = noise(s.seed + 50 + s.age * 2.3) * 10
            let liftY = -(2 + 14 * cooling)
            let drag = min(1, dt * 2.5)
            s.vx += (airX + turbulenceX - s.vx) * drag
            s.vy += (liftY + turbulenceY - s.vy) * drag
            s.x += s.vx * dt
            s.y += s.vy * dt
            sparks[i] = s
        }
        sparks.removeAll { $0.age >= $0.life }
        if sparks.count > 70 { sparks.removeFirst(sparks.count - 70) }
    }

    /// Calm a quarter of the time, a breeze most of the time, a hard gust
    /// now and then — usually from the same side as before, sometimes not.
    private func nextTarget() -> Double {
        let previousSide: Double = target >= 0 ? 1 : -1
        let side = random(0, 1) < 0.6 ? previousSide : -previousSide
        let roll = random(0, 1)
        if roll < 0.25 { return random(-0.06, 0.06) }
        if roll < 0.85 { return side * random(0.2, 0.55) }
        return side * random(0.65, 0.95)
    }

    private func spring(
        _ value: inout Double, _ velocity: inout Double,
        toward goal: Double, stiffness: Double, damping: Double, dt: Double
    ) {
        let c = 2 * stiffness.squareRoot() * damping
        velocity += (stiffness * (goal - value) - c * velocity) * dt
        value += velocity * dt
    }

    private func random(_ low: Double, _ high: Double) -> Double {
        Double.random(in: low...high, using: &rng)
    }
}

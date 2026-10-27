import SwiftUI
import AmgiTheme

// MARK: - Mood

/// What the streak chip feels like. A live streak burns, an at-risk one
/// smoulders, and a lapsed or never-started one rests in frost.
enum HeroStreakMood: Equatable {
    case blaze
    case smoulder
    case frost

    init(_ state: HeroStreakSummary.State) {
        switch state {
        case .active, .milestone: self = .blaze
        case .atRisk: self = .smoulder
        case .lapsed, .fresh: self = .frost
        }
    }
}

/// Clock helpers for the frost scene and the tap burst. The fire has its
/// own stateful simulation (`HeroFireSimulation`).
enum HeroStreakMotion {
    /// Seconds, wrapped so the trig below keeps its precision.
    static func time(_ date: Date) -> Double {
        date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600)
    }

    /// 1 at the moment of a tap, easing out to 0 over `duration`.
    static func burst(since tap: Date?, at date: Date, duration: Double = 1.1) -> Double {
        guard let tap else { return 0 }
        let progress = date.timeIntervalSince(tap) / duration
        guard progress >= 0, progress < 1 else { return 0 }
        return (1 - progress) * (1 - progress)
    }
    /// A gust accelerates the snow from its current position, then dies away.
    static func gust(since tap: Date?, at date: Date) -> Double {
        guard let tap else { return 0 }
        let elapsed = max(0, date.timeIntervalSince(tap))
        return elapsed * exp(-elapsed * 1.8) * 42
    }

    static func random(_ index: Int, _ salt: Int) -> Double {
        let value = sin(Double(index) * 127.1 + Double(salt) * 311.7) * 43758.5453
        return value - value.rounded(.down)
    }

}

// MARK: - Flame

/// A procedural vector flame. No symbol: each layer is a teardrop traced
/// along a spine whose lean blends from the root's to the tip's
/// (`HeroFireSimulation`), so when the wind turns the root swings first and
/// the tip whips after it. Smooth random noise travels up the spine and both
/// edges, so the licks never repeat. The upwind edge is pressed flat and the
/// downwind edge billows; with no wind it stands upright and both sides lick
/// alike. A side tongue on each flank licks up and falls back on its own
/// rhythm and leans further than the body, so the crown splits and rejoins;
/// now and then a wisp tears off the tip and burns out wherever the air takes it.
///
/// Layers, back to front: a blurred halo (its own light), the deep outer body
/// fading to nothing at its tips, a blue tint at the root where fuel meets
/// air, an amber mid flame, and a pale-gold core that bends least.
struct HeroFlameRenderer {
    var frame: HeroFireFrame
    /// 1 for a healthy flame; lower is weaker, shorter and more at the wind's mercy.
    var vigor: Double = 1
    var isDark: Bool
    var warm: Color
    var hot: Color
    var cool: Color

    private var t: Double { frame.t }
    private var noise: HeroNoise { frame.noise }

    /// Draws the flame with its root at the bottom-centre of `box`. The flame
    /// leans and its wisps travel beyond `box`, so the context should have
    /// room around it.
    func draw(_ gc: inout GraphicsContext, box: CGRect) {
        let burst = frame.burst
        let sputter = vigor < 1 ? 0.14 * max(0, noise(t * 0.8 + 61)) : 0
        let height = box.height * (0.8 + 0.2 * vigor) * (frame.height - sputter + 0.2 * burst)
        let width = box.width * 0.66 * (0.85 + 0.15 * vigor)
        // A weaker flame bends further for the same wind.
        let give = 0.85 + 0.2 * (1 - vigor)
        let baseLean = frame.baseLean * give
        let tipLean = frame.tipLean * give
        let root = CGPoint(x: box.midX - baseLean * width * 0.12, y: box.maxY - box.height * 0.02)

        var light = gc
        light.blendMode = isDark ? .plusLighter : .normal

        // The body: the main flame and a tongue on each flank. A tongue on
        // the downwind side reaches higher; with no wind both lick alike.
        let main = layer(root: root, height: height, width: width, base: baseLean, tip: tipLean, lick: 1, seed: 0)
        var outer = main.path
        for side in [-1.0, 1.0] {
            let downwind = side * max(-1, min(1, tipLean * 2.2))
            let licking = 0.5 + 0.5 * noise(t * 1.9 + side * 13)
            let tongueHeight = height * (0.38 + 0.3 * licking) * (1 + 0.35 * downwind) * (side < 0 ? 1 : vigor.squareRoot())
            let tongue = layer(
                root: CGPoint(x: root.x + side * width * 0.17, y: root.y - height * 0.32),
                height: max(0, tongueHeight), width: width * 0.36,
                base: baseLean * 1.4 + side * 0.1, tip: tipLean * 1.8 + side * 0.14,
                lick: 1.4, seed: 5.3 + side * 3.6
            )
            outer.addPath(tongue.path)
        }

        // Halo: the flame's own light, steady, carried a little with the lean.
        var halo = light
        halo.addFilter(.blur(radius: width * 0.5))
        halo.translateBy(x: frame.glowLean * width * 0.25, y: 0)
        halo.fill(main.path, with: .color(warm.mix(with: hot, by: 0.4).opacity((isDark ? 0.7 : 0.48) * vigor * frame.glow + 0.3 * burst)))

        // Outer body: deep orange at the root, red in the tongues, gone at the tips.
        var body = light
        body.addFilter(.blur(radius: width * 0.025))
        body.fill(outer, with: .linearGradient(
            Gradient(stops: [
                .init(color: warm.mix(with: hot, by: 0.3), location: 0),
                .init(color: hot.mix(with: warm, by: 0.3), location: 0.42),
                .init(color: hot.opacity(0.8), location: 0.72),
                .init(color: hot.opacity(0), location: 1),
            ]),
            startPoint: root, endPoint: main.tip
        ))

        // A wisp torn from the tip now and then, burning out wherever the air
        // takes it — upward in still air.
        let cycle = t / 0.9
        let phase = cycle - cycle.rounded(.down)
        if noise(cycle.rounded(.down) * 0.73 + 77) > 0.15 - burst - 0.3 * (1 - vigor) {
            let fade = pow(sin(.pi * phase), 1.2)
            let wispHeight = height * 0.3 * (1 - 0.5 * phase)
            let at = CGPoint(
                x: main.tip.x + phase * width * tipLean * 1.3,
                y: main.tip.y + wispHeight * 0.9 - phase * height * (0.4 - 0.15 * min(abs(tipLean), 1))
            )
            let wisp = layer(
                root: at, height: wispHeight, width: width * 0.16 * (1 - 0.4 * phase),
                base: tipLean * 2, tip: tipLean * 2.4, lick: 0.8, seed: 2.2
            )
            body.fill(wisp.path, with: .linearGradient(
                Gradient(colors: [hot.opacity(0.7 * fade), hot.opacity(0)]),
                startPoint: at, endPoint: wisp.tip
            ))
        }

        // Blue at the root, where the fuel meets the air.
        var base = gc
        base.clip(to: main.path)
        base.fill(main.path, with: .radialGradient(
            Gradient(colors: [cool.opacity(isDark ? 0.75 : 0.15), cool.opacity(0)]),
            center: CGPoint(x: root.x, y: root.y + height * 0.02), startRadius: 0, endRadius: width * 0.42
        ))

        // Mid flame: the amber body.
        let midRoot = CGPoint(x: root.x, y: root.y - height * 0.04)
        let mid = layer(root: midRoot, height: height * 0.7, width: width * 0.66, base: baseLean * 0.85, tip: tipLean * 0.85, lick: 0.9, seed: 1.7)
        light.fill(mid.path, with: .linearGradient(
            Gradient(stops: [
                .init(color: warm.mix(with: .white, by: isDark ? 0.2 : 0.1), location: 0),
                .init(color: warm, location: 0.55),
                .init(color: warm.mix(with: hot, by: 0.5).opacity(0), location: 1),
            ]),
            startPoint: midRoot, endPoint: mid.tip
        ))

        // Core: stiffest, bends least, hottest just above the root.
        let coreRoot = CGPoint(x: root.x, y: root.y - height * 0.08)
        let core = layer(
            root: coreRoot, height: height * 0.44 * (0.7 + 0.3 * vigor), width: width * 0.4,
            base: baseLean * 0.5, tip: tipLean * 0.5, lick: 0.5, seed: 3.1
        )
        var coreGC = light
        coreGC.addFilter(.blur(radius: width * 0.05))
        // Gold-white whatever the theme's warning hue: that is what burns hottest.
        let coreColor = warm.mix(with: .yellow, by: 0.6).mix(with: .white, by: isDark ? 0.7 : 0.25)
        coreGC.fill(core.path, with: .linearGradient(
            Gradient(stops: [
                .init(color: coreColor, location: 0),
                .init(color: coreColor.opacity(0.9), location: 0.5),
                .init(color: coreColor.opacity(0), location: 1),
            ]),
            startPoint: coreRoot, endPoint: core.tip
        ))
    }

    /// One teardrop layer, leaning `base` at its root and `tip` at its tip.
    /// `lick` scales how much its spine and edges wander.
    private func layer(
        root: CGPoint, height: Double, width: Double, base: Double, tip lean: Double, lick: Double, seed: Double
    ) -> (path: Path, tip: CGPoint) {
        let samples = 36
        var left: [CGPoint] = []
        var right: [CGPoint] = []
        left.reserveCapacity(samples + 1)
        right.reserveCapacity(samples + 1)
        var tip = root
        for i in 0...samples {
            // Denser near the root, so the base stays round.
            let u = Double(i) / Double(samples)
            let s = u * u * (1.6 - 0.6 * u)
            // The spine: the lean blends from root to tip and bends it most
            // at the top; turbulence travels up it.
            let localLean = base + (lean - base) * s
            let bend = localLean * pow(s, 1.8) * height * 0.62
            let wave = noise.fbm(s * 2.2 - t * 2.1 + seed * 11) * pow(s, 1.5) * width * 0.18 * lick
            let x = root.x + bend + wave
            let y = root.y - s * height
            // Round belly low down, a long neck drawn to a point at the tip.
            let profile = pow(sin(.pi * pow(s, 0.5)), 1.3)
            let ripple = 1 + 0.18 * s * noise(s * 3.5 - t * 2.8 + seed * 7) * lick
            let half = width / 2 * profile * ripple
            // Pressed flat upwind, billowing downwind.
            let squeeze = min(abs(localLean), 1.3) * s
            let upwind = half * (1 - 0.34 * squeeze)
            let downwind = half * (1 + 0.22 * squeeze)
            let (leftHalf, rightHalf) = localLean >= 0 ? (upwind, downwind) : (downwind, upwind)
            left.append(CGPoint(x: x - leftHalf, y: y))
            right.append(CGPoint(x: x + rightHalf, y: y))
            if i == samples { tip = CGPoint(x: x, y: y) }
        }
        let outline = left.reversed() + right.dropFirst()
        var path = Path()
        func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
        path.move(to: outline[0])
        for i in 1..<(outline.count - 1) {
            path.addQuadCurve(to: mid(outline[i], outline[i + 1]), control: outline[i])
        }
        path.addLine(to: outline[outline.count - 1])
        path.closeSubpath()
        return (path, tip)
    }
}

// MARK: - Frost

/// A snow crystal suspended in moving air. Six branching arms turn through
/// a shallow perspective as the crystal flutters; its edges catch different
/// light as it turns. The geometry reads at the chip's actual size.
struct HeroFrostRenderer {
    var t: Double
    var burst: Double
    var gust: Double = 0
    var isDark: Bool
    var frost: Color

    func draw(_ gc: inout GraphicsContext, box: CGRect) {
        let radius = min(box.width, box.height) * 0.47
        let center = CGPoint(
            x: box.midX + sin(t * 1.3) * radius * 0.13 + gust * 0.08,
            y: box.midY + sin(t * 1.7 + 0.8) * radius * 0.09
        )
        var crystal = gc
        crystal.translateBy(x: center.x, y: center.y)
        crystal.rotate(by: .radians(t * 0.24 + sin(t * 0.9) * 0.22 + gust * 0.015))
        crystal.scaleBy(x: 0.78 + 0.2 * sin(t * 0.8), y: 1)
        crystal.translateBy(x: -center.x, y: -center.y)
        let light = frost.mix(with: .white, by: isDark ? 0.55 : 0.12)
        let shimmer = 0.84 + 0.08 * sin(t * 0.65)
        var branches = Path()

        func point(_ along: Double, _ across: Double, angle: Double) -> CGPoint {
            CGPoint(
                x: center.x + radius * (cos(angle) * along - sin(angle) * across),
                y: center.y + radius * (sin(angle) * along + cos(angle) * across)
            )
        }
        for arm in 0..<6 {
            let angle = Double(arm) * .pi / 3 - .pi / 2
            branches.move(to: center)
            branches.addLine(to: point(1, 0, angle: angle))
            for (along, length) in [(0.45, 0.24), (0.72, 0.18)] {
                for side in [-1.0, 1.0] {
                    branches.move(to: point(along, 0, angle: angle))
                    branches.addLine(to: point(along + length, side * length * 0.8, angle: angle))
                }
            }
        }

        var halo = crystal
        halo.addFilter(.blur(radius: radius * 0.22))
        halo.stroke(branches, with: .color(frost.opacity(0.22 + burst * 0.12)), lineWidth: radius * 0.3)
        crystal.stroke(
            branches,
            with: .linearGradient(
                Gradient(colors: [light.opacity(shimmer), frost.opacity(0.85), light.opacity(shimmer)]),
                startPoint: CGPoint(x: box.minX, y: box.minY),
                endPoint: CGPoint(x: box.maxX, y: box.maxY)
            ),
            style: StrokeStyle(lineWidth: max(0.8, radius * 0.12), lineCap: .round, lineJoin: .round)
        )
    }
}

// MARK: - Background

/// Light and airborne particles share the emblem's movement: hot embers
/// follow the flame's air current; snow falls in three depths with drift,
/// flutter, and a continuous gust response on tap.
struct HeroStreakAmbience: View {
    let mood: HeroStreakMood
    let fire: HeroFireSimulation
    var milestone = false
    /// The last tap, for the passing gust and a lift in the frost light.
    var tap: Date?
    /// Where the flame stands in the chip.
    var source = UnitPoint(x: 0.12, y: 0.3)
    /// Fixed time for previews and snapshots; nil runs live.
    var stillTime: Double?

    @Environment(\.palette) private var palette
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.redactionReasons) private var redactionReasons
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        if redactionReasons.isEmpty {
            let still = reduceMotion || stillTime != nil || scenePhase != .active
            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: still)) { context in
                let t = stillTime ?? (reduceMotion ? 0 : HeroStreakMotion.time(context.date))
                let burst = still ? 0 : HeroStreakMotion.burst(since: tap, at: context.date)
                let gust = still ? 0 : HeroStreakMotion.gust(since: tap, at: context.date)
                let frame = still || mood == .frost ? fire.frame : advanced(to: context.date)
                Canvas { gc, size in
                    switch mood {
                    case .blaze, .smoulder: drawFire(&gc, size: size, frame: frame)
                    case .frost: drawFrost(&gc, size: size, t: t, burst: burst, gust: gust)
                    }
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        } else {
            Color.clear
        }
    }

    private func advanced(to date: Date) -> HeroFireFrame {
        fire.sparkRate = mood == .blaze ? (milestone ? 6 : 3) : 1
        return fire.advance(to: date)
    }

    private var isDark: Bool { colorScheme == .dark }

    // MARK: Fire

    private func drawFire(_ gc: inout GraphicsContext, size: CGSize, frame: HeroFireFrame) {
        let rect = CGRect(origin: .zero, size: size)
        let t = frame.t
        let noise = frame.noise
        let live = mood == .blaze
        let heat = (live ? 1.0 : 0.55) * (milestone ? 1.25 : 1)
        let warm = palette.warning
        let hot = palette.danger

        // Wash: two warm gradients cross-fading slowly, so the hue drifts.
        let drift = 0.5 + 0.5 * noise(t * 0.12 + 23)
        gc.fill(Path(rect), with: .linearGradient(
            Gradient(colors: [warm.opacity(0.14 * heat), hot.opacity(0.07 * heat)]),
            startPoint: .zero,
            endPoint: CGPoint(x: size.width, y: size.height)
        ))
        gc.fill(Path(rect), with: .linearGradient(
            Gradient(colors: [hot.opacity(0.12 * heat * drift), warm.opacity(0.05 * heat * drift)]),
            startPoint: CGPoint(x: 0, y: size.height),
            endPoint: CGPoint(x: size.width, y: 0)
        ))

        var light = gc
        light.blendMode = isDark ? .plusLighter : .normal

        // The flame's light: no flicker — a slow swell and fade, pooling a
        // little to whichever side the flame leans.
        let center = CGPoint(x: source.x * size.width, y: source.y * size.height)
        let lean = frame.glowLean
        let reach = max(size.width, size.height) * 0.64 * frame.glow * (live ? 1 : 0.72) * (1 + 0.3 * frame.burst)
        let core = (isDark ? 0.42 : 0.3) * heat * frame.glow + 0.25 * frame.burst
        var lamp = light
        lamp.translateBy(x: center.x + lean * reach * 0.14, y: center.y)
        lamp.scaleBy(x: 1.25 + 0.3 * min(abs(lean), 1), y: 1)
        lamp.fill(Path(ellipseIn: CGRect(x: -reach, y: -reach, width: reach * 2, height: reach * 2)), with: .radialGradient(
            Gradient(stops: [
                .init(color: warm.mix(with: .white, by: 0.35).opacity(core), location: 0),
                .init(color: warm.opacity(core * 0.55), location: 0.18),
                .init(color: hot.opacity(core * 0.16), location: 0.55),
                .init(color: hot.opacity(0), location: 1),
            ]),
            center: .zero, startRadius: 0, endRadius: reach
        ))

        // A slow pool of heat along the bottom edge.
        let pool = CGPoint(x: size.width * (0.5 + 0.35 * noise(t * 0.07 + 31)), y: size.height * 1.05)
        light.fill(Path(rect), with: .radialGradient(
            Gradient(colors: [hot.opacity(0.14 * heat), hot.opacity(0)]),
            center: pool, startRadius: 0, endRadius: size.width * 0.5
        ))

        // Sparks, cooling from white-gold to ember red, streaked along their
        // own velocity.
        let tip = CGPoint(x: center.x + frame.tipLean * 6, y: center.y - 9)
        for spark in frame.sparks {
            let p = spark.age / spark.life
            let x = tip.x + spark.x
            let y = tip.y + spark.y
            let alpha = min(1, p * 10) * pow(1 - p, 1.2) * (live ? 1 : 0.65)
            let width = spark.size * 0.7 * (1 - 0.5 * p)
            let color = warm.mix(with: .white, by: 0.55 * (1 - p)).mix(with: hot, by: p * 0.8)
            var trail = Path()
            trail.move(to: CGPoint(x: x - spark.vx * 0.03, y: y - spark.vy * 0.03))
            trail.addLine(to: CGPoint(x: x, y: y))
            light.stroke(trail, with: .color(color.opacity(alpha * 0.35)), style: StrokeStyle(lineWidth: width * 3, lineCap: .round))
            light.stroke(trail, with: .color(color.opacity(alpha)), style: StrokeStyle(lineWidth: width, lineCap: .round))
        }
    }

    private func drawFrost(_ gc: inout GraphicsContext, size: CGSize, t: Double, burst: Double, gust: Double) {
        let rect = CGRect(origin: .zero, size: size)
        let frost = palette.info
        gc.fill(Path(rect), with: .linearGradient(
            Gradient(colors: [frost.opacity(isDark ? 0.18 : 0.12), frost.opacity(0.02)]),
            startPoint: .zero, endPoint: CGPoint(x: size.width, y: size.height)
        ))
        let center = CGPoint(x: source.x * size.width, y: source.y * size.height)
        let glow = (isDark ? 0.12 : 0.09) * (0.9 + 0.1 * sin(t * 0.65)) + 0.06 * burst
        gc.fill(Path(rect), with: .radialGradient(
            Gradient(colors: [frost.opacity(glow), frost.opacity(0)]),
            center: center, startRadius: 0, endRadius: max(size.width, size.height) * 0.7
        ))

        // Depth controls speed, scale, and focus. Flakes enter and leave
        // outside the clip; no particle teleports across the visible chip.
        for index in 0..<16 {
            let depth = HeroStreakMotion.random(index, 11)
            let seed = HeroStreakMotion.random(index, 12)
            let speed = 0.06 + depth * 0.10
            let phase = (t * speed + seed).truncatingRemainder(dividingBy: 1)
            let y = -8 + phase * (size.height + 16)
            let wind = sin(t * 0.42 + seed * 6) * (3 + depth * 6)
            let flutter = sin(t * (0.9 + depth) + seed * 15) * (1 + depth * 2)
            let x = HeroStreakMotion.random(index, 13) * size.width + wind + flutter + gust * (0.4 + depth * 0.6)
            let fade = min(1, phase * 8) * min(1, (1 - phase) * 8)
            let radius = 0.4 + depth * 0.9
            var snow = gc
            snow.opacity = fade * (0.3 + depth * 0.4)
            let color = isDark ? Color.white : frost.mix(with: .white, by: 0.25)
            if depth > 0.72 {
                // A few near crystals tumble through a changing perspective.
                snow.translateBy(x: x, y: y)
                snow.rotate(by: .radians(t * (0.25 + seed * 0.4) + seed * 6))
                snow.scaleBy(x: 0.65 + 0.3 * sin(t * 1.1 + seed * 9), y: 1)
                var flake = Path()
                for arm in 0..<3 {
                    let angle = Double(arm) * .pi / 3
                    flake.move(to: CGPoint(x: -cos(angle) * radius * 1.8, y: -sin(angle) * radius * 1.8))
                    flake.addLine(to: CGPoint(x: cos(angle) * radius * 1.8, y: sin(angle) * radius * 1.8))
                }
                snow.stroke(flake, with: .color(color), style: StrokeStyle(lineWidth: 0.65, lineCap: .round))
            } else {
                snow.addFilter(.blur(radius: 0.3))
                snow.fill(
                    Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)),
                    with: .color(color)
                )
            }
        }
    }
}

// MARK: - Emblem

/// An anchored flame for live streaks, a frost crystal for dormant ones.
/// Flames rise and curl; snow crystals drift and tumble in moving air.
/// Reduce Motion keeps both at a composed frame.
struct HeroStreakEmblem: View {
    let state: HeroStreakSummary.State
    let size: CGFloat
    let fire: HeroFireSimulation
    var tap: Date?
    /// Fixed time for previews and snapshots; nil runs live.
    var stillTime: Double?

    @Environment(\.palette) private var palette
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.redactionReasons) private var redactionReasons
    @Environment(\.scenePhase) private var scenePhase
    @ScaledMetric(relativeTo: .footnote) private var scale: CGFloat = 1

    private var isStill: Bool { reduceMotion || !redactionReasons.isEmpty || stillTime != nil || scenePhase != .active }
    private var side: CGFloat { size * scale }

    var body: some View {
        let mood = HeroStreakMood(state)
        // The layout box is the flame's footprint; the canvas around it is
        // larger so the soft halo is never clipped.
        Color.clear
            .frame(width: side * 1.05, height: side * 1.4)
            .overlay(alignment: .bottom) {
                TimelineView(.animation(minimumInterval: 1.0 / 60, paused: isStill)) { context in
                    switch mood {
                    case .blaze, .smoulder:
                        let frame = isStill ? fire.frame : fire.advance(to: context.date)
                        Canvas { gc, canvas in
                            HeroFlameRenderer(
                                frame: frame,
                                vigor: mood == .blaze ? 1 : 0.6,
                                isDark: colorScheme == .dark,
                                warm: palette.warning,
                                hot: palette.danger,
                                cool: palette.info
                            )
                            .draw(&gc, box: footprint(in: canvas))
                        }
                    case .frost:
                        let t = stillTime ?? (isStill ? 0.6 : HeroStreakMotion.time(context.date))
                        let burst = isStill ? 0 : HeroStreakMotion.burst(since: tap, at: context.date)
                        let gust = isStill ? 0 : HeroStreakMotion.gust(since: tap, at: context.date)
                        Canvas { gc, canvas in
                            HeroFrostRenderer(
                                t: t, burst: burst, gust: gust,
                                isDark: colorScheme == .dark,
                                frost: palette.info
                            )
                            .draw(&gc, box: footprint(in: canvas))
                        }
                    }
                }
                .frame(width: side * 3, height: side * 2.2)
                .allowsHitTesting(false)
            }
            .accessibilityHidden(true)
    }

    /// The layout box, placed bottom-centre in the larger canvas.
    private func footprint(in canvas: CGSize) -> CGRect {
        CGRect(x: (canvas.width - side * 1.05) / 2, y: canvas.height - side * 1.4, width: side * 1.05, height: side * 1.4)
    }
}

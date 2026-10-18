import SwiftUI
import AmgiTheme

// MARK: - Mood

/// What the streak chip feels like. A live streak burns, an at-risk one
/// smoulders, and a lapsed or never-started one is frozen solid.
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

    /// Stable 0…1 pseudo-random value for particle `index`.
    static func random(_ index: Int, _ salt: Int) -> Double {
        let x = sin(Double(index) * 127.1 + Double(salt) * 311.7) * 43758.5453
        return x - x.rounded(.down)
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
        let give = 1.3 - 0.3 * vigor
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
            let fade = (1 - phase) * (1 - phase)
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
        let samples = 26
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
            let wave = noise.fbm(s * 2.2 - t * 2.6 + seed * 11) * pow(s, 1.5) * width * 0.26 * lick
            let x = root.x + bend + wave
            let y = root.y - s * height
            // Round belly low down, a long neck drawn to a point at the tip.
            let profile = pow(sin(.pi * pow(s, 0.5)), 1.3)
            let ripple = 1 + 0.26 * s * noise(s * 3.5 - t * 3.4 + seed * 7) * lick
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

// MARK: - Ice

/// The frozen streak: a block of ice, melting. Drawn as a solid in
/// three-quarter view — a bright top face, the front face, a shaded side
/// face — with edges the melt has softened, air trapped inside and a
/// hairline fracture. The front's bottom edge sags into a lip where drops
/// gather; each drop swells, stretches on its neck, lets go and falls into a
/// puddle that rings when it lands. Meltwater runs down the front, a glint
/// crosses the ice every few seconds, and the block settles a little. A tap
/// warms it: the block shivers and the drops come fat and fast.
struct HeroIceRenderer {
    var t: Double
    var burst: Double
    /// Seconds since the last tap, for the shiver.
    var elapsed: Double
    var isDark: Bool
    var ice: Color

    func draw(_ gc: inout GraphicsContext, box: CGRect) {
        let cube = min(box.width * 0.95, box.height * 0.66)
        let depth = cube * 0.3
        let front = CGRect(
            x: box.midX - (cube + depth) / 2,
            y: box.minY + depth,
            width: cube,
            height: cube * 0.88
        )
        let puddleY = box.maxY - cube * 0.05
        let pale = ice.mix(with: .white, by: 0.72)
        let water = ice.mix(with: .white, by: 0.35)
        let melt = 1 + 1.2 * burst
        let soft = cube * 0.07

        // Cold light thrown around the block.
        var glow = gc
        glow.addFilter(.blur(radius: cube * 0.3))
        glow.fill(Path(front.insetBy(dx: -depth * 0.3, dy: -depth * 0.3)), with: .color(ice.opacity(0.4 + 0.3 * burst)))

        // Puddle spreading from under the block.
        let puddle = CGRect(x: front.minX - cube * 0.12, y: puddleY - cube * 0.08, width: cube * 1.45, height: cube * 0.16)
        gc.fill(Path(ellipseIn: puddle), with: .radialGradient(
            Gradient(colors: [water.opacity(0.65), water.opacity(0)]),
            center: CGPoint(x: puddle.midX, y: puddle.midY), startRadius: 0, endRadius: cube * 0.72
        ))
        gc.fill(
            Path(ellipseIn: puddle.insetBy(dx: cube * 0.34, dy: cube * 0.05).offsetBy(dx: -cube * 0.08, dy: -cube * 0.015)),
            with: .color(.white.opacity(isDark ? 0.35 : 0.6))
        )

        // Drip sites along the front's bottom edge: (x across it, period, offset).
        let sites: [(x: Double, period: Double, offset: Double)] = [(0.28, 2.5, 0.1), (0.7, 3.2, 0.55)]
        func gather(_ site: (x: Double, period: Double, offset: Double)) -> Double {
            let cycle = t / site.period + site.offset
            return cycle - cycle.rounded(.down)
        }
        let hang = 0.64
        let sags = sites.map { site -> Double in
            let p = gather(site)
            let grow = p < hang ? p / hang : max(0, 1 - (p - hang) * 8)
            return cube * (0.03 + 0.045 * grow) * melt
        }
        func sag(at x: Double) -> Double {
            var total = cube * 0.012 * sin(x / cube * 9 + 1)
            for (site, amount) in zip(sites, sags) {
                let dx = (x - (front.minX + site.x * cube)) / (cube * 0.1)
                total += amount * exp(-dx * dx)
            }
            return total
        }

        // The solid settles and, when tapped, shivers about its base.
        var solid = gc
        let tilt = sin(t * 0.9) * 0.03 + sin(elapsed * 42) * 0.12 * burst
        let pivot = CGPoint(x: front.midX, y: front.maxY)
        solid.translateBy(x: pivot.x, y: pivot.y + sin(t * 1.1) * cube * 0.015)
        solid.rotate(by: .radians(tilt))
        solid.translateBy(x: -pivot.x, y: -pivot.y)

        // Faces. Each is filled, then stroked in its own colour with round
        // joins, which rounds every corner the way melting does.
        let back = CGPoint(x: depth, y: -depth)
        var top = Path()
        top.move(to: CGPoint(x: front.minX, y: front.minY))
        top.addLine(to: CGPoint(x: front.maxX, y: front.minY))
        top.addLine(to: CGPoint(x: front.maxX + back.x, y: front.minY + back.y))
        top.addLine(to: CGPoint(x: front.minX + back.x, y: front.minY + back.y))
        top.closeSubpath()

        var side = Path()
        side.move(to: CGPoint(x: front.maxX, y: front.minY))
        side.addLine(to: CGPoint(x: front.maxX + back.x, y: front.minY + back.y))
        side.addLine(to: CGPoint(x: front.maxX + back.x, y: front.maxY + back.y))
        side.addLine(to: CGPoint(x: front.maxX, y: front.maxY + sag(at: front.maxX)))
        side.closeSubpath()

        var face = Path()
        face.move(to: CGPoint(x: front.minX, y: front.minY))
        face.addLine(to: CGPoint(x: front.maxX, y: front.minY))
        face.addLine(to: CGPoint(x: front.maxX, y: front.maxY + sag(at: front.maxX)))
        for k in 1..<16 {
            let x = front.maxX - front.width * Double(k) / 16
            face.addLine(to: CGPoint(x: x, y: front.maxY + sag(at: x)))
        }
        face.addLine(to: CGPoint(x: front.minX, y: front.maxY + sag(at: front.minX)))
        face.closeSubpath()

        let rounded = StrokeStyle(lineWidth: soft, lineCap: .round, lineJoin: .round)
        let sideColor = ice.mix(with: .white, by: 0.2).mix(with: .black, by: isDark ? 0.05 : 0)
        let topColor = ice.mix(with: .white, by: isDark ? 0.85 : 0.7)

        let sideShading = GraphicsContext.Shading.linearGradient(
            Gradient(colors: [sideColor.opacity(0.95), ice.opacity(0.95)]),
            startPoint: CGPoint(x: front.maxX, y: front.minY),
            endPoint: CGPoint(x: front.maxX + back.x, y: front.maxY)
        )
        solid.fill(side, with: sideShading)
        solid.stroke(side, with: sideShading, style: rounded)

        let faceShading = GraphicsContext.Shading.linearGradient(
            Gradient(colors: [pale.opacity(0.97), ice.mix(with: .white, by: 0.4).opacity(0.95)]),
            startPoint: CGPoint(x: front.minX, y: front.minY),
            endPoint: CGPoint(x: front.maxX, y: front.maxY)
        )
        solid.fill(face, with: faceShading)
        solid.stroke(face, with: faceShading, style: rounded)

        solid.fill(top, with: .color(topColor))
        solid.stroke(top, with: .color(topColor), style: rounded)

        // Inside the ice: depth, trapped air, a fracture, meltwater, a glint.
        var inside = solid
        inside.clip(to: face)

        // Refraction: the far faces seen through the front, faintly.
        inside.fill(Path(CGRect(x: front.minX, y: front.minY, width: front.width * 0.5, height: front.height * 1.2)),
                    with: .linearGradient(
                        Gradient(colors: [.white.opacity(0.35), .white.opacity(0)]),
                        startPoint: CGPoint(x: front.minX, y: 0), endPoint: CGPoint(x: front.minX + front.width * 0.5, y: 0)
                    ))
        for b in 0..<5 {
            let bx = front.minX + cube * (0.15 + 0.7 * HeroStreakMotion.random(b, 60))
            let by = front.minY + cube * (0.15 + 0.6 * HeroStreakMotion.random(b, 61))
            let br = cube * (0.018 + 0.025 * HeroStreakMotion.random(b, 62))
            inside.stroke(Path(ellipseIn: CGRect(x: bx - br, y: by - br, width: br * 2, height: br * 2)),
                          with: .color(.white.opacity(0.8)), lineWidth: max(0.4, cube * 0.014))
        }
        var crack = Path()
        crack.move(to: CGPoint(x: front.maxX - cube * 0.1, y: front.minY + cube * 0.08))
        crack.addLine(to: CGPoint(x: front.maxX - cube * 0.24, y: front.minY + cube * 0.26))
        crack.addLine(to: CGPoint(x: front.maxX - cube * 0.18, y: front.minY + cube * 0.38))
        crack.addLine(to: CGPoint(x: front.maxX - cube * 0.3, y: front.minY + cube * 0.55))
        crack.move(to: CGPoint(x: front.maxX - cube * 0.18, y: front.minY + cube * 0.38))
        crack.addLine(to: CGPoint(x: front.maxX - cube * 0.08, y: front.minY + cube * 0.46))
        inside.stroke(crack, with: .color(.white.opacity(0.7)), lineWidth: max(0.4, cube * 0.014))

        // Meltwater running down the front.
        let runCycle = t / 2.2
        let run = runCycle - runCycle.rounded(.down)
        let runX = front.minX + cube * 0.16
        let runY = front.minY + cube * (run * 1.3 - 0.2)
        var rivulet = Path()
        rivulet.move(to: CGPoint(x: runX, y: runY - cube * 0.24))
        rivulet.addQuadCurve(to: CGPoint(x: runX + cube * 0.015, y: runY), control: CGPoint(x: runX - cube * 0.02, y: runY - cube * 0.1))
        inside.stroke(rivulet, with: .linearGradient(
            Gradient(colors: [.white.opacity(0), .white.opacity(0.95)]),
            startPoint: CGPoint(x: runX, y: runY - cube * 0.24), endPoint: CGPoint(x: runX, y: runY)
        ), style: StrokeStyle(lineWidth: max(0.6, cube * 0.04), lineCap: .round))

        // A glint crossing the block every few seconds, over every face.
        var lit = solid
        var whole = face
        whole.addPath(top)
        whole.addPath(side)
        lit.clip(to: whole)
        let glintCycle = t / 3.2
        let glint = (glintCycle - glintCycle.rounded(.down)) * 2.6 - 0.8
        let gx = front.minX + glint * (cube + depth)
        var band = Path()
        band.move(to: CGPoint(x: gx, y: box.minY - cube * 0.1))
        band.addLine(to: CGPoint(x: gx + cube * 0.2, y: box.minY - cube * 0.1))
        band.addLine(to: CGPoint(x: gx - cube * 0.35, y: front.maxY + cube * 0.1))
        band.addLine(to: CGPoint(x: gx - cube * 0.55, y: front.maxY + cube * 0.1))
        band.closeSubpath()
        lit.fill(band, with: .color(.white.opacity(0.5)))

        // Edges catching the light: the front's top edge and the vertical corner.
        var edges = Path()
        edges.move(to: CGPoint(x: front.minX + soft * 0.2, y: front.minY))
        edges.addLine(to: CGPoint(x: front.maxX, y: front.minY))
        edges.addLine(to: CGPoint(x: front.maxX + back.x, y: front.minY + back.y))
        edges.move(to: CGPoint(x: front.maxX, y: front.minY))
        edges.addLine(to: CGPoint(x: front.maxX, y: front.maxY - cube * 0.08))
        solid.stroke(edges, with: .color(.white.opacity(0.95)), style: StrokeStyle(lineWidth: max(0.6, cube * 0.035), lineCap: .round, lineJoin: .round))

        // Drops: swell on the lip, stretch on a neck, let go, fall, ring the puddle.
        for (index, site) in sites.enumerated() {
            let p = gather(site)
            let x = front.minX + site.x * cube
            let lip = front.maxY + sags[index] * 0.7 + soft * 0.4
            let size = cube * 0.08 * (0.8 + 0.35 * melt)
            if p < hang {
                let grow = p / hang
                let radius = size * pow(grow, 0.6)
                let stretch = radius * (0.5 + 1.1 * pow(grow, 3))
                drop(&solid, center: CGPoint(x: x, y: lip + stretch), radius: radius, neckTo: lip - radius * 0.5, water: water)
            } else if p < 0.88 {
                let fall = (p - hang) / (0.88 - hang)
                let startY = lip + size * 1.6
                let y = startY + (puddleY - startY) * fall * fall
                let along = CGRect(x: x - size * 0.75, y: y - size * 1.25, width: size * 1.5, height: size * 2.1)
                gc.fill(Path(ellipseIn: along), with: .color(water.opacity(0.9)))
                gc.fill(Path(ellipseIn: along.insetBy(dx: size * 0.45, dy: size * 0.65).offsetBy(dx: -size * 0.2, dy: -size * 0.3)), with: .color(.white.opacity(0.9)))
            } else {
                let ring = (p - 0.88) / 0.12
                let ringRect = CGRect(
                    x: x - cube * (0.06 + 0.3 * ring), y: puddleY - cube * (0.02 + 0.06 * ring),
                    width: cube * (0.12 + 0.6 * ring), height: cube * (0.04 + 0.12 * ring)
                )
                gc.stroke(Path(ellipseIn: ringRect), with: .color(.white.opacity(0.8 * (1 - ring))), lineWidth: max(0.5, cube * 0.025))
                for s in 0..<3 {
                    let angle = -Double.pi / 2 + Double(s - 1) * 0.7
                    let reach = cube * 0.16 * ring
                    let sx = x + cos(angle) * reach
                    let sy = puddleY + sin(angle) * reach + cube * 0.25 * ring * ring
                    let r = max(0.5, cube * 0.02)
                    gc.fill(Path(ellipseIn: CGRect(x: sx - r, y: sy - r, width: r * 2, height: r * 2)), with: .color(water.opacity(1 - ring)))
                }
            }
        }
    }

    private func drop(_ gc: inout GraphicsContext, center: CGPoint, radius: Double, neckTo top: Double, water: Color) {
        guard radius > 0.2 else { return }
        var path = Path()
        path.move(to: CGPoint(x: center.x - radius * 0.35, y: top))
        path.addQuadCurve(to: CGPoint(x: center.x - radius, y: center.y), control: CGPoint(x: center.x - radius * 0.3, y: center.y - radius * 0.9))
        path.addArc(center: center, radius: radius, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: true)
        path.addQuadCurve(to: CGPoint(x: center.x + radius * 0.35, y: top), control: CGPoint(x: center.x + radius * 0.3, y: center.y - radius * 0.9))
        path.closeSubpath()
        gc.fill(path, with: .color(water.opacity(0.92)))
        gc.fill(
            Path(ellipseIn: CGRect(x: center.x - radius * 0.55, y: center.y - radius * 0.55, width: radius * 0.5, height: radius * 0.6)),
            with: .color(.white.opacity(0.9))
        )
    }
}

// MARK: - Background

/// The chip's living fill. Fire: a warm wash whose hue drifts slowly between
/// amber and ember, the flame's light pooling around it — steady, breathing,
/// trailing its lean — and the sparks of `HeroFireSimulation` cooling from
/// white-gold to red as the air carries them; a gold sweep on milestones.
/// Frost: a winter-blue wash, cold light around the ice, and two depths of
/// snow falling behind the content, blown sideways on tap.
///
/// Colours come from the palette (`warning`, `danger`, `info`), so every
/// theme gets its own fire and ice.
struct HeroStreakAmbience: View {
    let mood: HeroStreakMood
    let fire: HeroFireSimulation
    var milestone = false
    /// The last tap, for the frost gust.
    var tap: Date?
    /// Where the flame stands in the chip.
    var source = UnitPoint(x: 0.12, y: 0.3)
    /// Fixed time for previews and snapshots; nil runs live.
    var stillTime: Double?

    @Environment(\.palette) private var palette
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.redactionReasons) private var redactionReasons

    var body: some View {
        if redactionReasons.isEmpty {
            let still = reduceMotion || stillTime != nil
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: still)) { context in
                let t = stillTime ?? (reduceMotion ? 0 : HeroStreakMotion.time(context.date))
                let burst = HeroStreakMotion.burst(since: tap, at: context.date)
                let frame = still ? fire.frame : advanced(to: context.date)
                Canvas { gc, size in
                    switch mood {
                    case .blaze, .smoulder: drawFire(&gc, size: size, frame: frame)
                    case .frost: drawFrost(&gc, size: size, t: t, burst: burst)
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
        fire.sparkRate = mood == .blaze ? (milestone ? 8 : 5) : 2
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
            Gradient(colors: [warm.opacity(0.18 * heat), hot.opacity(0.07 * heat)]),
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

        // Milestone: a gold sweep every few seconds.
        if milestone {
            let cycle = (t / 3.4).truncatingRemainder(dividingBy: 1)
            let x = (cycle * 2.2 - 0.6) * size.width
            let gold = warm.mix(with: .white, by: 0.6)
            light.fill(Path(rect), with: .linearGradient(
                Gradient(colors: [gold.opacity(0), gold.opacity(isDark ? 0.28 : 0.4), gold.opacity(0)]),
                startPoint: CGPoint(x: x - 26, y: 0),
                endPoint: CGPoint(x: x + 26, y: size.height)
            ))
        }

        // Sparks, cooling from white-gold to ember red, streaked along their
        // own velocity.
        let tip = CGPoint(x: center.x + frame.tipLean * 6, y: center.y - 9)
        for spark in frame.sparks {
            let p = spark.age / spark.life
            let x = tip.x + spark.x
            let y = tip.y + spark.y
            let alpha = min(1, p * 10) * pow(1 - p, 1.2) * (live ? 1 : 0.65)
            let width = spark.size * (1 - 0.5 * p)
            let color = warm.mix(with: .white, by: 0.55 * (1 - p)).mix(with: hot, by: p * 0.8)
            var trail = Path()
            trail.move(to: CGPoint(x: x - spark.vx * 0.03, y: y - spark.vy * 0.03))
            trail.addLine(to: CGPoint(x: x, y: y))
            light.stroke(trail, with: .color(color.opacity(alpha * 0.35)), style: StrokeStyle(lineWidth: width * 3, lineCap: .round))
            light.stroke(trail, with: .color(color.opacity(alpha)), style: StrokeStyle(lineWidth: width, lineCap: .round))
        }
    }

    // MARK: Frost

    private func drawFrost(_ gc: inout GraphicsContext, size: CGSize, t: Double, burst: Double) {
        let rect = CGRect(origin: .zero, size: size)
        let ice = palette.info
        let pale = ice.mix(with: .white, by: 0.55)

        // Winter wash: deeper at the top, as if lit from a cold sky.
        gc.fill(Path(rect), with: .linearGradient(
            Gradient(colors: [ice.opacity(isDark ? 0.30 : 0.22), ice.opacity(isDark ? 0.12 : 0.07)]),
            startPoint: .zero,
            endPoint: CGPoint(x: size.width * 0.4, y: size.height)
        ))

        var light = gc
        light.blendMode = isDark ? .plusLighter : .normal

        // A slow aurora drifting across the top.
        let aurora = CGPoint(x: size.width * (0.5 + 0.38 * sin(t * 0.22)), y: -size.height * 0.15)
        light.fill(Path(rect), with: .radialGradient(
            Gradient(colors: [pale.opacity(isDark ? 0.22 : 0.45), pale.opacity(0)]),
            center: aurora, startRadius: 0, endRadius: size.width * 0.6
        ))

        // Cold light around the frozen emblem; flashes on tap.
        let center = CGPoint(x: source.x * size.width, y: source.y * size.height)
        let glow = (isDark ? 0.3 : 0.24) * (0.9 + 0.1 * sin(t * 1.3)) + 0.35 * burst
        light.fill(Path(rect), with: .radialGradient(
            Gradient(colors: [pale.opacity(glow), ice.opacity(glow * 0.25), ice.opacity(0)]),
            center: center, startRadius: 0, endRadius: max(size.width, size.height) * (0.6 + 0.3 * burst)
        ))

        // Frosted top edge.
        light.fill(Path(rect), with: .linearGradient(
            Gradient(colors: [pale.opacity(isDark ? 0.14 : 0.5), pale.opacity(0)]),
            startPoint: .zero,
            endPoint: CGPoint(x: 0, y: size.height * 0.35)
        ))

        // Snow in two depths: small, soft and slow behind; larger in front.
        // A tap blows a gust through both.
        var far = light
        far.addFilter(.blur(radius: 0.7))
        let gust = burst * 28
        for i in 0..<18 {
            let near = i % 3 == 0
            let r0 = HeroStreakMotion.random(i, 11)
            let r1 = HeroStreakMotion.random(i, 12)
            let r2 = HeroStreakMotion.random(i, 13)
            let r3 = HeroStreakMotion.random(i, 14)
            let fall = (near ? 0.2 : 0.12) * (0.8 + 0.4 * r1)
            let phase = (t * fall + r0).truncatingRemainder(dividingBy: 1)
            let y = -4 + (size.height + 8) * phase
            let sway = sin(t * (0.8 + r3) + Double(i)) * (near ? 5 : 3)
            let x = r2 * (size.width + 16) - 8 + sway + gust * (near ? 1 : 0.6)
            let radius = near ? 1.3 + 0.8 * r3 : 0.7 + 0.5 * r3
            let fade = min(1, phase * 6) * min(1, (1 - phase) * 6)
            if near {
                if !isDark {
                    // A tinted rim, so white flakes still read on a pale wash.
                    light.fill(circle(x, y, radius + 0.6), with: .color(ice.opacity(0.35 * fade)))
                }
                light.fill(circle(x, y, radius), with: .color(.white.opacity((isDark ? 0.85 : 0.95) * fade)))
            } else {
                far.fill(circle(x, y, radius), with: .color((isDark ? Color.white : ice).opacity(0.5 * fade)))
            }
        }
    }

    private func circle(_ x: Double, _ y: Double, _ radius: Double) -> Path {
        Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
    }
}

// MARK: - Emblem

/// The chip's icon. Burning: the vector flame, in whatever the wind is doing;
/// it flares on tap. Smouldering: the same flame, shorter, sputtering and
/// bent further by the same wind. Frozen: a melting, dripping block of ice
/// (`HeroIceRenderer`).
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
    @ScaledMetric(relativeTo: .footnote) private var scale: CGFloat = 1

    @State private var lit = false

    private var isStill: Bool { reduceMotion || !redactionReasons.isEmpty || stillTime != nil }
    private var side: CGFloat { size * scale }

    var body: some View {
        let mood = HeroStreakMood(state)
        // The layout box is the flame's footprint; the canvas around it is
        // larger so the leaning tip and torn wisps are never clipped.
        Color.clear
            .frame(width: side * 1.05, height: side * 1.4)
            .overlay(alignment: .bottom) {
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: isStill)) { context in
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
                        let burst = HeroStreakMotion.burst(since: tap, at: context.date)
                        let elapsed = tap.map { context.date.timeIntervalSince($0) } ?? 0
                        Canvas { gc, canvas in
                            HeroIceRenderer(
                                t: t, burst: burst, elapsed: elapsed,
                                isDark: colorScheme == .dark,
                                ice: palette.info
                            )
                            .draw(&gc, box: footprint(in: canvas))
                        }
                    }
                }
                .frame(width: side * 3, height: side * 2.2)
                .allowsHitTesting(false)
            }
            .scaleEffect(lit || stillTime != nil ? 1 : 0.3, anchor: .bottom)
            .opacity(lit || stillTime != nil ? 1 : 0)
            .onAppear {
                withAnimation(AmgiMotion.momentum) { lit = true }
            }
            .accessibilityHidden(true)
    }

    /// The layout box, placed bottom-centre in the larger canvas.
    private func footprint(in canvas: CGSize) -> CGRect {
        CGRect(x: (canvas.width - side * 1.05) / 2, y: canvas.height - side * 1.4, width: side * 1.05, height: side * 1.4)
    }
}

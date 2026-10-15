import CoreGraphics
import Foundation

/// One eye, in face units on a head of radius ``AssistantHeadGeometry/radius``.
///
/// Coordinates are y-up and measured on the *unwrapped* face: `x`/`y` are arc
/// lengths across the sphere's front, so an eye 30 units right of centre sits
/// 30/100 rad of longitude around the head. Projection bends the outline onto
/// the sphere — that wrap is the whole 3D illusion.
struct EyePose: Equatable, Sendable {
    var x: Double
    var y: Double = 6
    var width: Double = 19
    var height: Double = 44
    /// Degrees, positive = counter-clockwise.
    var tilt: Double = 0
    /// 0…1 of the eye's height hidden by a flat upper lid from the top.
    var lid: Double = 0
    /// −1…1. Positive drops the lid toward the nose (cross, determined),
    /// negative drops it toward the temple (sad, worried).
    var slant: Double = 0
    /// 0…1. Pushes the bottom of the eye up into an arch — the `^ ^` of a
    /// smiling eye.
    var smile: Double = 0
    /// 1 = open, 0 = closed to a thin line. Multiplied with blinks.
    var open: Double = 1
    /// Bows the whole eye: positive arches it up into `^` (a closed happy
    /// eye, a wink), negative sags it into `‿` (asleep, content). Fraction
    /// of the eye's open height.
    var bend: Double = 0

    /// The same eye on the other side of the face. Lids and smiles are
    /// already side-relative, so only position and tilt flip.
    var mirrored: EyePose {
        var copy = self
        copy.x = -x
        copy.tilt = -tilt
        return copy
    }

    static func mix(_ a: EyePose, _ b: EyePose, _ t: Double) -> EyePose {
        EyePose(
            x: lerp(a.x, b.x, t), y: lerp(a.y, b.y, t),
            width: lerp(a.width, b.width, t), height: lerp(a.height, b.height, t),
            tilt: lerp(a.tilt, b.tilt, t), lid: lerp(a.lid, b.lid, t),
            slant: lerp(a.slant, b.slant, t), smile: lerp(a.smile, b.smile, t),
            open: lerp(a.open, b.open, t), bend: lerp(a.bend, b.bend, t)
        )
    }
}

/// The mouth: one outline between an upper and a lower lip curve, so every
/// shape — a resting line, a grin, an "o", a frown, a squiggle — is the
/// same set of numbers and any two blend.
struct MouthPose: Equatable, Sendable {
    var x: Double = 0
    var y: Double = -40
    var width: Double = 18
    /// −1…1. Lifts the corners into a smile, or drops them into a frown.
    var curve: Double = 0.25
    /// 0…1. How far the mouth is open at its centre.
    var open: Double = 0
    /// −1…1. Lifts the right corner and drops the left — a smirk.
    var skew: Double = 0
    /// 0…1. A wavy line — unsure, flustered.
    var wave: Double = 0

    static func mix(_ a: MouthPose, _ b: MouthPose, _ t: Double) -> MouthPose {
        MouthPose(
            x: lerp(a.x, b.x, t), y: lerp(a.y, b.y, t), width: lerp(a.width, b.width, t),
            curve: lerp(a.curve, b.curve, t), open: lerp(a.open, b.open, t),
            skew: lerp(a.skew, b.skew, t), wave: lerp(a.wave, b.wave, t)
        )
    }
}

/// A full face: head orientation, both eyes and the mouth.
struct HeadPose: Equatable, Sendable {
    /// Degrees. Positive pitch looks up, positive yaw turns toward the
    /// viewer's right, positive roll tilts counter-clockwise.
    var pitch: Double = 0
    var yaw: Double = 0
    var roll: Double = 0
    var left: EyePose
    var right: EyePose
    var mouth = MouthPose()

    /// Builds a pose from the *left* eye; the right defaults to its mirror.
    /// `look` shifts both eyes across the face, on top of the head turn —
    /// eyes lead, the head follows. The mouth stays put; the head carries it.
    static func face(
        pitch: Double = 0, yaw: Double = 0, roll: Double = 0,
        look: (x: Double, y: Double) = (0, 0),
        eye: EyePose = EyePose(x: -18),
        right: EyePose? = nil,
        mouth: MouthPose = MouthPose()
    ) -> HeadPose {
        var left = eye
        var other = right ?? eye.mirrored
        left.x += look.x; left.y += look.y
        other.x += look.x; other.y += look.y
        return HeadPose(pitch: pitch, yaw: yaw, roll: roll, left: left, right: other, mouth: mouth)
    }

    static let neutral = HeadPose.face()

    static func mix(_ a: HeadPose, _ b: HeadPose, _ t: Double) -> HeadPose {
        HeadPose(
            pitch: lerp(a.pitch, b.pitch, t), yaw: lerp(a.yaw, b.yaw, t),
            roll: lerp(a.roll, b.roll, t),
            left: .mix(a.left, b.left, t), right: .mix(a.right, b.right, t),
            mouth: .mix(a.mouth, b.mouth, t)
        )
    }
}

/// Sphere projection for the assistant head.
///
/// Technique after the procedural avatar studio by Stéphane Montlouis
/// (bible-strong-avatar-lab): eye outlines are authored flat, wrapped onto a
/// sphere as longitude/latitude, rotated with the head, then perspective-
/// projected. Eyes compress as they turn toward the rim, which is what sells
/// a flat disc as a ball. Reimplemented here, not ported.
enum AssistantHeadGeometry {
    static let radius = 100.0
    static let focalLength = 520.0
    /// Outline samples per eye. Dense enough that lids and smiles cut cleanly
    /// at large sizes; cheap enough to rebuild every frame.
    static let samplesPerCorner = 14
    /// Authored eye sizes are multiplied by this — one knob for how much of
    /// the ball the eyes take up.
    static let eyeScale = 1.2
    /// The same knob for the mouth's width and opening.
    static let mouthScale = 2.1

    /// Radius of the sphere's silhouette after perspective — slightly larger
    /// than `radius`, because the rim is closer to the camera than the centre
    /// plane.
    static var silhouetteRadius: Double {
        radius * focalLength / (focalLength * focalLength - radius * radius).squareRoot()
    }

    struct ProjectedEye {
        /// Screen points in face units, y-up, origin at the head's centre.
        var points: [CGPoint]
        /// 0…1 — fades an eye that has rotated toward the rim.
        var visibility: Double
    }

    /// `side` is −1 for the viewer's left eye, +1 for the right.
    static func project(eye: EyePose, side: Double, blink: Double, head: HeadPose) -> ProjectedEye {
        let s = eyeScale
        let outline = eyeOutline(eye, side: side, blink: blink).map { CGPoint(x: $0.x * s, y: $0.y * s) }
        let tilt = eye.tilt * .pi / 180
        let (sinT, cosT) = (sin(tilt), cos(tilt))
        var minFacing = 1.0
        let points = outline.map { local -> CGPoint in
            let fx = eye.x * s + local.x * cosT - local.y * sinT
            let fy = eye.y * s + local.x * sinT + local.y * cosT
            let (point, facing) = projectFacePoint(x: fx, y: fy, head: head)
            minFacing = min(minFacing, facing)
            return point
        }
        return ProjectedEye(points: points, visibility: smoothstep(0.02, 0.2, minFacing))
    }

    /// Mouth outline projected onto the head. `thickness` is the closed
    /// mouth's line weight in face units — the caller raises it at small
    /// sizes so the line never thins below a hairline.
    static func project(mouth: MouthPose, thickness: Double, head: HeadPose) -> ProjectedEye {
        var minFacing = 1.0
        let points = mouthOutline(mouth, thickness: thickness).map { local -> CGPoint in
            let (point, facing) = projectFacePoint(x: mouth.x + local.x, y: mouth.y + local.y, head: head)
            minFacing = min(minFacing, facing)
            return point
        }
        return ProjectedEye(points: points, visibility: smoothstep(0.02, 0.2, minFacing))
    }

    /// Upper lip left→right, then lower lip right→left. Opening is mostly
    /// jaw: the lower lip travels three times as far as the upper, less so
    /// in a grin, where the upper lip stays flat and the mouth reads as a D.
    static func mouthOutline(_ mouth: MouthPose, thickness: Double, samples: Int = 24) -> [CGPoint] {
        let halfW = max(mouth.width * mouthScale, thickness) / 2
        let openness = clamp(mouth.open, 0, 1)
        let open = openness * 30 * mouthScale
        let upperShare = 0.25 - 0.17 * clamp(mouth.curve, 0, 1)
        // Corners lift less as the mouth opens, so a wide-open grin keeps
        // its shape instead of folding.
        let lift = mouth.curve * (5 + mouth.width * mouthScale * 0.22) * (1 - 0.35 * openness)
        // An open grin keeps its top lip nearly straight — the D of a laugh
        // rather than a V.
        let upperLift = lift * (1 - 0.75 * openness)

        func centre(_ nx: Double, _ lift: Double) -> Double {
            lift * (nx * nx - 0.35) + mouth.skew * 6 * nx + mouth.wave * 3.2 * sin(nx * .pi * 2)
        }
        func gap(_ nx: Double) -> Double { open * pow(max(1 - nx * nx, 0), 0.5) }

        var points: [CGPoint] = []
        points.reserveCapacity(samples * 2 + 2)
        for i in 0...samples {
            let nx = -1 + 2 * Double(i) / Double(samples)
            points.append(CGPoint(x: nx * halfW, y: centre(nx, upperLift) + thickness / 2 + gap(nx) * upperShare))
        }
        for i in (0...samples).reversed() {
            let nx = -1 + 2 * Double(i) / Double(samples)
            points.append(CGPoint(x: nx * halfW, y: centre(nx, lift) - thickness / 2 - gap(nx) * (1 - upperShare)))
        }
        return points
    }

    /// Wraps a face point onto the sphere, turns it with the head and
    /// projects it. Returns the screen point and how squarely the surface
    /// there faces the camera (1 = head-on, 0 = on the rim).
    static func projectFacePoint(x: Double, y: Double, head: HeadPose) -> (CGPoint, Double) {
        let longitude = x / radius
        let latitude = y / radius
        var p = (
            x: cos(latitude) * sin(longitude),
            y: sin(latitude),
            z: cos(latitude) * cos(longitude)
        )
        p = rotateZ(p, head.roll)
        p = rotateX(p, head.pitch)
        p = rotateY(p, head.yaw)
        let z = p.z * radius
        let scale = focalLength / (focalLength - z)
        return (CGPoint(x: p.x * radius * scale, y: p.y * radius * scale), p.z)
    }

    /// The eye's flat outline in its own frame (centred, untilted), with
    /// blink, lids and smile applied.
    static func eyeOutline(_ eye: EyePose, side: Double, blink: Double) -> [CGPoint] {
        let width = max(eye.width, 1)
        let closedHeight = 3.5
        let openness = clamp(eye.open * blink, 0, 1)
        let height = closedHeight + (max(eye.height, closedHeight) - closedHeight) * openness
        let halfW = width / 2
        let halfH = height / 2
        let minThickness = min(3.0, height)

        return roundedRect(width: width, height: height).map { point in
            let nx = point.x / halfW            // −1…1 across the eye
            let towardNose = -side * nx         // +1 at the nose edge
            // Lids follow the eyeball: they sit a little lower at the corners.
            let top = halfH - eye.lid * height * (1 + 0.3 * nx * nx)
                - eye.slant * towardNose * 0.35 * height
            let bottomArch = -halfH + eye.smile * height * 0.75 * (1 - nx * nx)
            let upper = min(halfH, top)
            let lower = min(bottomArch, upper - minThickness)
            let y = clamp(point.y, lower, max(upper, lower + minThickness))
            let bow = eye.bend * eye.height * (1 - nx * nx)
            return CGPoint(x: point.x, y: y + bow - eye.bend * eye.height * 0.5)
        }
    }

    /// Stadium/rounded-rect outline, counter-clockwise from the bottom edge.
    static func roundedRect(width: Double, height: Double) -> [CGPoint] {
        let halfW = width / 2, halfH = height / 2
        let r = min(halfW, halfH)
        let corners: [(cx: Double, cy: Double, start: Double)] = [
            (halfW - r, -halfH + r, -.pi / 2),
            (halfW - r, halfH - r, 0),
            (-halfW + r, halfH - r, .pi / 2),
            (-halfW + r, -halfH + r, .pi),
        ]
        var points: [CGPoint] = []
        points.reserveCapacity(corners.count * (samplesPerCorner + 4))
        for (index, corner) in corners.enumerated() {
            for step in 0...samplesPerCorner {
                let angle = corner.start + Double(step) / Double(samplesPerCorner) * (.pi / 2)
                points.append(CGPoint(x: corner.cx + cos(angle) * r, y: corner.cy + sin(angle) * r))
            }
            // Straight run to the next corner, so a flat lid cutting across
            // it still has points to land on.
            let next = corners[(index + 1) % corners.count]
            let from = points[points.count - 1]
            let to = CGPoint(x: next.cx + cos(next.start) * r, y: next.cy + sin(next.start) * r)
            let runSteps = max(4, Int((hypot(to.x - from.x, to.y - from.y) / 1.5).rounded(.up)))
            for step in 1..<runSteps {
                let t = Double(step) / Double(runSteps)
                points.append(CGPoint(x: lerp(from.x, to.x, t), y: lerp(from.y, to.y, t)))
            }
        }
        return points
    }

    private typealias Vec = (x: Double, y: Double, z: Double)

    private static func rotateX(_ p: Vec, _ degrees: Double) -> Vec {
        let a = degrees * .pi / 180
        return (p.x, p.y * cos(a) + p.z * sin(a), -p.y * sin(a) + p.z * cos(a))
    }

    private static func rotateY(_ p: Vec, _ degrees: Double) -> Vec {
        let a = degrees * .pi / 180
        return (p.x * cos(a) + p.z * sin(a), p.y, -p.x * sin(a) + p.z * cos(a))
    }

    private static func rotateZ(_ p: Vec, _ degrees: Double) -> Vec {
        let a = degrees * .pi / 180
        return (p.x * cos(a) - p.y * sin(a), p.x * sin(a) + p.y * cos(a), p.z)
    }
}

func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
    min(max(value, low), high)
}

func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
    let t = clamp((x - edge0) / (edge1 - edge0), 0, 1)
    return t * t * (3 - 2 * t)
}

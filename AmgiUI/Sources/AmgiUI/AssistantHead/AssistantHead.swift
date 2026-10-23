public import SwiftUI
import AmgiTheme

/// The assistant's face: a ball with two eyes that wrap around it.
///
/// Size-agnostic — it fills the square it's given, from a 20pt glyph in a
/// button to a hero on an empty state — and surface-agnostic: the caller
/// says what the assistant is doing (``AssistantMood``) and, optionally,
/// where it's looking. Decorative to VoiceOver; label the control it sits
/// in instead.
///
/// ```swift
/// AssistantHead(isGenerating ? .thinking : .idle)
///     .frame(width: 28, height: 28)
/// ```
public struct AssistantHead: View {
    private let mood: AssistantMood
    private let gaze: CGPoint?
    private let style: AssistantHeadStyle

    @State private var engine = AssistantHeadEngine()
    @Environment(\.palette) private var palette
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameters:
    ///   - mood: What the assistant is doing or feeling. Changes blend.
    ///   - gaze: Where to look, −1…1 on each axis (x right, y down); `nil`
    ///     looks at the viewer. Smoothed, so raw touch or cursor positions
    ///     are fine.
    ///   - style: Colours and shading. Defaults follow the palette.
    public init(_ mood: AssistantMood = .idle, gaze: CGPoint? = nil, style: AssistantHeadStyle = .standard) {
        self.mood = mood
        self.gaze = gaze
        self.style = style
    }

    public var body: some View {
        let bodyColor = style.body ?? palette.accent
        let eyeColor = style.eyes ?? palette.onAccent
        TimelineView(.animation(paused: reduceMotion)) { context in
            let frame = reduceMotion
                ? AssistantHeadEngine.still(mood: mood, gaze: gaze)
                : engine.frame(mood: mood, gaze: gaze, at: context.date.timeIntervalSinceReferenceDate)
            AssistantHeadCanvas(
                frame: frame, bodyColor: bodyColor, eyeColor: eyeColor,
                shading: style.shading ? HeadShading(colorScheme) : nil,
                showsMouth: style.showsMouth
            )
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

/// Colours for ``AssistantHead``. `nil` colours resolve from the palette:
/// the body takes `accent` and the eyes `onAccent`, so the head is the
/// brand violet in every theme — a deep ball with white eyes in light mode,
/// a light one with deep violet eyes in dark.
public struct AssistantHeadStyle: Equatable, Sendable {
    public var body: Color?
    public var eyes: Color?
    /// A soft key light and rim falloff that round the disc into a ball.
    /// Turn off for a flat, glyph-like mark.
    public var shading: Bool
    /// Eyes-only when off — for marks too small for a mouth to read, or
    /// surfaces that want the quieter face.
    public var showsMouth: Bool

    public init(body: Color? = nil, eyes: Color? = nil, shading: Bool = true, showsMouth: Bool = true) {
        self.body = body
        self.eyes = eyes
        self.shading = shading
        self.showsMouth = showsMouth
    }

    public static let standard = AssistantHeadStyle()
    public static let flat = AssistantHeadStyle(shading: false)
}

/// Draws one frame. Split out so the drawing is a pure function of its
/// inputs and the engine never runs inside the renderer.
struct AssistantHeadCanvas: View {
    let frame: HeadFrame
    let bodyColor: Color
    let eyeColor: Color
    let shading: HeadShading?
    var showsMouth = true

    var body: some View {
        Canvas { context, size in
            draw(in: &context, size: size)
        }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        typealias G = AssistantHeadGeometry
        // Headroom above for hops and bobs.
        let unit = min(size.width, size.height) / 2 / (G.silhouetteRadius + 4)
        let center = CGPoint(x: size.width / 2, y: size.height / 2 + 2 * unit - frame.bob * unit)
        func screen(_ p: CGPoint) -> CGPoint {
            CGPoint(x: center.x + p.x * unit, y: center.y - p.y * unit)
        }

        let r = G.silhouetteRadius * unit
        let ball = Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
        context.fill(ball, with: .color(bodyColor))

        if let shading {
            shading.apply(to: ball, in: &context, center: center, radius: r, body: bodyColor)
        }

        for (eye, side) in [(frame.pose.left, -1.0), (frame.pose.right, 1.0)] {
            let projected = G.project(eye: eye, side: side, blink: frame.blink, head: frame.pose)
            guard projected.visibility > 0.01 else { continue }
            let path = Self.smoothClosedPath(projected.points.map(screen))
            context.fill(path, with: .color(eyeColor.opacity(projected.visibility)))
        }

        if showsMouth {
            // Never thinner than about a point on screen.
            let thickness = max(7, 1.2 / unit)
            let mouth = G.project(mouth: frame.pose.mouth, thickness: thickness, head: frame.pose)
            if mouth.visibility > 0.01 {
                let path = Self.smoothClosedPath(mouth.points.map(screen))
                context.fill(path, with: .color(eyeColor.opacity(mouth.visibility)))
            }
        }
    }

    /// Quadratic curves through the midpoints of a polygon — rounds the
    /// corners where a lid or smile cuts the outline.
    static func smoothClosedPath(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard points.count > 2 else { return path }
        func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
        path.move(to: mid(points[points.count - 1], points[0]))
        for index in points.indices {
            let next = points[(index + 1) % points.count]
            path.addQuadCurve(to: mid(points[index], next), control: points[index])
        }
        path.closeSubpath()
        return path
    }
}

/// Lighting on the ball, tuned per appearance. The light stays put while the
/// head turns, as a real light would. Shadows are the body colour taken
/// toward black rather than neutral black, which greys a saturated violet
/// into mud; highlights stay white, since they're the light, not chrome.
///
/// Light mode is a deep ball on a pale page: a satin sheen top-left, a rim
/// that falls into deep violet, and a faint bounce along the lower edge so
/// the underside doesn't go flat. Dark mode is a light ball on a near-black
/// page, where a dark rim would dissolve the silhouette: the shadow sits
/// low and soft, the sheen is gentler (the body is already light), and a
/// thin lit edge keeps the outline crisp against the background.
struct HeadShading: Equatable {
    var sheen: Double
    var specular: Double
    var shadowDepth: Double
    var shadowOpacity: Double
    var shadowStart: Double
    var edgeLight: Double

    init(_ scheme: ColorScheme) {
        switch scheme {
        case .dark:
            sheen = 0.16; specular = 0.30
            shadowDepth = 0.55; shadowOpacity = 0.30; shadowStart = 0.55
            edgeLight = 0.22
        default:
            sheen = 0.22; specular = 0.42
            shadowDepth = 0.6; shadowOpacity = 0.42; shadowStart = 0.5
            edgeLight = 0.16
        }
    }

    func apply(to ball: Path, in context: inout GraphicsContext, center: CGPoint, radius r: CGFloat, body: Color) {
        let shadow = body.mix(with: .black, by: shadowDepth)
        let key = CGPoint(x: center.x - r * 0.38, y: center.y - r * 0.46)

        // Broad sheen: the ball's lit hemisphere.
        context.fill(ball, with: .radialGradient(
            Gradient(stops: [
                .init(color: .white.opacity(sheen), location: 0),
                .init(color: .white.opacity(sheen * 0.25), location: 0.5),
                .init(color: .white.opacity(0), location: 1),
            ]),
            center: key, startRadius: 0, endRadius: r * 1.3
        ))
        // Form shadow, offset away from the light, in the body's own hue.
        context.fill(ball, with: .radialGradient(
            Gradient(stops: [
                .init(color: shadow.opacity(0), location: shadowStart),
                .init(color: shadow.opacity(shadowOpacity), location: 1),
            ]),
            center: CGPoint(x: center.x - r * 0.22, y: center.y - r * 0.28),
            startRadius: 0, endRadius: r * 1.22
        ))
        // Bounce / lit edge: a thin crescent along the lower-right rim.
        context.fill(ball, with: .radialGradient(
            Gradient(stops: [
                .init(color: .white.opacity(0), location: 0.82),
                .init(color: .white.opacity(edgeLight), location: 1),
            ]),
            center: CGPoint(x: center.x - r * 0.12, y: center.y - r * 0.14),
            startRadius: 0, endRadius: r * 1.06
        ))
        // Specular: small and soft, inside the sheen.
        context.fill(ball, with: .radialGradient(
            Gradient(stops: [
                .init(color: .white.opacity(specular), location: 0),
                .init(color: .white.opacity(0), location: 1),
            ]),
            center: CGPoint(x: center.x - r * 0.42, y: center.y - r * 0.52),
            startRadius: 0, endRadius: r * 0.34
        ))
    }
}

// MARK: - Previews

#Preview("Every mood") {
    ScrollView {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 16)], spacing: 20) {
            ForEach(AssistantMood.allCases) { mood in
                VStack(spacing: 6) {
                    AssistantHead(mood).frame(width: 72, height: 72)
                    Text(mood.rawValue).amgiFont(.micro)
                }
            }
        }
        .padding()
    }
}

#Preview("Light and dark") {
    HStack(spacing: 0) {
        ForEach([ColorScheme.light, .dark], id: \.self) { scheme in
            HStack(spacing: 16) {
                AssistantHead(.idle).frame(width: 28, height: 28)
                AssistantHead(.happy).frame(width: 64, height: 64)
                AssistantHead(.curious).frame(width: 120, height: 120)
            }
            .padding(24)
            .background(scheme == .dark ? Color.black : Color(white: 0.96))
            .environment(\.colorScheme, scheme)
            .environment(\.palette, scheme == .dark ? .vividDark : .vividLight)
        }
    }
}

#Preview("Sizes") {
    HStack(alignment: .bottom, spacing: 20) {
        ForEach([18.0, 24, 32, 64, 160], id: \.self) { side in
            AssistantHead(.idle).frame(width: side, height: side)
        }
    }
    .padding()
}

#Preview("Flat") {
    HStack(spacing: 20) {
        AssistantHead(.happy, style: .flat).frame(width: 96, height: 96)
        AssistantHead(.thinking, style: .flat).frame(width: 96, height: 96)
    }
    .padding()
}

#Preview("Switching") {
    @Previewable @State var mood = AssistantMood.idle
    VStack(spacing: 24) {
        AssistantHead(mood).frame(width: 180, height: 180)
        Picker("Mood", selection: $mood) {
            ForEach(AssistantMood.allCases) { Text($0.rawValue).tag($0) }
        }
    }
    .padding()
}

#Preview("Gaze follows touch") {
    @Previewable @State var gaze: CGPoint?
    GeometryReader { proxy in
        AssistantHead(.curious, gaze: gaze)
            .frame(width: 160, height: 160)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    gaze = CGPoint(
                        x: value.location.x / proxy.size.width * 2 - 1,
                        y: value.location.y / proxy.size.height * 2 - 1
                    )
                }
                .onEnded { _ in gaze = nil })
    }
}

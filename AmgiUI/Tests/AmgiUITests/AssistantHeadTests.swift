import CoreGraphics
import Testing
@testable import AmgiUI

@Suite("AssistantHead")
struct AssistantHeadTests {
    typealias G = AssistantHeadGeometry

    @Test func faceCentreProjectsToCentre() {
        let (point, facing) = G.projectFacePoint(x: 0, y: 0, head: .neutral)
        #expect(abs(point.x) < 1e-9)
        #expect(abs(point.y) < 1e-9)
        #expect(abs(facing - 1) < 1e-9)
    }

    @Test func turningTheHeadCompressesTheFarEye() {
        var head = HeadPose.neutral
        head.yaw = 35
        // Turning right carries the right eye toward the rim.
        let towardRim = G.project(eye: head.right, side: 1, blink: 1, head: head)
        let towardCentre = G.project(eye: head.left, side: -1, blink: 1, head: head)
        #expect(Self.width(towardCentre.points) > Self.width(towardRim.points) * 1.15)
    }

    @Test func blinkClosesToAThinLine() {
        let eye = EyePose(x: -18)
        let open = G.eyeOutline(eye, side: -1, blink: 1)
        let shut = G.eyeOutline(eye, side: -1, blink: 0)
        #expect(Self.height(open) > 40)
        #expect(Self.height(shut) < 4)
    }

    @Test func lidAndSmileNeverInvertTheEye() {
        let squeezed = EyePose(x: -18, lid: 0.9, slant: 1, smile: 1)
        for point in G.eyeOutline(squeezed, side: -1, blink: 1) {
            #expect(point.y.isFinite)
        }
        #expect(Self.height(G.eyeOutline(squeezed, side: -1, blink: 1)) >= 2.9)
    }

    @Test func slantDropsTheLidOnTheNoseSide() {
        let cross = EyePose(x: -18, lid: 0.1, slant: 0.6)
        // Left eye: the nose is toward +x.
        let points = G.eyeOutline(cross, side: -1, blink: 1)
        let noseTop = points.filter { $0.x > 6 }.map(\.y).max() ?? 0
        let templeTop = points.filter { $0.x < -6 }.map(\.y).max() ?? 0
        #expect(noseTop < templeTop)
    }

    @Test func openMouthIsTallerThanClosed() {
        let closed = G.mouthOutline(MouthPose(curve: 0), thickness: 4.5)
        let open = G.mouthOutline(MouthPose(curve: 0, open: 0.6), thickness: 4.5)
        #expect(Self.height(closed) < 5)
        #expect(Self.height(open) > 15)
    }

    @Test func smileLiftsTheCornersAndFrownDropsThem() {
        func cornerMinusCentre(_ curve: Double) -> Double {
            let points = G.mouthOutline(MouthPose(curve: curve), thickness: 4.5, samples: 24)
            return points[0].y - points[12].y
        }
        #expect(cornerMinusCentre(0.8) > 3)
        #expect(cornerMinusCentre(-0.8) < -3)
    }

    @Test func everyMoodHasAScript() {
        for mood in AssistantMood.allCases {
            #expect(!mood.script.steps.isEmpty, "\(mood) has no steps")
        }
    }

    @MainActor
    @Test func changingMoodIsContinuous() {
        let engine = AssistantHeadEngine()
        var t = 100.0
        var last = engine.frame(mood: .idle, gaze: nil, at: t)
        for mood in [AssistantMood.surprised, .laughing, .sleeping, .thinking] {
            for _ in 0..<30 {
                t += 1.0 / 60
                let next = engine.frame(mood: mood, gaze: nil, at: t)
                #expect(abs(next.pose.yaw - last.pose.yaw) < 6, "\(mood) jumped")
                #expect(abs(next.pose.left.height - last.pose.left.height) < 6, "\(mood) jumped")
                #expect(abs(next.pose.mouth.curve - last.pose.mouth.curve) < 0.3, "\(mood) jumped")
                last = next
            }
        }
    }

    @Test func loopingScriptWrapsSmoothly() {
        let script = AssistantMood.idle.script
        let end = script.pose(at: script.cycleDuration - 0.001)
        let start = script.pose(at: script.cycleDuration + 0.001)
        #expect(abs(end.yaw - start.yaw) < 0.5)
    }

    private static func width(_ points: [CGPoint]) -> Double {
        (points.map(\.x).max() ?? 0) - (points.map(\.x).min() ?? 0)
    }

    private static func height(_ points: [CGPoint]) -> Double {
        (points.map(\.y).max() ?? 0) - (points.map(\.y).min() ?? 0)
    }
}

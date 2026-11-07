import Foundation
import Testing
@testable import AirDialCore

/// A 3D pointing hand (metres, AirDial convention: x right, y up, z away from the camera):
/// index straight up, middle / ring / little curled, thumb tip at `thumb`.
private func hand3D(thumb: Vec3, time: Double, indexTip2D: Vec2 = Vec2(0.7, 0.5)) -> HandSample {
    var w = [Vec3](repeating: Vec3(0, 0, 0), count: 21)
    w[0] = Vec3(0, -0.09, 0)                                   // wrist
    w[1] = Vec3(-0.03, -0.07, 0); w[2] = Vec3(-0.045, -0.045, -0.01); w[3] = Vec3(-0.05, -0.025, -0.02)
    w[4] = thumb
    func straight(_ x: Double, _ base: Int) {                 // MCP, PIP, DIP, tip straight up
        for k in 0..<4 { w[base + k] = Vec3(x, 0.03 * Double(k), 0) }
    }
    func curled(_ x: Double, _ base: Int) {                   // folded towards the palm
        w[base] = Vec3(x, 0, 0); w[base + 1] = Vec3(x, 0.03, -0.01)
        w[base + 2] = Vec3(x, 0.025, -0.035); w[base + 3] = Vec3(x, 0.005, -0.035)
    }
    straight(-0.025, 5); curled(-0.005, 9); curled(0.015, 13); curled(0.035, 17)
    // 2D joints consistent enough for the pose classifier (index extended, others curled).
    func j(_ dx: Double, _ ext: Bool) -> HandSample.FingerJoints {
        let base = indexTip2D - Vec2(0.03, 0.25)
        return .init(tip: base + Vec2(dx, ext ? 0.25 : 0.08), pip: base + Vec2(dx, ext ? 0.15 : 0.12), mcp: base + Vec2(dx, 0.09))
    }
    let wrist2 = indexTip2D - Vec2(0.03, 0.25)
    return HandSample(time: time, wrist: wrist2,
                      fingers: [.index: j(0.03, true), .middle: j(0.06, false), .ring: j(0.09, false), .little: j(0.12, false)],
                      thumbTip: wrist2 + Vec2(0, 0.1), thumbConfidence: 0.9, world: w)
}

struct Hand3DTests {
    let middleTip = Vec3(-0.005, 0.005, -0.035)
    let middlePIP = Vec3(-0.005, 0.03, -0.01)
    let away = Vec3(-0.08, -0.02, -0.02)

    @Test func testBendDecidesFingerState() {
        let s = hand3D(thumb: away, time: 0)
        let c = GestureConfig()
        #expect(PoseClassifier.state(of: .index, in: s, config: c) == .extended)
        #expect(PoseClassifier.state(of: .middle, in: s, config: c) == .curled)
        #expect(PoseClassifier.classify(s, config: c) == .point)
    }

    private func run(_ thumbs: [(Vec3, Int)]) -> [PointerTracker.Event] {
        var p = PointerTracker()
        var out: [PointerTracker.Event] = []
        var t = 0.0
        for (thumb, frames) in thumbs {
            for _ in 0..<frames {
                if let e = p.update(hand3D(thumb: thumb, time: t), time: t, aspect: 4.0 / 3.0) { out.append(e) }
                t += 1.0 / 30
            }
        }
        return out
    }

    @Test func testTappingTheMiddleFingertipIsALeftClick() {
        #expect(run([(away, 10), (middleTip + Vec3(0.005, 0, 0), 8), (away, 5)]) == [.press, .release])
    }

    @Test func testTappingTheSecondKnuckleIsARightClick() {
        #expect(run([(away, 10), (middlePIP + Vec3(0, 0.008, 0), 8), (away, 5)]) == [.rightClick])
    }

    @Test func testAThumbRestingOnTheFingerDoesNotClick() {
        // Already touching when the hand appears, and never lifted: no tap.
        #expect(run([(middlePIP + Vec3(0, 0.008, 0), 40)]) == [])
        #expect(run([(middleTip + Vec3(0.005, 0, 0), 40)]) == [])
    }

    @Test func testLiftingARestingThumbAndTappingIsARightClick() {
        // Resting on the knuckle, lift ~2 cm, tap down again.
        let rest = middlePIP + Vec3(0, 0.008, 0)
        #expect(run([(rest, 30), (rest + Vec3(0, 0.02, 0.01), 4), (rest, 6)]) == [.rightClick])
    }

    private func scrollTotal(_ thumbs: [(Vec3, Int)]) -> (Double, [PointerTracker.Event]) {
        var p = PointerTracker()
        var total = 0.0
        var out: [PointerTracker.Event] = []
        var t = 0.0
        for (thumb, frames) in thumbs {
            for _ in 0..<frames {
                if let e = p.update(hand3D(thumb: thumb, time: t), time: t, aspect: 4.0 / 3.0) { out.append(e) }
                total += p.scroll
                t += 1.0 / 30
            }
        }
        return (total, out)
    }

    @Test func testSlidingTheThumbAlongTheMiddleFingerScrolls() {
        // Thumb touching the middle finger, sliding from the knuckle towards the fingertip and back.
        let a = Vec3(-0.005, 0.03, -0.004)       // on the middle phalanx, near the PIP
        let b = Vec3(-0.005, 0.022, -0.032)      // near the DIP / fingertip end
        var forward: [(Vec3, Int)] = [(a, 6)]
        for k in 1...20 { forward.append((a + (b - a) * (Double(k) / 20), 1)) }
        let (up, events) = scrollTotal(forward + [(b, 4)])
        #expect(up > 100)                         // scrolled up
        #expect(events.isEmpty)                   // and no clicks
        var back: [(Vec3, Int)] = [(b, 6)]
        for k in 1...20 { back.append((b + (a - b) * (Double(k) / 20), 1)) }
        let (down, events2) = scrollTotal(back + [(a, 4)])
        #expect(down < -100)
        #expect(events2.isEmpty)
    }

    @Test func testSlowlySlidingOntoTheKnuckleIsNotATap() {
        // Thumb comes from far away but takes 5 s to arrive (the last 4 cm alone take well over
        // the 0.6 s tap window): a slide, not a tap.
        var seq: [(Vec3, Int)] = [(away, 5)]
        for k in 1...150 {
            let f = Double(k) / 150
            seq.append((away + (middlePIP + Vec3(0, 0.008, 0) - away) * f, 1))
        }
        seq.append((middlePIP + Vec3(0, 0.008, 0), 10))
        #expect(run(seq) == [])
    }
}

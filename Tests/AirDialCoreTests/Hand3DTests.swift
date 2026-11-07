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

/// A 3D thumbs-up: all four fingers curled, the thumb straight and away from them.
private func thumbsUp3D(time: Double, indexTip2D: Vec2) -> HandSample {
    var s = hand3D(thumb: Vec3(-0.06, 0.04, 0), time: time, indexTip2D: indexTip2D)
    var w = s.world!
    // Curl the index too.
    w[5] = Vec3(-0.025, 0, 0); w[6] = Vec3(-0.025, 0.03, -0.01); w[7] = Vec3(-0.025, 0.025, -0.035); w[8] = Vec3(-0.025, 0.005, -0.035)
    // Thumb straight up and out, CMC -> MCP -> IP -> tip in a line; its tip ~5 cm from the index
    // finger's middle joint (measured on a real thumbs-up: ~7 cm; tucked: ~3 cm).
    w[1] = Vec3(-0.04, -0.06, 0); w[2] = Vec3(-0.05, -0.025, 0.003); w[3] = Vec3(-0.06, 0.01, 0.006); w[4] = Vec3(-0.07, 0.045, 0.01)
    s.world = w
    return s
}

struct Hand3DTests {
    let middleDIP = Vec3(-0.005, 0.025, -0.035)   // first knuckle, by the fingertip: left click
    let middlePIP = Vec3(-0.005, 0.03, -0.01)     // second knuckle: right click
    let away = Vec3(-0.08, -0.02, -0.02)

    @Test func testThumbsUpIsRecognisedWithoutPointingUp() {
        let c = GestureConfig()
        #expect(PoseClassifier.classify(thumbsUp3D(time: 0, indexTip2D: Vec2(0.6, 0.5)), config: c) == .thumbsUp)
        // Tilt the whole hand 70 degrees sideways (thumb no longer "up" for the camera): still a thumbs-up.
        var s = thumbsUp3D(time: 0, indexTip2D: Vec2(0.6, 0.5))
        let a = 70 * Double.pi / 180
        s.world = s.world!.map { Vec3($0.x * cos(a) - $0.y * sin(a), $0.x * sin(a) + $0.y * cos(a), $0.z) }
        #expect(PoseClassifier.classify(s, config: c) == .thumbsUp)
    }

    @Test func testSwitchingFromPointingToThumbsUpLeavesTheCursorWhereYouPointed() {
        let e = GestureEngine()
        var t = 0.0
        var pointed: Vec2?
        while t < 1.0 {   // point, steady at x = 0.6
            _ = e.process(hand3D(thumb: Vec3(-0.08, -0.02, -0.02), time: t, indexTip2D: Vec2(0.6, 0.5)), time: t)
            pointed = e.status.pointer
            t += 1.0 / 30
        }
        var last: Vec2?
        var actions: [GestureAction] = []
        var k = 0
        while t < 2.0 {   // the hand drifts to x = 0.8 while turning into a thumbs-up
            let x = 0.6 + min(Double(k) / 10, 1) * 0.2
            actions += e.process(thumbsUp3D(time: t, indexTip2D: Vec2(x, 0.5)), time: t)
            if let p = e.status.pointer { last = p }
            t += 1.0 / 30
            k += 1
        }
        #expect(actions.contains(.fnDown))
        #expect(last!.distance(to: pointed!) < 0.03, "\(String(describing: last)) vs \(String(describing: pointed))")
    }

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

    @Test func testTappingTheFirstKnuckleIsALeftClick() {
        #expect(run([(away, 10), (middleDIP + Vec3(0.006, 0, 0), 8), (away, 5)]) == [.press])
    }

    @Test func testTappingTheSecondKnuckleIsARightClick() {
        #expect(run([(away, 10), (middlePIP + Vec3(0, 0.008, 0), 8), (away, 5)]) == [.rightClick])
    }

    @Test func testAThumbRestingOnTheFingerDoesNotClick() {
        // Already touching when the hand appears, and never lifted: no tap.
        #expect(run([(middlePIP + Vec3(0, 0.008, 0), 40)]) == [])
        #expect(run([(middleDIP + Vec3(0.006, 0, 0), 40)]) == [])
    }

    @Test func testLiftingARestingThumbAndTappingIsARightClick() {
        // Resting on the knuckle, lift ~2 cm, tap down again.
        let rest = middlePIP + Vec3(0, 0.008, 0)
        // (The click is confirmed 0.2 s after touching down, once it's clear the thumb isn't sliding.)
        #expect(run([(rest, 30), (rest + Vec3(0, 0.02, 0.01), 4), (rest, 10)]) == [.rightClick])
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

    @Test func testTapThenSlideIsAScrollNotAClick() {
        // Tap down on the second knuckle, then slide towards the fingertip right away.
        let a = middlePIP + Vec3(0, 0.006, 0)
        let b = Vec3(-0.005, 0.022, -0.032)
        var seq: [(Vec3, Int)] = [(away, 10), (a, 1)]
        for k in 1...10 { seq.append((a + (b - a) * (Double(k) / 10), 1)) }
        seq.append((b, 3))
        let (total, events) = scrollTotal(seq)
        #expect(events.isEmpty)
        #expect(total > 50)
    }

    @Test func testJitteryRestingThumbNeitherScrollsNorFreezesTheCursor() {
        // Thumb resting on the middle finger with tracker jitter (+-3 mm back and forth), while
        // the index fingertip (cursor) moves: no scroll, and the cursor keeps following.
        var p = PointerTracker()
        let rest = middlePIP + Vec3(0, 0.006, 0)
        var scrolled = 0.0
        var tips: [Double] = []
        for i in 0..<90 {
            let t = Double(i) / 30
            // Jitter plus a slow drift along the finger (8 mm over 3 s, as the hand shifts while
            // pointing at different places): the drift used to add up to a "scroll" and freeze the cursor.
            let drift = (Vec3(-0.005, 0.022, -0.032) - middlePIP).normalized * (0.008 * t / 3)
            let jitter = drift + Vec3(0, 0.003 * sin(Double(i) * 1.7), 0.003 * cos(Double(i) * 2.3))
            let s = hand3D(thumb: rest + jitter, time: t, indexTip2D: Vec2(0.5 + 0.3 * t / 3, 0.5))
            _ = p.update(s, time: t, aspect: 4.0 / 3.0)
            scrolled += abs(p.scroll)
            if let tip = p.tip { tips.append(tip.x) }
        }
        #expect(scrolled == 0)
        #expect((tips.last ?? 0) - (tips.first ?? 0) > 0.2)   // the cursor followed the finger
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

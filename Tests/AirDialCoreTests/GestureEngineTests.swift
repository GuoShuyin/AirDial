import Foundation
import Testing
@testable import AirDialCore

/// Synthetic hands: the whole hand is translated so that the tracked fingertip follows a path.
private func hand(pose: HandPose, tipAt tip: Vec2, time: Double) -> HandSample {
    // Hand layout relative to the wrist (units of image height).
    let extendedTip = Vec2(0, 0.25), extendedPip = Vec2(0, 0.15)
    let curledTip = Vec2(0, 0.08), curledPip = Vec2(0, 0.12)
    let mcp = Vec2(0, 0.09)

    func joints(_ extended: Bool, dx: Double) -> HandSample.FingerJoints {
        let t = extended ? extendedTip : curledTip
        let p = extended ? extendedPip : curledPip
        return .init(tip: Vec2(t.x + dx, t.y), pip: Vec2(p.x + dx, p.y), mcp: Vec2(mcp.x + dx, mcp.y))
    }

    let ext: [Finger: Bool]
    switch pose {
    case .point: ext = [.index: true, .middle: false, .ring: false, .little: false]
    case .twoFingers: ext = [.index: true, .middle: true, .ring: false, .little: false]
    default: ext = [.index: true, .middle: true, .ring: true, .little: true]
    }
    let dxs: [Finger: Double] = [.index: -0.03, .middle: 0.0, .ring: 0.03, .little: 0.06]

    var fingers: [Finger: HandSample.FingerJoints] = [:]
    for f in Finger.allCases { fingers[f] = joints(ext[f]!, dx: dxs[f]!) }

    // Translate so the tracked point (index tip, or index/middle midpoint) lands on `tip`.
    let rel: Vec2 = pose == .twoFingers
        ? Vec2.midpoint(fingers[.index]!.tip!, fingers[.middle]!.tip!)
        : fingers[.index]!.tip!
    let wrist = tip - rel
    func shift(_ j: HandSample.FingerJoints) -> HandSample.FingerJoints {
        .init(tip: j.tip.map { $0 + wrist }, pip: j.pip.map { $0 + wrist }, mcp: j.mcp.map { $0 + wrist })
    }
    return HandSample(time: time, wrist: wrist, fingers: fingers.mapValues(shift))
}

private let fps = 30.0

private func run(_ engine: GestureEngine, pose: HandPose, seconds: Double, start: Double = 0,
                 path: (Double) -> Vec2) -> [GestureAction] {
    var out: [GestureAction] = []
    let n = Int(seconds * fps)
    for i in 0..<n {
        let t = start + Double(i) / fps
        let s = hand(pose: pose, tipAt: path(t - start), time: t)
        out += engine.process(s, time: t)
    }
    return out
}

private func circle(center: Vec2 = Vec2(0.66, 0.5), radius: Double, period: Double, clockwise: Bool,
                    phase: Double = 0) -> (Double) -> Vec2 {
    { t in
        let a = phase + (clockwise ? -1.0 : 1.0) * 2 * .pi * t / period
        return Vec2(center.x + radius * cos(a), center.y + radius * sin(a))
    }
}

struct GestureEngineTests {
    @Test func testPoseClassification() {
        let c = GestureConfig()
        #expect(PoseClassifier.classify(hand(pose: .point, tipAt: Vec2(0.5, 0.5), time: 0), config: c) == .point)
        #expect(PoseClassifier.classify(hand(pose: .twoFingers, tipAt: Vec2(0.5, 0.5), time: 0), config: c) == .twoFingers)
        #expect(PoseClassifier.classify(hand(pose: .other, tipAt: Vec2(0.5, 0.5), time: 0), config: c) == .other)
        #expect(PoseClassifier.classify(nil, config: c) == .none)
    }

    @Test func testClockwiseCircleTurnsVolumeUp() {
        let e = GestureEngine()
        // Two loops, 1 s per loop, radius 0.1 (a comfortable circle about a fist wide).
        let actions = run(e, pose: .point, seconds: 2.0, path: circle(radius: 0.1, period: 1.0, clockwise: true))
        #expect(actions.count >= 3, "\(actions)")
        #expect(actions.allSatisfy { $0 == .volumeUp }, "\(actions)")
    }

    @Test func testCounterClockwiseCircleTurnsVolumeDown() {
        let e = GestureEngine()
        let actions = run(e, pose: .point, seconds: 2.0, path: circle(radius: 0.1, period: 1.0, clockwise: false))
        #expect(actions.count >= 3, "\(actions)")
        #expect(actions.allSatisfy { $0 == .volumeDown }, "\(actions)")
    }

    @Test func testSlowCircleStillWorks() {
        let e = GestureEngine()
        let actions = run(e, pose: .point, seconds: 4.0, path: circle(radius: 0.12, period: 2.0, clockwise: true))
        #expect(actions.count >= 3, "\(actions)")
        #expect(actions.allSatisfy { $0 == .volumeUp })
    }

    @Test func testReversingDirectionSwitchesVolumeDirection() {
        let e = GestureEngine()
        var actions = run(e, pose: .point, seconds: 1.5, path: circle(radius: 0.1, period: 1.0, clockwise: true))
        actions += run(e, pose: .point, seconds: 1.5, start: 1.5,
                       path: circle(radius: 0.1, period: 1.0, clockwise: false, phase: .pi))
        #expect(actions.first == .volumeUp)
        #expect(actions.last == .volumeDown)
    }

    @Test func testPartialCircleDoesNothing() {
        let e = GestureEngine()
        // Only ~200 degrees of arc: below the 270 degree start threshold.
        let actions = run(e, pose: .point, seconds: 0.55, path: circle(radius: 0.1, period: 1.0, clockwise: true))
        #expect(actions == [])
    }

    @Test func testTinyCircleDoesNothing() {
        let e = GestureEngine()
        let actions = run(e, pose: .point, seconds: 2.0, path: circle(radius: 0.02, period: 0.7, clockwise: true))
        #expect(actions == [])
    }

    @Test func testBackAndForthLineDoesNothing() {
        let e = GestureEngine()
        let actions = run(e, pose: .point, seconds: 3.0) { t in
            Vec2(0.5 + 0.15 * sin(2 * .pi * t / 0.8), 0.5 + 0.02 * sin(2 * .pi * t / 1.3))
        }
        #expect(actions == [])
    }

    @Test func testJitterDoesNothing() {
        let e = GestureEngine()
        var rng = SystemRandomNumberGenerator()
        let actions = run(e, pose: .point, seconds: 3.0) { _ in
            Vec2(0.6 + Double.random(in: -0.008...0.008, using: &rng), 0.5 + Double.random(in: -0.008...0.008, using: &rng))
        }
        #expect(actions == [])
    }

    @Test func testCircleWithOpenPalmDoesNothing() {
        let e = GestureEngine()
        let actions = run(e, pose: .other, seconds: 2.0, path: circle(radius: 0.1, period: 1.0, clockwise: true))
        #expect(actions == [])
    }

    @Test func testTwoFingerSwipeUpIsNextAndReturnIsIgnored() {
        let e = GestureEngine()
        // Hold still, swipe up 0.25 in 0.25 s, hold, then bring the hand back down.
        let actions = run(e, pose: .twoFingers, seconds: 2.0) { t in
            let y: Double
            if t < 0.4 { y = 0.35 }
            else if t < 0.65 { y = 0.35 + (t - 0.4) / 0.25 * 0.25 }
            else if t < 1.0 { y = 0.60 }
            else if t < 1.3 { y = 0.60 - (t - 1.0) / 0.3 * 0.25 }
            else { y = 0.35 }
            return Vec2(0.66, y)
        }
        #expect(actions == [.nextTrack])
    }

    @Test func testTwoFingerSwipeDownIsPrevious() {
        let e = GestureEngine()
        let actions = run(e, pose: .twoFingers, seconds: 1.0) { t in
            Vec2(0.66, t < 0.3 ? 0.65 : max(0.35, 0.65 - (t - 0.3) / 0.25 * 0.3))
        }
        #expect(actions == [.previousTrack])
    }

    @Test func testTwoFingerSwipeRightAndLeft() {
        let e = GestureEngine()
        let right = run(e, pose: .twoFingers, seconds: 1.0) { t in
            Vec2(t < 0.3 ? 0.4 : min(0.8, 0.4 + (t - 0.3) / 0.25 * 0.4), 0.5)
        }
        #expect(right == [.nextTrack])

        let e2 = GestureEngine()
        let left = run(e2, pose: .twoFingers, seconds: 1.0) { t in
            Vec2(t < 0.3 ? 0.9 : max(0.5, 0.9 - (t - 0.3) / 0.25 * 0.4), 0.5)
        }
        #expect(left == [.previousTrack])
    }

    @Test func testSlowDriftWithTwoFingersDoesNothing() {
        let e = GestureEngine()
        // 0.3 of travel over 3 s is a hand drifting, not a swipe.
        let actions = run(e, pose: .twoFingers, seconds: 3.0) { t in Vec2(0.66, 0.3 + 0.1 * t) }
        #expect(actions == [])
    }

    @Test func testBriefPoseDropoutDoesNotBreakCircle() {
        let e = GestureEngine()
        var actions: [GestureAction] = []
        let path = circle(radius: 0.1, period: 1.0, clockwise: true)
        for i in 0..<60 {
            let t = Double(i) / fps
            // Every 10th frame the model "loses" the hand.
            let s: HandSample? = i % 10 == 5 ? nil : hand(pose: .point, tipAt: path(t), time: t)
            actions += e.process(s, time: t)
        }
        #expect(actions.count >= 3, "\(actions)")
        #expect(actions.allSatisfy { $0 == .volumeUp })
    }
}

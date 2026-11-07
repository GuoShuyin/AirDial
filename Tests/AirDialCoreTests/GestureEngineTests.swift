import Foundation
import Testing
@testable import AirDialCore

/// Synthetic hands: the whole hand is translated so that the tracked fingertip follows a path.
/// `spread` scales the sideways spacing of the fingers: 1 = a narrow hand (palm width 0.09,
/// like an edge-on hand), 1.7 = a palm facing the camera from up close (width ~0.15, measured).
private func hand(pose: HandPose, tipAt tip: Vec2, time: Double, spread: Double = 1) -> HandSample {
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
    for f in Finger.allCases { fingers[f] = joints(ext[f]!, dx: dxs[f]! * spread) }

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

private func run(_ engine: GestureEngine, pose: HandPose, seconds: Double, start: Double = 0, spread: Double = 1,
                 path: (Double) -> Vec2) -> [GestureAction] {
    var out: [GestureAction] = []
    let n = Int(seconds * fps)
    for i in 0..<n {
        let t = start + Double(i) / fps
        let s = hand(pose: pose, tipAt: path(t - start), time: t, spread: spread)
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
        // The helper's default hand has all four fingers extended: an open palm.
        #expect(PoseClassifier.classify(hand(pose: .other, tipAt: Vec2(0.5, 0.5), time: 0), config: c) == .openPalm)
        #expect(PoseClassifier.classify(nil, config: c) == .none)
    }

    @Test func testClockwiseCircleTurnsVolumeUp() {
        let e = GestureEngine()
        // Three loops, 1 s per loop, radius 0.1 (a comfortable circle about a fist wide): one step per loop.
        let actions = run(e, pose: .point, seconds: 3.2, path: circle(radius: 0.1, period: 1.0, clockwise: true))
        #expect(actions.count == 3, "\(actions)")
        #expect(actions.allSatisfy { $0 == .volumeUp }, "\(actions)")
    }

    @Test func testCounterClockwiseCircleTurnsVolumeDown() {
        let e = GestureEngine()
        let actions = run(e, pose: .point, seconds: 3.2, path: circle(radius: 0.1, period: 1.0, clockwise: false))
        #expect(actions.count == 3, "\(actions)")
        #expect(actions.allSatisfy { $0 == .volumeDown }, "\(actions)")
    }

    @Test func testSlowCircleStillWorks() {
        let e = GestureEngine()
        let actions = run(e, pose: .point, seconds: 6.4, path: circle(radius: 0.12, period: 2.0, clockwise: true))
        #expect(actions.count == 3, "\(actions)")
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

    @Test func testOpenPalmSwipeSwitchesDesktop() {
        // Raise the palm, hold it still for a moment, then swipe.
        // Palm moves right -> desktop on the left (default), and vice versa.
        let e = GestureEngine()
        let right = run(e, pose: .other, seconds: 1.3, spread: 1.7) { t in
            Vec2(t < 0.6 ? 0.4 : min(0.8, 0.4 + (t - 0.6) / 0.25 * 0.4), 0.65)
        }
        #expect(right == [.desktopLeft])

        let e2 = GestureEngine()
        let left = run(e2, pose: .other, seconds: 1.3, spread: 1.7) { t in
            Vec2(t < 0.6 ? 0.9 : max(0.5, 0.9 - (t - 0.6) / 0.25 * 0.4), 0.65)
        }
        #expect(left == [.desktopRight])
    }

    @Test func testOpenPalmUpOrDownTogglesMissionControl() {
        // Hold, swipe up: Mission Control. Hold again, swipe down: Mission Control again (toggles it off).
        let e = GestureEngine()
        // (Fingertip heights; the palm centre sits ~0.16 lower and must stay above palmMinHeight to arm.)
        var actions = run(e, pose: .other, seconds: 1.3, spread: 1.7) { t in
            Vec2(0.8, t < 0.6 ? 0.55 : min(0.95, 0.55 + (t - 0.6) / 0.25 * 0.4))
        }
        actions += run(e, pose: .other, seconds: 2.5, start: 1.3, spread: 1.7) { t in
            Vec2(0.8, t < 1.8 ? 0.95 : max(0.55, 0.95 - (t - 1.8) / 0.25 * 0.4))
        }
        #expect(actions == [.missionControl, .missionControl])
    }

    @Test func testNarrowHandPassingThroughDoesNotSwitchDesktop() {
        // An open hand seen edge-on / from afar (narrow palm) moving across the frame.
        let e = GestureEngine()
        let actions = run(e, pose: .other, seconds: 2.0) { t in Vec2(0.2 + 0.7 * t, 0.5 + 0.05 * sin(3 * t)) }
        #expect(actions == [])
    }

    @Test func testPalmHoldModeIgnoresPalmPassingThrough() {
        // Strict mode: even a palm facing the camera doesn't count unless it pauses first.
        var c = GestureConfig()
        c.palmRequireHold = true
        let e = GestureEngine(config: c)
        let actions = run(e, pose: .other, seconds: 2.0, spread: 1.7) { t in Vec2(0.2 + 0.7 * t, 0.65 + 0.05 * sin(3 * t)) }
        #expect(actions == [])
    }

    @Test func testPalmSwipesStraightAwayWithoutHolding() {
        // Default: raise the palm and swipe immediately, no pause.
        let e = GestureEngine()
        let actions = run(e, pose: .other, seconds: 0.8, spread: 1.7) { t in
            Vec2(t < 0.15 ? 0.4 : min(0.8, 0.4 + (t - 0.15) / 0.2 * 0.4), 0.65)
        }
        #expect(actions == [.desktopLeft])
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

    @Test func testTwoFingerSwipeDownIsAlsoNextByDefault() {
        let e = GestureEngine()
        let actions = run(e, pose: .twoFingers, seconds: 1.0) { t in
            Vec2(0.66, t < 0.3 ? 0.65 : max(0.35, 0.65 - (t - 0.3) / 0.25 * 0.3))
        }
        #expect(actions == [.nextTrack])
    }

    @Test func testTwoFingerSwipeDownIsPreviousWithVerticalPrev() {
        var c = GestureConfig()
        c.verticalSwipeAlwaysNext = false
        let e = GestureEngine(config: c)
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
        for i in 0..<96 {
            let t = Double(i) / fps
            // Every 10th frame the model "loses" the hand.
            let s: HandSample? = i % 10 == 5 ? nil : hand(pose: .point, tipAt: path(t), time: t)
            actions += e.process(s, time: t)
        }
        #expect(actions.count == 3, "\(actions)")
        #expect(actions.allSatisfy { $0 == .volumeUp })
    }

    @Test func testFingerMisreadEveryLoopDoesNotBreakCircle() {
        // On a real webcam the finger is misread for several frames in a row once per loop,
        // when it turns towards the camera. That must not reset the circle.
        let e = GestureEngine()
        var actions: [GestureAction] = []
        let path = circle(radius: 0.1, period: 1.0, clockwise: true)
        for i in 0..<96 {
            let t = Double(i) / fps
            let misread = (i % 30) >= 20 && (i % 30) < 28  // 8 frames per loop
            actions += e.process(hand(pose: misread ? .other : .point, tipAt: path(t), time: t), time: t)
        }
        #expect(actions.count == 3, "\(actions)")
        #expect(actions.allSatisfy { $0 == .volumeUp }, "\(actions)")
    }
}

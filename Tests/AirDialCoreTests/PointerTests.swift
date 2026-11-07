import CoreGraphics
import Foundation
import Testing
@testable import AirDialCore

/// A pointing hand (index extended) with the index tip at `tip`, the thumb tip `thumbOffset` away
/// from the tip of `pinchFinger` (middle by default), palm width 0.15.
private func pointingHand(tip: Vec2, thumbOffset: Vec2 = Vec2(0.12, -0.12), time: Double, thumbConfidence: Float = 0.9,
                          pinchFinger: Finger = .middle) -> HandSample {
    let wrist = tip - Vec2(0, 0.25)
    func j(_ dx: Double, extended: Bool) -> HandSample.FingerJoints {
        .init(tip: Vec2(wrist.x + dx, wrist.y + (extended ? 0.25 : 0.08)),
              pip: Vec2(wrist.x + dx, wrist.y + (extended ? 0.15 : 0.12)),
              mcp: Vec2(wrist.x + dx, wrist.y + 0.09))
    }
    let fingers: [Finger: HandSample.FingerJoints] = [.index: j(0, extended: true), .middle: j(0.05, extended: false),
                                                      .ring: j(0.10, extended: false), .little: j(0.15, extended: false)]
    return HandSample(time: time, wrist: wrist, fingers: fingers,
                      thumbTip: fingers[pinchFinger]!.tip! + thumbOffset, thumbConfidence: thumbConfidence)
}

struct PointerTests {
    // The user's layout: MacBook on the left, main display in the middle, another on the right,
    // all at different heights (global display coordinates, y down).
    let screens = [
        CGRect(x: -1512, y: 681, width: 1512, height: 982),   // MacBook (left)
        CGRect(x: 0, y: 0, width: 3440, height: 1440),        // main (middle)
        CGRect(x: 3440, y: -605, width: 2560, height: 1440),  // right
    ]

    @Test func testPointingLeftMiddleRightReachesEachDisplay() {
        let left = ScreenMapper.point(for: Vec2(0.05, 0.5), screens: screens)!
        let middle = ScreenMapper.point(for: Vec2(0.5, 0.5), screens: screens)!
        let right = ScreenMapper.point(for: Vec2(0.95, 0.5), screens: screens)!
        #expect(screens[0].contains(left))
        #expect(screens[1].contains(middle))
        #expect(screens[2].contains(right))
    }

    @Test func testPointingUpReachesTheTopOfThatDisplay() {
        // Top of the right display, even though it sits higher than the others.
        let p = ScreenMapper.point(for: Vec2(0.95, 1.0), screens: screens)!
        #expect(abs(p.y - screens[2].minY) < 2)
        let q = ScreenMapper.point(for: Vec2(0.05, 0.0), screens: screens)!
        #expect(abs(q.y - (screens[0].maxY - 1)) < 2)
    }

    @Test func testReachCalibratesAsTheFingerMoves() {
        var p = PointerTracker()
        var t = 0.0
        // Sweep the fingertip from x = 0.3 to 1.1 and back, at a steady height.
        for i in 0...80 {
            let x = 0.3 + 0.8 * Double(i) / 80
            _ = p.update(pointingHand(tip: Vec2(x, 0.5), time: t), time: t, aspect: 4.0 / 3.0)
            t += 1.0 / 30
        }
        // After reaching x = 1.1, that is the right edge (filter settled after holding still).
        for _ in 0..<30 {
            _ = p.update(pointingHand(tip: Vec2(1.1, 0.5), time: t), time: t, aspect: 4.0 / 3.0)
            t += 1.0 / 30
        }
        #expect(p.position!.x > 0.97)
        for _ in 0..<60 {
            _ = p.update(pointingHand(tip: Vec2(0.3, 0.5), time: t), time: t, aspect: 4.0 / 3.0)
            t += 1.0 / 30
        }
        #expect(p.position!.x < 0.03)
    }

    @Test func testPinchPressesAndReleasesAndFreezesThePointer() {
        var p = PointerTracker()
        var events: [PointerTracker.Event] = []
        var t = 0.0
        func step(_ thumb: Vec2, tip: Vec2 = Vec2(0.7, 0.5)) {
            if let e = p.update(pointingHand(tip: tip, thumbOffset: thumb, time: t), time: t, aspect: 4.0 / 3.0) { events.append(e) }
            t += 1.0 / 30
        }
        for _ in 0..<20 { step(Vec2(0.12, -0.12)) }          // pointing, thumb away
        let before = p.position!
        for _ in 0..<8 { step(Vec2(0.01, -0.01), tip: Vec2(0.69, 0.49)) }  // pinch: the hand shifts a little
        #expect(events == [.press])
        #expect(p.position!.distance(to: before) < 0.02)       // frozen where it was before the pinch
        for _ in 0..<5 { step(Vec2(0.12, -0.12)) }            // open again
        #expect(events == [.press, .release])
    }

    @Test func testFingertipsLookingCloseWhileMovingFastIsNotAClick() {
        // Circling quickly while the thumb happens to look close to the index tip in 2D.
        var p = PointerTracker()
        var events: [PointerTracker.Event] = []
        for i in 0..<60 {
            let t = Double(i) / 30
            let a = 2 * Double.pi * t
            let tip = Vec2(0.66 + 0.12 * cos(a), 0.5 + 0.12 * sin(a))
            if let e = p.update(pointingHand(tip: tip, thumbOffset: Vec2(0.01, -0.01), time: t), time: t, aspect: 4.0 / 3.0) { events.append(e) }
        }
        #expect(events.isEmpty)
    }

    @Test func testThumbTouchingTheIndexIsNotAClickByDefault() {
        // The default click is thumb + middle finger; the thumb resting on the index tip isn't one.
        var p = PointerTracker()
        var events: [PointerTracker.Event] = []
        for i in 0..<30 {
            let t = Double(i) / 30
            if let e = p.update(pointingHand(tip: Vec2(0.7, 0.5), thumbOffset: Vec2(0.01, -0.01), time: t, pinchFinger: .index),
                                time: t, aspect: 4.0 / 3.0) { events.append(e) }
        }
        #expect(events.isEmpty)
    }

    @Test func testGuessedThumbIsNotAClick() {
        var p = PointerTracker()
        var events: [PointerTracker.Event] = []
        for i in 0..<30 {
            let t = Double(i) / 30
            if let e = p.update(pointingHand(tip: Vec2(0.7, 0.5), thumbOffset: Vec2(0.01, -0.01), time: t, thumbConfidence: 0.2),
                                time: t, aspect: 4.0 / 3.0) { events.append(e) }
        }
        #expect(events.isEmpty)
    }
}

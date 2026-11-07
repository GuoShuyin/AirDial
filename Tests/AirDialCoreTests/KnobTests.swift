import Foundation
import Testing
@testable import AirDialCore

/// A knob grip: thumb out to one side, index and middle fingertips opposite, ring and little
/// curled, palm width 0.15. `angle` (degrees) rotates the whole grip around the palm centre,
/// like turning the wrist; `offset` moves the whole hand.
private func knobHand(angle: Double, offset: Vec2 = .zero, time: Double, thumbConfidence: Float = 0.9) -> HandSample {
    let centre = Vec2(0.66, 0.5) + offset
    let a = angle * .pi / 180
    func rot(_ v: Vec2) -> Vec2 { centre + Vec2(v.x * cos(a) - v.y * sin(a), v.x * sin(a) + v.y * cos(a)) }
    // Knuckles centred on `centre` (the wrist rolls about an axis through the palm).
    let wrist = rot(Vec2(0, -0.09))
    func finger(_ dx: Double, extended: Bool) -> HandSample.FingerJoints {
        .init(tip: rot(Vec2(dx, extended ? 0.16 : -0.01)), pip: rot(Vec2(dx, extended ? 0.07 : 0.03)), mcp: rot(Vec2(dx, 0)))
    }
    return HandSample(time: time, wrist: wrist,
                      fingers: [.index: finger(-0.075, extended: true), .middle: finger(-0.025, extended: true),
                                .ring: finger(0.025, extended: false), .little: finger(0.075, extended: false)],
                      thumbTip: rot(Vec2(-0.17, 0.02)), thumbConfidence: thumbConfidence)
}

struct KnobTests {
    private func turn(_ e: GestureEngine, from a0: Double, to a1: Double, seconds: Double, start: Double = 0,
                      offset: (Double) -> Vec2 = { _ in .zero }) -> [GestureAction] {
        var out: [GestureAction] = []
        let n = Int(seconds * 30)
        for i in 0...n {
            let f = Double(i) / Double(n)
            let t = start + Double(i) / 30
            out += e.process(knobHand(angle: a0 + (a1 - a0) * f, offset: offset(f), time: t), time: t)
        }
        return out
    }

    @Test func testTheGripIsRecognized() {
        #expect(KnobTracker.grip(knobHand(angle: 0, time: 0), config: GestureConfig()) != nil)
    }

    @Test func testTurningRightTurnsVolumeUp() {
        // Clockwise as you see it = negative angle (y up). 80 degrees = 2 steps of 35.
        let acts = turn(GestureEngine(), from: 0, to: -80, seconds: 0.8)
        #expect(acts == [.volumeUp, .volumeUp])
    }

    @Test func testTurningLeftTurnsVolumeDown() {
        let acts = turn(GestureEngine(), from: 0, to: 80, seconds: 0.8)
        #expect(acts == [.volumeDown, .volumeDown])
    }

    @Test func testSwipingWithTheGripIsNotATurn() {
        // The hand moves 0.3 sideways while the wrist happens to rotate 60 degrees.
        let acts = turn(GestureEngine(), from: 0, to: -60, seconds: 0.5, offset: { f in Vec2(0.3 * f, 0) })
        #expect(!acts.contains(.volumeUp) && !acts.contains(.volumeDown))
    }

    @Test func testGuessedThumbIsNotAKnob() {
        #expect(KnobTracker.grip(knobHand(angle: 0, time: 0, thumbConfidence: 0.2), config: GestureConfig()) == nil)
    }
}

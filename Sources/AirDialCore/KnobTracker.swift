import Foundation

/// "Turning a knob" with thumb, index and middle finger: volume up when turned to the right
/// (clockwise as you see it), down when turned to the left.
///
/// The grip: the thumb is clearly seen and held out away from the palm (opposite the fingers),
/// index and middle fingertips are visible and the middle finger isn't curled (that would be
/// pointing), ring and little finger aren't extended. A V sign often looks just like that, so the
/// difference is the motion: turning rotates the thumb -> fingertips direction while the hand
/// stays in place, whereas a swipe moves the whole hand. Rotation only counts while the palm
/// centre has moved less than `knobMaxMove` over the last half second.
public struct KnobTracker {
    private var lastAngle: Double?
    private var accumulated: Double = 0
    private var palmHistory: [(t: Double, p: Vec2)] = []

    /// Rotation since the last step (degrees, + = clockwise), for display.
    public var progress: Double { -accumulated }

    public init() {}

    public mutating func reset() {
        lastAngle = nil
        accumulated = 0
        palmHistory.removeAll()
    }

    /// The thumb -> (index, middle tip midpoint) vector if the hand holds the knob grip.
    static func grip(_ s: HandSample, config c: GestureConfig) -> Vec2? {
        guard let thumb = s.thumbTip, s.thumbConfidence >= c.pinchMinThumbConfidence,
              let it = s.tip(.index), let mt = s.tip(.middle),
              let ringMCP = s.fingers[.ring]?.mcp, let scale = s.palmWidth, scale > 1e-3 else { return nil }
        guard PoseClassifier.state(of: .middle, in: s, config: c) != .curled,
              PoseClassifier.state(of: .ring, in: s, config: c) != .extended,
              PoseClassifier.state(of: .little, in: s, config: c) != .extended else { return nil }
        guard thumb.distance(to: ringMCP) / scale > c.knobThumbOut else { return nil }
        let v = Vec2.midpoint(it, mt) - thumb
        let len = v.length / scale
        guard len > 0.3, len < 1.6 else { return nil }
        return v
    }

    /// Returns +1 for a volume-up step (turned right), -1 for down, 0 for nothing.
    public mutating func add(_ s: HandSample?, time t: Double, config c: GestureConfig) -> Int {
        guard let s = s, let v = KnobTracker.grip(s, config: c), let palm = s.palmCenter else {
            reset()
            return 0
        }
        palmHistory.append((t, palm))
        while let first = palmHistory.first, t - first.t > 0.5 { palmHistory.removeFirst() }
        let moved = palmHistory.map { $0.p.distance(to: palm) }.max() ?? 0

        let angle = atan2(v.y, v.x) * 180 / .pi
        defer { lastAngle = angle }
        guard let last = lastAngle else { return 0 }
        var d = (angle - last + 540).truncatingRemainder(dividingBy: 360) - 180
        if abs(d) > c.knobMaxTurnPerFrame { d = 0 }   // keypoint glitch
        if moved > c.knobMaxMove {
            accumulated = 0                         // the hand is moving: a swipe, not a turn
            return 0
        }
        accumulated += d
        guard abs(accumulated) >= c.knobStepDegrees else { return 0 }
        // y is up, so clockwise (turning right as you see it) is a negative angle change.
        let step = accumulated < 0 ? 1 : -1
        accumulated = 0
        return step
    }
}

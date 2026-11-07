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
    private var lastKnuckles: Vec3?   // 3D: knuckle line (index MCP -> little MCP) last frame
    private var accumulated: Double = 0
    private var palmHistory: [(t: Double, p: Vec2)] = []

    /// Rotation since the last step (degrees, + = clockwise), for display.
    public var progress: Double { -accumulated }

    public init() {}

    public mutating func reset() {
        lastAngle = nil
        lastKnuckles = nil
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

    /// 3D grip: thumb, index and middle fingertips spread around a knob, ring and little curled.
    static func grip3D(_ s: HandSample, config c: GestureConfig) -> Bool {
        guard let w = s.world else { return false }
        let thumb = w[HandSample.worldThumbTip]
        guard let it = s.worldTip(.index), let mt = s.worldTip(.middle) else { return false }
        let di = thumb.distance(to: it), dm = thumb.distance(to: mt)
        guard di >= c.knobGripMin3D, di <= c.knobGripMax3D, dm >= c.knobGripMin3D, dm <= c.knobGripMax3D else { return false }
        return PoseClassifier.state(of: .ring, in: s, config: c) != .extended
            && PoseClassifier.state(of: .little, in: s, config: c) != .extended
    }

    /// Turning measured in 3D: the knuckle line rotating around the hand's own axis
    /// (wrist -> middle knuckle), whatever the camera angle.
    private mutating func add3D(_ s: HandSample, time t: Double, config c: GestureConfig) -> Int {
        guard KnobTracker.grip3D(s, config: c), let w = s.world, let palm = s.palmCenter else {
            reset()
            return 0
        }
        palmHistory.append((t, palm))
        while let first = palmHistory.first, t - first.t > 0.5 { palmHistory.removeFirst() }
        let moved = palmHistory.map { $0.p.distance(to: palm) }.max() ?? 0

        let axis = (w[9] - w[0]).normalized
        func onPlane(_ v: Vec3) -> Vec3 { v - axis * v.dot(axis) }
        let knuckles = onPlane(w[5] - w[17])
        defer { lastKnuckles = knuckles }
        guard let last = lastKnuckles.map(onPlane) else { return 0 }
        var d = atan2(axis.dot(last.cross(knuckles)), last.dot(knuckles)) * 180 / .pi
        if c.knobReverse3D { d = -d }
        if abs(d) > c.knobMaxTurnPerFrame { d = 0 }
        if moved > c.knobMaxMove {
            accumulated = 0
            return 0
        }
        accumulated += d
        guard abs(accumulated) >= c.knobStepDegrees else { return 0 }
        let step = accumulated < 0 ? 1 : -1
        accumulated = 0
        return step
    }

    /// Returns +1 for a volume-up step (turned right), -1 for down, 0 for nothing.
    public mutating func add(_ s: HandSample?, time t: Double, config c: GestureConfig) -> Int {
        if let s = s, s.world != nil { return add3D(s, time: t, config: c) }
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

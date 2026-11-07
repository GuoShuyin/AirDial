import Foundation

/// Detects "drawing a circle in the air" from a stream of fingertip positions.
///
/// Core idea: add up how much the *direction of motion* turns along the resampled
/// fingertip path. One loop is ±360° wherever the circle is; straight lines and
/// back-and-forth motion add up to ~0. On top of that, starting the "knob" requires
/// the recent path to actually look like a circle:
///   - net rotation ≥ `circleStartDegrees`, almost all of it in one direction (consistency)
///   - big enough, not too flat (bounding box aspect), and round (radius spread)
/// Once engaged, every further `circleStepDegrees` of rotation fires another step,
/// like turning a real knob.
public struct CircleTracker {
    private struct Point {
        var t: Double
        var p: Vec2
        var turn: Double // degrees turned at this point; + = counter-clockwise (y up)
    }

    public private(set) var engaged = false
    public private(set) var engagedSign: Double = 0  // +1 CCW, -1 CW
    /// For display: rotation progress toward the next step.
    public private(set) var displayDegrees: Double = 0

    private var window: [Point] = []
    private var progress: Double = 0
    private var peakProgress: Double = 0  // furthest the knob got since the last step
    private var lastSample: Vec2?
    private var lastDir: Vec2?
    private var lastMoveTime: Double = 0

    public init() {}

    public mutating func reset() {
        engaged = false
        engagedSign = 0
        displayDegrees = 0
        window.removeAll()
        progress = 0
        peakProgress = 0
        lastSample = nil
        lastDir = nil
    }

    /// Feed one (smoothed) fingertip position.
    /// Returns +1 for a counter-clockwise step, -1 for a clockwise step, 0 for nothing.
    public mutating func add(_ p: Vec2, time t: Double, config c: GestureConfig) -> Int {
        guard let last = lastSample else {
            start(at: p, time: t)
            return 0
        }

        let d = p - last
        let len = d.length
        if len < c.circleMinStep {
            if t - lastMoveTime > c.circleIdleReset {
                reset()
                start(at: p, time: t)
            }
            return 0
        }

        lastSample = p
        lastMoveTime = t
        var turn = 0.0
        if let prev = lastDir {
            turn = atan2(prev.cross(d), prev.dot(d)) * 180 / .pi
            if abs(turn) > c.circleMaxTurnDegrees { turn = 0 } // sharp kink = noise / direction flip
        }
        lastDir = d

        window.append(Point(t: t, p: p, turn: turn))
        while let first = window.first, t - first.t > c.circleWindow {
            window.removeFirst()
        }

        return engaged ? continueKnob(turn: turn, config: c) : tryStart(config: c)
    }

    // MARK: - Private

    private mutating func start(at p: Vec2, time t: Double) {
        lastSample = p
        lastMoveTime = t
        window = [Point(t: t, p: p, turn: 0)]
    }

    private mutating func disengage() {
        engaged = false
        engagedSign = 0
        progress = 0
        peakProgress = 0
        if let last = window.last { window = [last] }
    }

    /// Most recent stretch of the window whose net rotation reaches `target` degrees
    /// (in `sign` direction, or either direction when sign is nil).
    private func recentStretch(reaching target: Double, sign: Double?) -> (start: Int, net: Double, abs: Double)? {
        var net = 0.0
        var absSum = 0.0
        var k = window.count
        while k > 0 {
            k -= 1
            net += window[k].turn
            absSum += abs(window[k].turn)
            let reached = sign.map { net * $0 >= target } ?? (abs(net) >= target)
            if reached { return (k, net, absSum) }
        }
        return nil
    }

    private mutating func tryStart(config c: GestureConfig) -> Int {
        guard let s = recentStretch(reaching: c.circleStartDegrees, sign: nil), s.abs > 0 else {
            displayDegrees = window.reduce(0) { $0 + $1.turn }
            return 0
        }
        displayDegrees = s.net
        // 1) Consistency: nearly all turning in one direction (random motion fails this).
        guard abs(s.net) / s.abs >= c.circleConsistency else { return 0 }

        let pts = window[s.start...].map { $0.p }
        let xs = pts.map { $0.x }, ys = pts.map { $0.y }
        let w = xs.max()! - xs.min()!
        let h = ys.max()! - ys.min()!
        let big = max(w, h), small = min(w, h)
        // 2) Size and 3) not a flat ellipse.
        guard big >= c.circleMinDiameter, small / big >= c.circleMinAspect else { return 0 }
        // 4) Roundness: distance to centroid should not vary too much.
        let cx = xs.reduce(0, +) / Double(xs.count)
        let cy = ys.reduce(0, +) / Double(ys.count)
        let radii = pts.map { $0.distance(to: Vec2(cx, cy)) }
        let mean = radii.reduce(0, +) / Double(radii.count)
        guard mean > 0 else { return 0 }
        let variance = radii.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(radii.count)
        guard variance.squareRoot() / mean <= c.circleMaxRadiusSpread else { return 0 }

        let sign: Double = s.net > 0 ? 1 : -1
        engaged = true
        engagedSign = sign
        progress = 0
        peakProgress = 0
        displayDegrees = 0
        if let last = window.last { window = [last] }
        return Int(sign)
    }

    private mutating func continueKnob(turn: Double, config c: GestureConfig) -> Int {
        progress += turn * engagedSign
        displayDegrees = progress * engagedSign
        peakProgress = max(peakProgress, progress)
        if progress < peakProgress - c.circleReverseDegrees {
            // Turned the other way: stop; the reverse direction must start fresh.
            disengage()
            return 0
        }
        guard progress >= c.circleStepDegrees else { return 0 }
        progress -= c.circleStepDegrees
        peakProgress = progress

        // Keep turning only while the motion is still a consistent rotation.
        guard let s = recentStretch(reaching: c.circleStepDegrees, sign: engagedSign),
              s.abs > 0, abs(s.net) / s.abs >= c.circleEngagedConsistency else {
            disengage()
            return 0
        }
        return Int(engagedSign)
    }
}

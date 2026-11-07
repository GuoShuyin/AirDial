import Foundation

/// Turns the index fingertip into a pointer position and the thumb-index pinch into mouse button
/// presses. Pure logic: the app maps the normalized position onto the screens and posts events.
///
/// Position: the fingertip is mapped from a "reach" rectangle in the camera frame to [0, 1]²
/// (x: 0 = your left, y: 0 = bottom). The rectangle starts small around the centre of the frame
/// and grows to include wherever your fingertip goes, so the mapping calibrates itself as you
/// move: reaching your furthest comfortable point to the right takes the pointer to the right
/// edge of the rightmost screen.
///
/// Pinch: thumb tip close to the middle fingertip (or the index, see `pinchFinger`; relative to
/// the size of the hand) presses the button, opening them releases it. The pointer freezes at
/// where it was just before the pinch started, in case the pinch moves the index tip.
public struct PointerTracker {
    public enum Event: Equatable { case press, release }

    public private(set) var position: Vec2?     // normalized [0, 1]², y up
    public private(set) var pressed = false

    private var range: (minX: Double, maxX: Double, minY: Double, maxY: Double)?
    private var filter: OneEuroFilter2D
    private var history: [(t: Double, p: Vec2)] = []
    private var closedFrames = 0
    private var openFrames = 0
    private var frozenAt: Vec2?
    private var lastTip: Vec2?
    private var lastPalm: (t: Double, p: Vec2)?
    private var config: GestureConfig

    public init(config: GestureConfig = GestureConfig()) {
        self.config = config
        filter = OneEuroFilter2D(minCutoff: config.pointerMinCutoff, beta: config.pointerBeta)
    }

    /// Hand lost / pose changed: release the button if it was down, keep the calibration.
    public mutating func reset() -> Event? {
        let wasPressed = pressed
        position = nil
        pressed = false
        history.removeAll()
        closedFrames = 0
        openFrames = 0
        frozenAt = nil
        lastTip = nil
        lastPalm = nil
        filter.reset()
        return wasPressed ? .release : nil
    }

    /// Hand scale used for the pinch threshold: knuckle width, or index MCP-PIP length.
    static func handScale(_ s: HandSample) -> Double? {
        if let w = s.palmWidth, w > 1e-3 { return w }
        if let mcp = s.fingers[.index]?.mcp, let pip = s.fingers[.index]?.pip { return 2 * mcp.distance(to: pip) }
        return nil
    }

    /// `aspect` = frame width / height (x coordinates run from 0 to aspect).
    public mutating func update(_ s: HandSample, time t: Double, aspect: Double) -> Event? {
        guard let tip = s.tip(.index) else { return nil }
        let c = config

        // Pinch state with hysteresis and a couple of frames of debounce.
        var event: Event?
        var speed = Double.infinity
        if let palm = s.palmCenter {
            if let last = lastPalm, t > last.t { speed = palm.distance(to: last.p) / (t - last.t) }
            lastPalm = (t, palm)
        }
        if let thumb = s.thumbTip, s.thumbConfidence >= c.pinchMinThumbConfidence, let scale = PointerTracker.handScale(s),
           let pinchTip = s.tip(c.pinchFinger) {
            let d = thumb.distance(to: pinchTip) / scale
            // In between the two thresholds neither counter moves: a single slightly-off frame
            // in the middle of a pinch must not restart it.
            if d < c.pinchCloseRatio, pressed || speed < c.pinchMaxSpeed { closedFrames += 1; openFrames = 0 }
            else if d > c.pinchOpenRatio { openFrames += 1; closedFrames = 0 }
            else if speed >= c.pinchMaxSpeed { closedFrames = 0 }
            if !pressed, closedFrames >= c.pinchFrames {
                pressed = true
                event = .press
            } else if pressed, openFrames >= c.pinchReleaseFrames {
                pressed = false
                frozenAt = nil
                event = .release
            }
            // Freeze as soon as the fingers start closing, at where the pointer was before.
            if frozenAt == nil, d < c.pinchOpenRatio, let before = history.first(where: { t - $0.t <= c.pinchFreezeLookback }) {
                frozenAt = before.p
            } else if !pressed, d > c.pinchOpenRatio {
                frozenAt = nil
            }
        }

        // Self-calibrating reach rectangle.
        var r = range ?? (minX: aspect * (0.5 - c.pointerInitialReach / 2), maxX: aspect * (0.5 + c.pointerInitialReach / 2),
                          minY: 0.5 - c.pointerInitialReach / 2, maxY: 0.5 + c.pointerInitialReach / 2)
        // Only real, continuous motion grows it: a keypoint glitch (big jump) must not.
        let continuous = lastTip.map { tip.distance(to: $0) < c.pointerMaxJump } ?? false
        lastTip = tip
        if frozenAt == nil, continuous {
            r.minX = min(r.minX, tip.x); r.maxX = max(r.maxX, tip.x)
            r.minY = min(r.minY, tip.y); r.maxY = max(r.maxY, tip.y)
        }
        range = r
        let u = (tip.x - r.minX) / max(r.maxX - r.minX, 1e-3)
        let v = (tip.y - r.minY) / max(r.maxY - r.minY, 1e-3)
        let raw = Vec2(min(max(u, 0), 1), min(max(v, 0), 1))
        let p = filter.filter(raw, time: t)

        history.append((t, p))
        while let first = history.first, t - first.t > c.pinchFreezeLookback { history.removeFirst() }

        position = frozenAt ?? p
        return event
    }
}

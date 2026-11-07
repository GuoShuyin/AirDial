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
    public enum Event: Equatable { case press, release, rightClick }

    public private(set) var position: Vec2?     // normalized [0, 1]², y up
    /// Smoothed fingertip in camera coordinates (frozen during a pinch), for calibrated mapping.
    public private(set) var tip: Vec2?
    public private(set) var pressed = false

    private var range: (minX: Double, maxX: Double, minY: Double, maxY: Double)?
    private var filter: OneEuroFilter2D
    private var tipFilter: OneEuroFilter2D
    private var tipHistory: [(t: Double, p: Vec2)] = []
    private var frozenTip: Vec2?
    private var history: [(t: Double, p: Vec2)] = []
    private var closedFrames = 0
    private var openFrames = 0
    private var frozenAt: Vec2?
    private var lastTip: Vec2?
    private var lastPalm: (t: Double, p: Vec2)?
    // Recent thumb distances (3D) to the left / right click targets, for telling a tap (lift and
    // come down) from a thumb simply resting there.
    private var leftHistory: [(t: Double, d: Double)] = []
    private var rightHistory: [(t: Double, d: Double)] = []
    private var contactHistory: [(t: Double, d: Double)] = []   // thumb to the whole middle finger
    // Scrolling: the thumb sliding along the middle finger.
    private var lastArc: Double?
    private var contactSince: Double?
    private var slid = 0.0
    private var scrolling = false
    /// Scroll amount for this frame, pixels (+ = up). 0 when not scrolling.
    public private(set) var scroll: Double = 0
    private var rightFrames = 0
    private var rightLatched = false
    private var config: GestureConfig

    public init(config: GestureConfig = GestureConfig()) {
        self.config = config
        filter = OneEuroFilter2D(minCutoff: config.pointerMinCutoff, beta: config.pointerBeta)
        // Camera units span roughly half the range of the normalized position: twice the beta.
        tipFilter = OneEuroFilter2D(minCutoff: config.pointerMinCutoff, beta: config.pointerBeta * 2)
    }

    /// Hand lost / pose changed: release the button if it was down, keep the calibration.
    public mutating func reset() -> Event? {
        let wasPressed = pressed
        position = nil
        tip = nil
        pressed = false
        history.removeAll()
        tipHistory.removeAll()
        frozenTip = nil
        tipFilter.reset()
        closedFrames = 0
        openFrames = 0
        frozenAt = nil
        lastTip = nil
        lastPalm = nil
        rightFrames = 0
        rightLatched = false
        leftHistory.removeAll()
        rightHistory.removeAll()
        contactHistory.removeAll()
        lastArc = nil
        contactSince = nil
        slid = 0
        scrolling = false
        scroll = 0
        filter.reset()
        return wasPressed ? .release : nil
    }

    /// Closest point on a polyline: (distance, arc length from the first point).
    static func closest(_ p: Vec3, on pts: [Vec3]) -> (d: Double, arc: Double) {
        var best = (d: Double.infinity, arc: 0.0)
        var run = 0.0
        for i in 0..<(pts.count - 1) {
            let a = pts[i], b = pts[i + 1], ab = b - a
            let len2 = ab.dot(ab)
            let u = len2 > 1e-12 ? max(0, min(1, (p - a).dot(ab) / len2)) : 0
            let q = a + ab * u
            let d = p.distance(to: q)
            if d < best.d { best = (d, run + u * len2.squareRoot()) }
            run += len2.squareRoot()
        }
        return best
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
        scroll = 0
        var speed = Double.infinity
        if let palm = s.palmCenter {
            if let last = lastPalm, t > last.t { speed = palm.distance(to: last.p) / (t - last.t) }
            lastPalm = (t, palm)
        }
        // 3D: the real distance between the fingertips. 2D: relative to the knuckle width.
        var pinchDistance: (d: Double, close: Double, open: Double)?
        var freezeDistance: Double?       // nearest click target, for freezing the pointer
        var mustTap = false               // 3D: the thumb has to lift and come down (a tap)
        var leftTapped = false
        if let w = s.world, let tip3 = s.worldTip(c.pinchFinger) {
            let thumb = w[HandSample.worldThumbTip]
            let dL = thumb.distance(to: tip3)
            // Right click: thumb tip tapping the middle finger's second knuckle (PIP).
            let dR = c.enableRightClick ? thumb.distance(to: w[HandSample.worldJoints(.middle)[1]]) : Double.infinity
            leftHistory.append((t, dL)); rightHistory.append((t, dR))
            while let f = leftHistory.first, t - f.t > c.tapWindow { leftHistory.removeFirst() }
            while let f = rightHistory.first, t - f.t > c.tapWindow { rightHistory.removeFirst() }
            // Distance to the whole middle finger: lifting off it is a tap, sliding along it is not.
            let middle = HandSample.worldJoints(.middle).map { w[$0] }
            let contact = PointerTracker.closest(thumb, on: middle)
            contactHistory.append((t, contact.d))
            while let f = contactHistory.first, t - f.t > c.tapWindow { contactHistory.removeFirst() }
            let lifted = (contactHistory.map { $0.d }.max() ?? 0) - contact.d >= c.tapLift

            // Scroll wheel: thumb in contact with the middle finger, sliding along it.
            if c.enableScroll, contact.d < c.scrollContact3D {
                if contactSince == nil { contactSince = t }
                if let last = lastArc {
                    let delta = contact.arc - last
                    if abs(delta) < 0.02 { slid += delta }   // ignore glitches
                    if !scrolling, abs(slid) >= c.scrollDeadZone3D, t - (contactSince ?? t) >= 0.1 { scrolling = true; slid = 0 }
                    if scrolling, abs(delta) < 0.02 {
                        // Towards the fingertip (arc grows) = scroll up, like rolling a wheel forward.
                        scroll = delta * c.scrollPixelsPerMetre * (c.scrollReverse ? -1 : 1)
                    }
                }
                lastArc = contact.arc
            } else if contact.d > c.pinchOpen3D {
                lastArc = nil
                contactSince = nil
                slid = 0
                scrolling = false
            }

            // A tap: within the window the thumb was at least `tapLift` further from the finger than now
            // (and it isn't sliding along it).
            let tapOK = lifted && !scrolling
            if c.pinchFinger == .middle {
                leftTapped = tapOK && dL <= dR
            } else {
                leftTapped = (leftHistory.map { $0.d }.max() ?? 0) - dL >= c.tapLift && !scrolling
            }
            let rightTapped = tapOK && dR < dL
            freezeDistance = min(dL, dR)
            mustTap = true
            // The nearer target decides: a thumb on the knuckle is not also a left pinch.
            pinchDistance = (dL <= dR ? dL : max(dL, c.pinchClose3D + 1e-6), c.pinchClose3D, c.pinchOpen3D)

            if dR < c.pinchClose3D, dR < dL, speed < c.pinchMaxSpeed { rightFrames += 1 }
            else if dR > c.pinchOpen3D { rightFrames = 0; rightLatched = false }
            else { rightFrames = 0 }
            if !rightLatched, rightFrames >= c.pinchFrames3D, rightTapped {
                rightLatched = true
                event = .rightClick
            }
        } else if let thumb = s.thumbTip, s.thumbConfidence >= c.pinchMinThumbConfidence, let scale = PointerTracker.handScale(s),
                  let pinchTip = s.tip(c.pinchFinger) {
            pinchDistance = (thumb.distance(to: pinchTip) / scale, c.pinchCloseRatio, c.pinchOpenRatio)
        }
        if let (d, closeAt, openAt) = pinchDistance {
            // In between the two thresholds neither counter moves: a single slightly-off frame
            // in the middle of a pinch must not restart it.
            if d < closeAt, pressed || speed < c.pinchMaxSpeed { closedFrames += 1; openFrames = 0 }
            else if d > openAt { openFrames += 1; closedFrames = 0 }
            else if speed >= c.pinchMaxSpeed { closedFrames = 0 }
            if !pressed, closedFrames >= (mustTap ? c.pinchFrames3D : c.pinchFrames), !mustTap || leftTapped, event == nil {
                pressed = true
                event = .press
            } else if pressed, openFrames >= c.pinchReleaseFrames {
                pressed = false
                frozenAt = nil
                frozenTip = nil
                event = .release
            }
            // Freeze as soon as the fingers start closing, at where the pointer was before.
            let fd = freezeDistance ?? d
            if frozenAt == nil, fd < openAt, let before = history.first(where: { t - $0.t <= c.pinchFreezeLookback }) {
                frozenAt = before.p
                frozenTip = tipHistory.first(where: { t - $0.t <= c.pinchFreezeLookback })?.p
            } else if !pressed, !rightLatched, fd > openAt {
                frozenAt = nil
                frozenTip = nil
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

        let ft = tipFilter.filter(tip, time: t)
        tipHistory.append((t, ft))
        while let first = tipHistory.first, t - first.t > c.pinchFreezeLookback { tipHistory.removeFirst() }
        self.tip = frozenTip ?? ft
        return event
    }
}

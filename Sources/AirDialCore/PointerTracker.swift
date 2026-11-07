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
    // Recent thumb distances (3D) to the middle finger, for telling a tap (lift and come down)
    // from a thumb simply resting there.
    private var contactHistory: [(t: Double, d: Double)] = []   // thumb to the whole middle finger
    // Scrolling: the thumb sliding along the middle finger.
    private var lastArc: Double?
    private var slid = 0.0
    /// Scroll amount for this frame, pixels (+ = up). 0 when not scrolling.
    public private(set) var scroll: Double = 0
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
        contactHistory.removeAll()
        lastArc = nil
        slid = 0
        scroll = 0
        tapState = .idle
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

    // MARK: 3D taps and scrolling on the middle finger

    private enum TapState {
        case idle
        case pending(target: Event, arc: Double, since: Double)   // touched: click unless it slides
        case scrolling
        case latched                                              // clicked: wait for the thumb to lift
    }
    private var tapState: TapState = .idle

    /// The thumb tip against the middle finger (MCP -> PIP -> DIP -> tip):
    /// - lift it off and tap it down near the second knuckle (PIP) = right click,
    ///   near the first knuckle (DIP, by the fingertip) = left click;
    /// - a tap is only a click if the thumb doesn't then slide along the finger (that is scrolling);
    /// - slide it along the finger = scroll wheel; a thumb merely resting there does nothing.
    private mutating func update3D(_ s: HandSample, time t: Double) -> Event? {
        let c = config
        guard let w = s.world else { return nil }
        let thumb = w[HandSample.worldThumbTip]
        let mj = HandSample.worldJoints(.middle).map { w[$0] }   // MCP, PIP, DIP, tip
        let contact = PointerTracker.closest(thumb, on: mj)
        let arcPIP = mj[0].distance(to: mj[1])
        let arcDIP = arcPIP + mj[1].distance(to: mj[2])
        let arcTip = arcDIP + mj[2].distance(to: mj[3])
        let leftArc = c.leftClickAtFingertip ? arcTip : arcDIP

        contactHistory.append((t, contact.d))
        while let f = contactHistory.first, t - f.t > c.tapWindow { contactHistory.removeFirst() }
        let lifted = (contactHistory.map { $0.d }.max() ?? 0) - contact.d >= c.tapLift
        let touching = contact.d < c.pinchClose3D
        let off = contact.d > c.pinchOpen3D
        defer { lastArc = touching ? contact.arc : nil }

        func freeze() {
            guard frozenAt == nil else { return }
            frozenAt = history.first(where: { t - $0.t <= c.pinchFreezeLookback })?.p ?? position
            frozenTip = tipHistory.first(where: { t - $0.t <= c.pinchFreezeLookback })?.p ?? tip
        }
        func unfreeze() { frozenAt = nil; frozenTip = nil }
        func scrollStep() {
            guard c.enableScroll, let last = lastArc else { return }
            let delta = contact.arc - last
            guard abs(delta) < 0.02 else { return }   // glitch
            // Towards the fingertip (arc grows) = scroll up, like rolling a wheel forward.
            scroll = delta * c.scrollPixelsPerMetre * (c.scrollReverse ? -1 : 1)
        }

        switch tapState {
        case .idle:
            unfreeze()
            guard touching else { slid = 0; return nil }
            if lifted {
                // Which knuckle is it nearer to along the finger?
                let right = c.enableRightClick && abs(contact.arc - arcPIP) < abs(contact.arc - leftArc)
                tapState = .pending(target: right ? .rightClick : .press, arc: contact.arc, since: t)
                freeze()
                return nil
            }
            // Resting: only sliding along the finger does something (scroll).
            if let last = lastArc { slid += contact.arc - last }
            if c.enableScroll, abs(slid) >= c.scrollDeadZone3D { tapState = .scrolling; freeze(); slid = 0 }
            return nil

        case let .pending(target, arc0, since):
            if abs(contact.arc - arc0) > c.tapSlideCancel3D {
                tapState = c.enableScroll ? .scrolling : .latched    // it slid: scrolling, not a click
                return nil
            }
            if off || t - since >= c.tapConfirm {
                tapState = off ? .idle : .latched
                if off { unfreeze() }
                return target
            }
            return nil

        case .scrolling:
            if off { tapState = .idle; unfreeze(); return nil }
            if touching { scrollStep() }
            return nil

        case .latched:
            if off { tapState = .idle; unfreeze() }
            return nil
        }
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
        if s.world != nil {
            event = update3D(s, time: t)
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
            if !pressed, closedFrames >= c.pinchFrames, event == nil {
                pressed = true
                event = .press
            } else if pressed, openFrames >= c.pinchReleaseFrames {
                pressed = false
                frozenAt = nil
                frozenTip = nil
                event = .release
            }
            // Freeze as soon as the fingers start closing, at where the pointer was before.
            let fd = d
            if frozenAt == nil, fd < openAt, let before = history.first(where: { t - $0.t <= c.pinchFreezeLookback }) {
                frozenAt = before.p
                frozenTip = tipHistory.first(where: { t - $0.t <= c.pinchFreezeLookback })?.p
            } else if !pressed, fd > openAt {
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

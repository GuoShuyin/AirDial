import Foundation

/// Open palm -> fist ("grab") and fist -> open palm ("release") as one-shot gestures.
///
/// Both shapes must be seen for `handShapeFrames` frames in a row with the palm facing the
/// camera (wide knuckles), and the second shape must follow the first within `handShapeGap`.
/// After a grab fires, the hand is "spent": relaxing the fist open again (the natural thing to
/// do) must not immediately fire a release. Further palm/fist changes are ignored until the hand
/// shows something else or leaves the frame for `handShapeResetTime`. After a release, closing
/// the hand again is a deliberate grab and works straight away.
public struct HandShapeTransition {
    public enum Kind: Equatable { case grab, release }

    private var current: HandPose = .none   // shape of the current run (.openPalm / .fist / other)
    private var runFrames = 0
    private var runStart: Double = 0
    private var lastConfirmed: (pose: HandPose, end: Double)?  // last confirmed palm / fist run
    private var spent = false
    private var otherSince: Double?

    public init() {}

    public mutating func add(raw: HandPose, sample: HandSample?, time t: Double, config c: GestureConfig) -> Kind? {
        let wide = (sample?.palmWidth ?? 0) >= c.palmMinWidth
        let shape: HandPose = (raw == .openPalm || raw == .fist) && wide ? raw : .other

        if shape == .other {
            // Something else, or nothing: after a while the hand is fresh again.
            let since = otherSince ?? t
            otherSince = since
            if t - since >= c.handShapeResetTime {
                spent = false
                lastConfirmed = nil
            }
            if current != .other {
                if runFrames >= c.handShapeFrames { lastConfirmed = (current, t) }
                current = .other
                runFrames = 0
            }
            return nil
        }
        otherSince = nil

        if shape != current {
            if current == .openPalm || current == .fist, runFrames >= c.handShapeFrames {
                lastConfirmed = (current, t)
            }
            current = shape
            runFrames = 0
            runStart = t
        }
        runFrames += 1
        guard runFrames == c.handShapeFrames else {
            if runFrames > c.handShapeFrames { lastConfirmed = (current, t) }
            return nil
        }

        // The current shape just got confirmed. Did the other one come right before it?
        defer { lastConfirmed = (current, t) }
        guard let prev = lastConfirmed, prev.pose != current, runStart - prev.end <= c.handShapeGap else { return nil }
        if spent { return nil }
        spent = current == .fist
        return current == .fist ? .grab : .release
    }
}

import Foundation

public enum Finger: CaseIterable {
    case index, middle, ring, little
}

/// The joints AirDial needs from one hand, already converted to user-view coordinates.
/// Any joint may be nil if the hand-pose model was not confident about it.
public struct HandSample {
    public struct FingerJoints {
        public var tip: Vec2?
        public var pip: Vec2?
        public var mcp: Vec2?

        public init(tip: Vec2?, pip: Vec2?, mcp: Vec2?) {
            self.tip = tip
            self.pip = pip
            self.mcp = mcp
        }
    }

    public var time: Double
    public var wrist: Vec2?
    public var fingers: [Finger: FingerJoints]
    public var thumbTip: Vec2?
    /// Vision's confidence in the thumb tip (the thumb is often guessed when hidden behind the hand).
    public var thumbConfidence: Float

    public init(time: Double, wrist: Vec2?, fingers: [Finger: FingerJoints], thumbTip: Vec2? = nil, thumbConfidence: Float = 1) {
        self.time = time
        self.wrist = wrist
        self.fingers = fingers
        self.thumbTip = thumbTip
        self.thumbConfidence = thumbConfidence
    }

    public func tip(_ f: Finger) -> Vec2? { fingers[f]?.tip }
}

public enum HandPose: String {
    case none        // no hand
    case point       // only index finger extended  -> circle = volume
    case twoFingers  // index + middle extended     -> swipe = track
    case openPalm    // index + middle + ring extended -> sideways swipe = switch desktop
    case other       // open palm, fist, etc.
}

public enum FingerState {
    case extended, curled, unknown
}

public enum PoseClassifier {
    /// A finger is "extended" when its tip is clearly farther from the wrist than its PIP joint.
    /// Using ratios of distances makes this independent of how far the hand is from the camera.
    public static func state(of f: Finger, in s: HandSample, config: GestureConfig) -> FingerState {
        guard let wrist = s.wrist, let j = s.fingers[f], let tip = j.tip, let pip = j.pip else {
            return .unknown
        }
        let dTip = tip.distance(to: wrist)
        let dPip = pip.distance(to: wrist)
        guard dPip > 1e-4 else { return .unknown }
        let ratio = dTip / dPip
        if ratio >= config.extendedRatio { return .extended }
        if ratio <= config.curledRatio { return .curled }
        // Ambiguous zone: use the MCP as a second opinion if available.
        if let mcp = j.mcp {
            let dMcp = mcp.distance(to: wrist)
            if dMcp > 1e-4, dTip / dMcp < 1.25 { return .curled }
        }
        return .unknown
    }

    public static func classify(_ s: HandSample?, config: GestureConfig) -> HandPose {
        guard let s = s, s.wrist != nil, s.tip(.index) != nil else { return .none }
        let index = state(of: .index, in: s, config: config)
        let middle = state(of: .middle, in: s, config: config)
        let ring = state(of: .ring, in: s, config: config)
        let little = state(of: .little, in: s, config: config)

        // "unknown" on ring/little is tolerated as long as it is not "extended":
        // those fingers are often partly hidden when folded.
        let ringFolded = ring != .extended
        let littleFolded = little != .extended

        if index == .extended, middle == .extended, ring == .extended, little != .curled {
            return .openPalm
        }
        if index == .extended, middle == .extended, ringFolded, littleFolded, ring == .curled || little == .curled {
            return .twoFingers
        }
        if index == .extended, middle == .curled, ringFolded, littleFolded {
            return .point
        }
        return .other
    }
}

extension HandSample {
    /// Mean of the fingertips: moves much more than the palm centre in a quick wrist flick.
    public var fingertipCenter: Vec2? {
        let tips = Finger.allCases.compactMap { fingers[$0]?.tip }
        guard !tips.isEmpty else { return nil }
        let n = Double(tips.count)
        return Vec2(tips.reduce(0) { $0 + $1.x } / n, tips.reduce(0) { $0 + $1.y } / n)
    }

    /// Index MCP to little MCP distance: how wide the palm looks. Large when the palm faces the
    /// camera from up close (a deliberate gesture), small when it is edge-on or far away.
    public var palmWidth: Double? {
        guard let a = fingers[.index]?.mcp, let b = fingers[.little]?.mcp else { return nil }
        return a.distance(to: b)
    }

    /// Centre of the palm: mean of the finger MCP joints (the wrist is often out of frame).
    public var palmCenter: Vec2? {
        let mcps = Finger.allCases.compactMap { fingers[$0]?.mcp }
        guard !mcps.isEmpty else { return wrist }
        let n = Double(mcps.count)
        return Vec2(mcps.reduce(0) { $0 + $1.x } / n, mcps.reduce(0) { $0 + $1.y } / n)
    }
}

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
    /// 3D joints in metres around the hand's centre, when the tracker provides them (MediaPipe),
    /// in MediaPipe order: 0 wrist, 1-4 thumb (CMC, MCP, IP, tip), then MCP, PIP, DIP, tip for
    /// index (5-8), middle (9-12), ring (13-16) and little finger (17-20).
    public var world: [Vec3]?

    public init(time: Double, wrist: Vec2?, fingers: [Finger: FingerJoints], thumbTip: Vec2? = nil, thumbConfidence: Float = 1,
                world: [Vec3]? = nil) {
        self.time = time
        self.wrist = wrist
        self.fingers = fingers
        self.thumbTip = thumbTip
        self.thumbConfidence = thumbConfidence
        self.world = world.flatMap { $0.count == 21 ? $0 : nil }
    }

    /// World joint indices (MCP, PIP, DIP, tip) of a finger.
    public static func worldJoints(_ f: Finger) -> [Int] {
        switch f {
        case .index: return [5, 6, 7, 8]
        case .middle: return [9, 10, 11, 12]
        case .ring: return [13, 14, 15, 16]
        case .little: return [17, 18, 19, 20]
        }
    }
    public static let worldThumbTip = 4
    public static let worldWrist = 0

    /// 3D tip position of a finger.
    public func worldTip(_ f: Finger) -> Vec3? { world.map { $0[HandSample.worldJoints(f)[3]] } }

    /// How much a finger is bent, degrees: angle at the PIP plus angle at the DIP (3D only).
    /// About 0-40 for a straight finger, 150+ for a finger curled into a fist.
    public func bend(_ f: Finger) -> Double? {
        guard let w = world else { return nil }
        let j = HandSample.worldJoints(f).map { w[$0] }
        return (j[1] - j[0]).angle(to: j[2] - j[1]) + (j[2] - j[1]).angle(to: j[3] - j[2])
    }

    public func tip(_ f: Finger) -> Vec2? { fingers[f]?.tip }
}

public enum HandPose: String {
    case none        // no hand
    case point       // only index finger extended  -> circle = volume
    case twoFingers  // index + middle extended     -> swipe = track
    case openPalm    // index + middle + ring extended -> sideways swipe = switch desktop
    case fist        // all fingers curled                -> palm <-> fist = minimize / full screen
    case thumbsUp    // fist with the thumb up (3D only)  -> hold the Fn / Globe key
    case other       // open palm, fist, etc.
}

public enum FingerState {
    case extended, curled, unknown
}

public enum PoseClassifier {
    /// A finger is "extended" when its tip is clearly farther from the wrist than its PIP joint.
    /// Using ratios of distances makes this independent of how far the hand is from the camera.
    public static func state(of f: Finger, in s: HandSample, config: GestureConfig) -> FingerState {
        // With 3D joints the bend angle decides, which doesn't depend on the viewing angle.
        if let b = s.bend(f) {
            if b <= config.bendExtendedMax { return .extended }
            if b >= config.bendCurledMin { return .curled }
            return .unknown
        }
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
        if let pose = classify3D(s, config: config) { return pose }
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
        // 3D: a waving hand is relaxed (fingers bent 60-80 degrees), so for the open palm it's
        // enough that no finger is anywhere near curled.
        if let bends = Optional(Finger.allCases.compactMap { s.bend($0) }), bends.count == 4,
           bends.allSatisfy({ $0 < config.palmOpenBendMax }) {
            return .openPalm
        }
        if index == .extended, middle == .extended, ringFolded, littleFolded, ring == .curled || little == .curled {
            return .twoFingers
        }
        if index == .extended, middle == .curled, ringFolded, littleFolded {
            return .point
        }
        if index == .curled, middle == .curled, ringFolded, littleFolded, ring == .curled || little == .curled {
            return .fist
        }
        return .other
    }
}

extension PoseClassifier {
    /// 3D-only shapes and refinements; nil = use the general rules.
    static func classify3D(_ s: HandSample, config c: GestureConfig) -> HandPose? {
        guard let w = s.world, let bi = s.bend(.index), let bm = s.bend(.middle),
              let br = s.bend(.ring), let bl = s.bend(.little) else { return nil }
        let othersCurled = bm >= c.bendCurledMin && br >= c.bendCurledMin - 10 && bl >= c.bendCurledMin - 10
        if bi >= c.bendCurledMin, othersCurled {
            // A fist; with the thumb sticking out upwards it's a thumbs-up.
            let thumbOut = w[4].distance(to: w[5]) >= c.thumbsUpOut3D
            let thumbUp = w[4].y - w[2].y >= c.thumbsUpRise3D
            return thumbOut && thumbUp ? .thumbsUp : .fist
        }
        // Pointing down / towards the camera bends the index in the estimate (~90 degrees at the
        // camera display's bottom corners) while the other fingers stay curled: still pointing.
        if bi < c.bendCurledMin, othersCurled { return .point }
        return nil
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

    /// 3D: how squarely the palm faces the camera, 0 (edge-on) ... 1 (flat to the camera).
    public var palmFacing: Double? {
        guard let w = world else { return nil }
        let n = (w[5] - w[0]).cross(w[17] - w[0])
        let len = n.length
        return len > 1e-9 ? abs(n.z) / len : nil
    }

    /// A deliberate palm gesture: the palm flat to the camera from up close. With 3D joints:
    /// facing the camera and not tiny; with 2D only: wide enough in the picture.
    public func palmIsDeliberate(_ c: GestureConfig) -> Bool {
        if let f = palmFacing {
            return f >= c.palmMinFacing3D && (palmWidth ?? 0) >= c.palmMinWidth3D
        }
        return (palmWidth ?? 0) >= c.palmMinWidth
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

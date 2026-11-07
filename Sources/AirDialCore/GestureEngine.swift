import Foundation

public enum GestureAction: String {
    case volumeUp, volumeDown, nextTrack, previousTrack
    case desktopLeft, desktopRight
    case missionControl
}

/// What the engine is doing right now (for the on-screen overlay).
public struct GestureStatus {
    public var pose: HandPose = .none
    public var rawPose: HandPose = .none
    public var cursor: Vec2?          // smoothed point being tracked
    public var circleDegrees: Double = 0
    public var circleEngaged = false
    public var palmArmed = false

    public init() {}
}

/// Turns a stream of hand samples into actions.
/// Pipeline: classify pose -> debounce pose -> smooth point -> circle / swipe detector -> lockouts.
public final class GestureEngine {
    public var config: GestureConfig
    public private(set) var status = GestureStatus()

    private var activePose: HandPose = .none
    private var candidatePose: HandPose = .none
    private var candidateCount = 0
    private var lastActiveSeen: Double = -.infinity

    private var filter: OneEuroFilter2D
    private var circle = CircleTracker()
    private var swipe = SwipeDetector()
    private var palmSwipe = SwipeDetector()
    private var palmFilter: OneEuroFilter2D
    private var palmBlockedUntil: Double = -.infinity
    private var lastPalm: (p: Vec2, t: Double)?
    private var lastPalmRaw: Vec2?
    private var palmStillSince: Double?
    private var palmArmedUntil: Double = -.infinity
    private var circleBlockedUntil: Double = -.infinity
    private var swipeBlockedUntil: Double = -.infinity

    public init(config: GestureConfig = GestureConfig()) {
        self.config = config
        filter = OneEuroFilter2D(minCutoff: config.filterMinCutoff, beta: config.filterBeta)
        palmFilter = OneEuroFilter2D(minCutoff: config.filterMinCutoff, beta: config.filterBeta)
    }

    /// Feed one camera frame. `sample` is nil when no hand was detected.
    public func process(_ sample: HandSample?, time: Double) -> [GestureAction] {
        let raw = PoseClassifier.classify(sample, config: config)
        status.rawPose = raw
        updatePose(raw, time: time)
        status.pose = activePose

        var actions: [GestureAction] = []

        switch activePose {
        case .point:
            guard let s = sample, let tip = s.tip(.index) else { break }
            let p = filter.filter(tip, time: time)
            status.cursor = p
            let steps = circle.add(p, time: time, config: config)
            if steps != 0, time >= circleBlockedUntil {
                // steps > 0 = counter-clockwise (y up, mirrored view = as the user sees it)
                let clockwise = steps < 0
                let up = clockwise == config.clockwiseIsVolumeUp
                actions.append(up ? .volumeUp : .volumeDown)
                swipeBlockedUntil = time + config.crossGestureLockout
                palmBlockedUntil = time + config.crossGestureLockout
            }
        case .twoFingers:
            guard let s = sample, let a = s.tip(.index), let b = s.tip(.middle) else { break }
            let p = filter.filter(Vec2.midpoint(a, b), time: time)
            status.cursor = p
            if let dir = swipe.add(p, time: time, config: config), time >= swipeBlockedUntil {
                if let action = action(for: dir) {
                    actions.append(action)
                    circleBlockedUntil = time + config.crossGestureLockout
                    palmBlockedUntil = time + config.crossGestureLockout
                }
            }
        case .openPalm:
            guard config.enablePalmSwipe, let s = sample, let c = s.palmCenter else { break }
            let p = palmFilter.filter(c, time: time)
            status.cursor = p
            defer { lastPalmRaw = c }
            if let prevRaw = lastPalmRaw, c.distance(to: prevRaw) > config.palmMaxJump {
                // Keypoint glitch: drop the motion so far instead of treating the jump as a swipe.
                palmFilter.reset()
                palmSwipe.resetMotion()
                palmStillSince = nil
                palmArmedUntil = -.infinity
                lastPalm = nil
                status.cursor = c
                break
            }
            if let last = lastPalm, time > last.t {
                let speed = p.distance(to: last.p) / (time - last.t)
                if speed < config.palmStillSpeed, p.y >= config.palmMinHeight {
                    let since = palmStillSince ?? time
                    palmStillSince = since
                    if time - since >= config.palmArmSeconds { palmArmedUntil = time + config.palmArmedWindow }
                } else {
                    palmStillSince = nil
                }
            }
            lastPalm = (p, time)
            status.palmArmed = time <= palmArmedUntil
            var pc = config
            pc.enableVerticalSwipe = config.enablePalmVerticalSwipe
            pc.enableHorizontalSwipe = true
            pc.swipeMinDistance = config.palmSwipeMinDistance
            let armed = time <= palmArmedUntil && time >= palmBlockedUntil
            if !armed { palmSwipe.observe(p, time: time, config: pc) }
            if armed, let dir = palmSwipe.add(p, time: time, config: pc) {
                palmArmedUntil = -.infinity
                palmStillSince = nil
                switch dir {
                case .up, .down:
                    actions.append(.missionControl)
                case .left, .right:
                    let goLeft = (dir == .right) == config.palmRightGoesLeft
                    actions.append(goLeft ? .desktopLeft : .desktopRight)
                }
                circleBlockedUntil = time + config.crossGestureLockout
                swipeBlockedUntil = time + config.crossGestureLockout
            }
        case .none, .other:
            status.cursor = nil
        }

        status.circleDegrees = circle.displayDegrees
        status.circleEngaged = circle.engaged
        return actions
    }

    private func action(for dir: SwipeDirection) -> GestureAction? {
        switch dir {
        case .up: return config.verticalSwipeAlwaysNext || config.swipeUpIsNext ? .nextTrack : .previousTrack
        case .down: return config.verticalSwipeAlwaysNext || !config.swipeUpIsNext ? .nextTrack : .previousTrack
        case .right: return .nextTrack
        case .left: return .previousTrack
        }
    }

    private func updatePose(_ raw: HandPose, time: Double) {
        if raw == activePose {
            lastActiveSeen = time
            candidatePose = raw
            candidateCount = 0
            return
        }
        if raw == candidatePose {
            candidateCount += 1
        } else {
            candidatePose = raw
            candidateCount = 1
        }

        let isGesturePose = raw == .point || raw == .twoFingers || raw == .openPalm
        let switchNow: Bool
        if isGesturePose {
            let fromGesture = activePose == .point || activePose == .twoFingers || activePose == .openPalm
            switchNow = candidateCount >= (fromGesture ? config.poseSwitchFrames : config.poseConfirmFrames)
        } else {
            // Leaving a gesture pose is slower: tolerate a few misread frames mid-gesture.
            switchNow = time - lastActiveSeen > config.poseDropSeconds
        }
        if switchNow {
            activePose = raw
            lastActiveSeen = time
            candidateCount = 0
            circle.reset()
            swipe.resetMotion()
            palmSwipe.resetMotion()
            filter.reset()
            palmFilter.reset()
            lastPalm = nil
            lastPalmRaw = nil
            palmStillSince = nil
            palmArmedUntil = -.infinity
        }
    }
}

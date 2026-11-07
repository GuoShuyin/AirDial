import Foundation

public enum GestureAction: String {
    case volumeUp, volumeDown, nextTrack, previousTrack
    case desktopLeft, desktopRight
    case missionControl
    case pointerPress, pointerRelease   // thumb-middle tap: click / fingers opened again
    case pointerRightClick              // thumb taps the middle finger's second knuckle
    case exitFullScreen                 // open palm -> fist ("grab")
    case enterFullScreen                // fist -> open palm ("release")
}

/// What the engine is doing right now (for the on-screen overlay).
public struct GestureStatus {
    public var pose: HandPose = .none
    public var rawPose: HandPose = .none
    public var cursor: Vec2?          // smoothed point being tracked
    public var circleDegrees: Double = 0
    public var circleEngaged = false
    public var palmArmed = false
    public var pointer: Vec2?          // normalized [0, 1]², y up; nil = not pointing
    public var pointerTip: Vec2?       // smoothed fingertip, camera coordinates (for calibration)
    public var scroll: Double = 0      // pixels to scroll this frame (+ = up)
    public var pointerPressed = false
    public var knobDegrees: Double = 0
    public var fingersTogether = false

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
    private var pointer: PointerTracker
    private var knob = KnobTracker()
    private var fingersTogether = false
    private var handShape = HandShapeTransition()
    private var handShapeBlockedUntil: Double = -.infinity
    private var knobBlockedUntil: Double = -.infinity
    private var lastFistSeen: Double = -.infinity
    private var pendingPalm: (action: GestureAction, time: Double)?
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
        pointer = PointerTracker(config: config)
    }

    /// Feed one camera frame. `sample` is nil when no hand was detected.
    /// `aspect` = camera frame width / height (sample x coordinates run from 0 to aspect).
    public func process(_ sample: HandSample?, time: Double, aspect: Double = 4.0 / 3.0) -> [GestureAction] {
        let raw = PoseClassifier.classify(sample, config: config)
        status.rawPose = raw
        updatePose(raw, time: time)
        status.pose = activePose

        var actions: [GestureAction] = []

        // Open palm <-> fist (uses the raw shape: these are quick changes, not held poses).
        // While pointing / circling or using two fingers, palm and fist readings are misreads.
        let shapeRaw = activePose == .point || activePose == .twoFingers ? HandPose.other : raw
        if raw == .fist { lastFistSeen = time }
        if config.enableHandShapes, let kind = handShape.add(raw: shapeRaw, sample: sample, time: time, config: config),
           time >= handShapeBlockedUntil {
            actions.append(kind == .grab ? .exitFullScreen : .enterFullScreen)
            pendingPalm = nil
            knobBlockedUntil = time + config.crossGestureLockout
            palmBlockedUntil = time + config.handShapeSwipeLockout
            circleBlockedUntil = time + config.crossGestureLockout
            swipeBlockedUntil = time + config.crossGestureLockout
        }

        // Pointer: follows the index fingertip while the one-finger pose is active.
        if config.enablePointer {
            if activePose == .point, let s = sample {
                switch pointer.update(s, time: time, aspect: aspect) {
                case .press?: actions.append(.pointerPress)
                case .release?: actions.append(.pointerRelease)
                case .rightClick?: actions.append(.pointerRightClick)
                case nil: break
                }
            } else if activePose != .point, status.pointer != nil || pointer.pressed {
                if pointer.reset() == .release { actions.append(.pointerRelease) }
            }
            status.pointer = activePose == .point ? pointer.position : nil
            status.pointerTip = activePose == .point ? pointer.tip : nil
            status.scroll = activePose == .point ? pointer.scroll : 0
            status.pointerPressed = pointer.pressed
        }

        switch activePose {
        case .point:
            guard config.enableCircleVolume, let s = sample, let tip = s.tip(.index) else { break }
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

            // Together (side by side) = circle for volume; apart (a V) = swipe for tracks.
            if config.enableTwoFingerCircle, let spread = fingerSpread(s) {
                let wasTogether = fingersTogether
                if spread.d < spread.together { fingersTogether = true } else if spread.d > spread.apart { fingersTogether = false }
                if wasTogether != fingersTogether { circle.reset(); swipe.resetMotion() }
            }
            status.fingersTogether = fingersTogether
            if fingersTogether && config.enableTwoFingerCircle {
                let steps = circle.add(p, time: time, config: config)
                if steps != 0, time >= circleBlockedUntil {
                    let clockwise = steps < 0
                    actions.append(clockwise == config.clockwiseIsVolumeUp ? .volumeUp : .volumeDown)
                    swipeBlockedUntil = time + config.crossGestureLockout
                    palmBlockedUntil = time + config.crossGestureLockout
                }
                status.circleDegrees = circle.displayDegrees
                status.circleEngaged = circle.engaged
                break
            }
            if let dir = swipe.add(p, time: time, config: config), time >= swipeBlockedUntil {
                if let action = action(for: dir) {
                    actions.append(action)
                    knob.reset()
                    knobBlockedUntil = time + config.crossGestureLockout
                    circleBlockedUntil = time + config.crossGestureLockout
                    palmBlockedUntil = time + config.crossGestureLockout
                }
            }
        case .openPalm:
            guard config.enablePalmSwipe, let s = sample,
                  let c = config.palmTrackFingertips ? s.fingertipCenter : s.palmCenter else { break }
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
                let still = !config.palmRequireHold || speed < config.palmStillSpeed
                if still, p.y >= config.palmMinHeight, (s.palmWidth ?? 0) >= config.palmMinWidth {
                    let since = palmStillSince ?? time
                    palmStillSince = since
                    if !config.palmRequireHold || time - since >= config.palmArmSeconds {
                        palmArmedUntil = time + config.palmArmedWindow
                    }
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
            pc.swipeWindow = config.palmSwipeWindow
            let armed = time <= palmArmedUntil && time >= palmBlockedUntil
            if !armed { palmSwipe.observe(p, time: time, config: pc) }
            if armed, let dir = palmSwipe.add(p, time: time, config: pc) {
                palmArmedUntil = -.infinity
                palmStillSince = nil
                let action: GestureAction
                switch dir {
                case .up, .down:
                    action = .missionControl
                case .left, .right:
                    let goLeft = (dir == .right) == config.palmRightGoesLeft
                    action = goLeft ? .desktopLeft : .desktopRight
                }
                // A fist just before means the hand was closing / opening, not swiping.
                if time - lastFistSeen > config.palmFistExclusion {
                    pendingPalm = (action, time)
                    handShapeBlockedUntil = time + config.crossGestureLockout
                }
            }
        case .none, .other, .fist:
            status.cursor = nil
        }

        // Knob: thumb + index + middle held in place and turned.
        if config.enableKnob {
            let step = knob.add(sample, time: time, config: config)
            if step != 0, time >= knobBlockedUntil {
                actions.append(step > 0 ? .volumeUp : .volumeDown)
                swipeBlockedUntil = time + config.crossGestureLockout
                palmBlockedUntil = time + config.crossGestureLockout
            }
            status.knobDegrees = knob.progress
        }

        // Act on a palm swipe once the hand stayed open for a moment; a fist cancels it.
        if let pending = pendingPalm {
            if lastFistSeen >= pending.time {
                pendingPalm = nil
            } else if time - pending.time >= config.palmSwipeConfirm {
                actions.append(pending.action)
                pendingPalm = nil
                knobBlockedUntil = time + config.crossGestureLockout
                handShapeBlockedUntil = time + config.crossGestureLockout
                circleBlockedUntil = time + config.crossGestureLockout
                swipeBlockedUntil = time + config.crossGestureLockout
            }
        }

        status.circleDegrees = circle.displayDegrees
        status.circleEngaged = circle.engaged
        return actions
    }

    /// Index-middle fingertip spread with the together / apart thresholds for it.
    private func fingerSpread(_ s: HandSample) -> (d: Double, together: Double, apart: Double)? {
        if let a = s.worldTip(.index), let b = s.worldTip(.middle) {
            return (a.distance(to: b), config.fingersTogether3D, config.fingersApart3D)
        }
        guard let a = s.tip(.index), let b = s.tip(.middle), let w = s.palmWidth, w > 1e-3 else { return nil }
        return (a.distance(to: b) / w, config.fingersTogether2D, config.fingersApart2D)
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

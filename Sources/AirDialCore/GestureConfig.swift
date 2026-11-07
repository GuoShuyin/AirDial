import Foundation

/// All tunable thresholds in one place. Distances are in units of image height
/// (1.0 = full camera frame height). Angles are in degrees, times in seconds.
public struct GestureConfig {
    // MARK: Pose classification
    /// tip-to-wrist / pip-to-wrist above this => finger extended.
    public var extendedRatio: Double = 1.12
    /// tip-to-wrist / pip-to-wrist below this => finger curled.
    public var curledRatio: Double = 0.98
    /// Frames a new pose must be seen in a row before it becomes active.
    public var poseConfirmFrames: Int = 3
    /// Same, when switching straight from one gesture pose to another. Longer, because the
    /// model briefly misreads a pointing finger as an open hand (~12% of frames on a webcam).
    public var poseSwitchFrames: Int = 10
    /// Seconds without seeing the active pose (no hand / other pose) before it is dropped.
    /// Time-based, not frame-based: the model misreads the finger for several frames in a row
    /// whenever it turns towards the camera mid-circle, and that must not reset the circle.
    public var poseDropSeconds: Double = 0.5

    // MARK: Circle (one finger) -> volume
    /// Total rotation needed before the first volume step fires.
    /// Large on purpose so random hand movement never triggers it.
    public var circleStartDegrees: Double = 270
    /// Additional rotation per extra volume step once the knob is "engaged".
    /// 360 = one volume step per loop (N loops -> N steps, the first one at `circleStartDegrees`).
    public var circleStepDegrees: Double = 360
    /// Fingertip path is resampled every `circleMinStep` so jitter doesn't add rotation.
    public var circleMinStep: Double = 0.012
    /// A single turn larger than this between two samples is treated as noise.
    public var circleMaxTurnDegrees: Double = 100
    /// Minimum circle diameter (bounding box) required to start.
    public var circleMinDiameter: Double = 0.07
    /// How far back (seconds) the start check looks. Slow circles need a longer window.
    public var circleWindow: Double = 3.0
    /// |net rotation| / total |rotation| needed to start (1.0 = perfectly one-directional).
    public var circleConsistency: Double = 0.85
    /// Same check while the knob is engaged (more lenient).
    public var circleEngagedConsistency: Double = 0.6
    /// Bounding box short side / long side must be at least this (rejects flat ellipses / lines).
    public var circleMinAspect: Double = 0.45
    /// std(radius) / mean(radius) must be at most this (rejects squiggles).
    public var circleMaxRadiusSpread: Double = 0.25
    /// Turning back by this much from the furthest point reached disengages the knob.
    public var circleReverseDegrees: Double = 120
    /// Finger standing still this long resets the circle.
    public var circleIdleReset: Double = 0.6
    /// true: clockwise (as you see it) = volume up, like BMW.
    public var clockwiseIsVolumeUp: Bool = true

    // MARK: Two-finger swipe -> track
    /// Time window the swipe must happen within.
    public var swipeWindow: Double = 0.45
    /// Minimum travel distance of the two fingertips within the window.
    public var swipeMinDistance: Double = 0.16
    /// Main axis travel must exceed cross axis travel by this factor.
    public var swipeAxisRatio: Double = 1.8
    /// No new swipe for this long after one fired.
    public var swipeCooldown: Double = 0.8
    /// Swipe in the opposite direction is blocked this long (prevents the
    /// "bring your hand back" motion from undoing the swipe).
    public var swipeReturnLockout: Double = 1.4
    public var enableVerticalSwipe: Bool = true
    public var enableHorizontalSwipe: Bool = true
    /// true: two fingers up = next track, down = previous track.
    public var swipeUpIsNext: Bool = true

    // MARK: Open palm sideways swipe -> switch desktop (Space)
    public var enablePalmSwipe: Bool = true
    /// Minimum sideways travel of the palm centre within `swipeWindow`.
    /// Larger than the two-finger swipe so that circling with an open hand doesn't switch desktops.
    public var palmSwipeMinDistance: Double = 0.25
    /// The palm must be held still (slower than `palmStillSpeed`, image heights / s) for
    /// `palmArmSeconds` before a swipe counts, and the swipe must start within `palmArmedWindow`.
    /// An open hand passing through the frame (reaching for the mouse...) never pauses.
    public var palmStillSpeed: Double = 0.35
    public var palmArmSeconds: Double = 0.25
    public var palmArmedWindow: Double = 1.0
    /// The palm centre must be at least this high in the frame (0 = bottom, 1 = top) to arm:
    /// hands resting near the keyboard sit at the bottom edge.
    public var palmMinHeight: Double = 0.3
    /// A jump larger than this between two frames is a keypoint glitch, not hand motion.
    public var palmMaxJump: Double = 0.15
    /// true: palm moves right = go to the desktop on the left (like dragging the desktops along).
    public var palmRightGoesLeft: Bool = true

    // MARK: Cross-gesture
    /// After any action, the *other* gesture is blocked for this long.
    public var crossGestureLockout: Double = 0.6

    // MARK: Smoothing
    public var filterMinCutoff: Double = 1.2
    public var filterBeta: Double = 0.6

    public init() {}
}

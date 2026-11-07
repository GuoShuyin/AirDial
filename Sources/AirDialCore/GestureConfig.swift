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

    // MARK: Knob (thumb + index + middle, turn the wrist) -> volume
    public var enableKnob: Bool = true
    /// Degrees of turning per volume step.
    public var knobStepDegrees: Double = 35
    /// The palm centre must have moved less than this (image heights) over the last 0.5 s.
    public var knobMaxMove: Double = 0.05
    /// Thumb tip to ring knuckle distance / knuckle width: the thumb is held out, not tucked.
    public var knobThumbOut: Double = 0.6
    /// A bigger turn between two frames is a keypoint glitch.
    public var knobMaxTurnPerFrame: Double = 40

    // MARK: Circle (one finger) -> volume
    /// Off by default: one finger is the mouse cursor, and circling it fought with pointing.
    public var enableCircleVolume: Bool = false
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
    /// true: two fingers up OR down = next track. Up and down are hard to tell apart on a webcam
    /// (a swipe often starts with a quick wind-up the other way), so by default both mean "next".
    public var verticalSwipeAlwaysNext: Bool = true
    /// When `verticalSwipeAlwaysNext` is false: true = up is next / down is previous.
    public var swipeUpIsNext: Bool = true

    // MARK: Open palm swipe: sideways -> switch desktop (Space), up/down -> Mission Control
    public var enablePalmSwipe: Bool = true
    /// Up or down (either direction) toggles Mission Control: once to show all windows, again to close it.
    public var enablePalmVerticalSwipe: Bool = true
    /// Minimum sideways travel of the palm centre within `swipeWindow`.
    /// Larger than the two-finger swipe so that circling with an open hand doesn't switch desktops.
    public var palmSwipeMinDistance: Double = 0.25
    /// Strict mode (`--palm-hold`): the palm must be held still (slower than `palmStillSpeed`,
    /// image heights / s) for `palmArmSeconds` before a swipe counts, and the swipe must start
    /// within `palmArmedWindow`. Off by default: swiping straight away feels much better, and the
    /// palm-width check below already rejects most hands that merely pass by.
    public var palmRequireHold: Bool = false
    public var palmStillSpeed: Double = 0.35
    public var palmArmSeconds: Double = 0.25
    public var palmArmedWindow: Double = 1.0
    /// The palm centre must be at least this high in the frame (0 = bottom, 1 = top) to arm.
    /// Off by default: people swipe sideways with the hand low in the frame (palm at 0.1-0.27).
    public var palmMinHeight: Double = 0.0
    /// Time window a palm swipe must happen within (shorter = must be quicker, like a flick).
    public var palmSwipeWindow: Double = 0.3
    /// Track the fingertips (true) or the palm centre (false) for palm swipes.
    /// A wrist flick moves the fingertips a lot and the palm centre only a little.
    public var palmTrackFingertips: Bool = false
    /// The palm must look at least this wide (index MCP to little MCP, image heights) to arm.
    /// Deliberate palm swipes measured 0.135-0.17; hands passing by / resting 0.08-0.12.
    public var palmMinWidth: Double = 0.14
    /// A jump larger than this between two frames is a keypoint glitch, not hand motion.
    /// Kept large: a real palm swipe moves up to ~0.3 per frame, more when blurred frames drop out.
    public var palmMaxJump: Double = 1.0
    /// true: palm moves right = go to the desktop on the left (like dragging the desktops along).
    public var palmRightGoesLeft: Bool = true

    // MARK: Open palm <-> fist: minimize / full screen
    public var enableHandShapes: Bool = true
    /// Frames each shape must be seen in a row (the model briefly reads a pointing finger as a fist).
    public var handShapeFrames: Int = 4
    /// Max time between the end of the first shape and the start of the second.
    public var handShapeGap: Double = 0.4
    /// After a grab fires, the hand must show something else (or leave) this long first.
    public var handShapeResetTime: Double = 0.4
    /// Palm swipes and fist/open changes exclude each other: a palm swipe is dropped if a fist
    /// was seen within this long before it, and after a fist/open change no palm swipe counts
    /// for `handShapeSwipeLockout`. (Closing or opening the hand while raising it must not also
    /// be a swipe up.)
    public var palmFistExclusion: Double = 0.5
    public var handShapeSwipeLockout: Double = 1.0
    /// A detected palm swipe is only acted on after the hand stayed open this long (a fist
    /// appearing in the meantime cancels it).
    public var palmSwipeConfirm: Double = 0.1

    // MARK: Pointer (index finger = mouse cursor, thumb-index pinch = click)
    public var enablePointer: Bool = true
    /// Starting size of the reach rectangle (fraction of the frame height / width) that maps to
    /// all screens. It grows to include wherever the fingertip goes.
    public var pointerInitialReach: Double = 0.3
    /// Smoothing (One Euro, in normalized screen units): low min cutoff = steady when still.
    public var pointerMinCutoff: Double = 0.4
    public var pointerBeta: Double = 4.0
    /// Which fingertip the thumb pinches to click. Middle (default) keeps the index fingertip,
    /// and so the cursor, still while clicking; it also looks close to the thumb by accident
    /// less often (0-2% of pointing frames vs 5-18% for the index on the recordings).
    public var pinchFinger: Finger = .middle
    /// Thumb tip to pinch fingertip distance / hand scale (knuckle width): below = pinched, above = open.
    /// Strict, because in 2D the fingertips often *look* close while pointing at the camera:
    /// with 0.35 and no other checks, circle recordings produced 18-37 false clicks each.
    public var pinchCloseRatio: Double = 0.18
    /// Re-arm threshold: the fingers only need to part a little before the next click
    /// (with 0.6 people kept the "button" held for seconds, turning clicks into drags).
    public var pinchOpenRatio: Double = 0.35
    /// The thumb tip must be seen with at least this confidence (it is often just guessed).
    public var pinchMinThumbConfidence: Float = 0.4
    /// The hand must be nearly still to press (palm centre speed, image heights / s): you stop to
    /// click, while circling or moving the pointer around is fast.
    public var pinchMaxSpeed: Double = 0.5
    /// A fingertip jump larger than this between frames is a glitch: it doesn't grow the reach.
    public var pointerMaxJump: Double = 0.08
    /// Frames in a row needed to press / to release.
    public var pinchFrames: Int = 4
    public var pinchReleaseFrames: Int = 2
    /// When a pinch starts, the pointer goes back to where it was this long ago and stays there.
    public var pinchFreezeLookback: Double = 0.2

    // MARK: Cross-gesture
    /// After any action, the *other* gesture is blocked for this long.
    public var crossGestureLockout: Double = 0.6

    // MARK: Smoothing
    public var filterMinCutoff: Double = 1.2
    public var filterBeta: Double = 0.6

    public init() {}
}

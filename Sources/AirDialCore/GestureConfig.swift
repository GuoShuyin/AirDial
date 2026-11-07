import Foundation

/// All tunable thresholds in one place. Distances are in units of image height
/// (1.0 = full camera frame height). Angles are in degrees, times in seconds.
public struct GestureConfig {
    // MARK: Pose classification
    /// While pointing, a fist reading counts as still pointing (pointing at the camera looks like a fist).
    public var pointSticksThroughFist: Bool = true
    /// 3D (MediaPipe): a finger bent less than this (PIP + DIP angle, degrees) is extended...
    public var bendExtendedMax: Double = 60
    /// ...and more than this is curled.
    public var bendCurledMin: Double = 100
    /// 3D thumbs-up: fist with the thumb straight (bend < `thumbsUpMaxBend`) and its tip at least
    /// `thumbsUpMinDistance` from the index finger's middle joint. Measured: thumbs-up 23 degrees /
    /// 7 cm, tucked thumb 3 cm. Released (Fn up) once the tip is back within
    /// `thumbsUpReleaseDistance` or the thumb bends past `thumbsUpReleaseBend`.
    public var thumbsUpMaxBend: Double = 45
    public var thumbsUpMinDistance: Double = 0.045
    public var thumbsUpReleaseBend: Double = 60
    public var thumbsUpReleaseDistance: Double = 0.035
    /// When pointing turns into a thumbs-up, the cursor goes back to where it was this long before
    /// the first thumbs-up frame, and stays there until you point again.
    public var thumbsUpCursorRewind: Double = 0.3
    /// Seconds after the thumbs-up ends before Fn is released (other poses use poseDropSeconds).
    public var thumbsUpReleaseSeconds: Double = 0.2
    /// Frames in a row before a thumbs-up counts (0.3 s): a stray Fn press can open the emoji picker.
    public var thumbsUpConfirmFrames: Int = 9
    /// Thumbs-up holds the Fn / Globe key while it lasts.
    public var enableThumbsUpFn: Bool = true
    /// 3D: all four fingers bent less than this = open palm (a waving hand measured 60-80).
    public var palmOpenBendMax: Double = 90
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
    /// Off by default: turning the wrist was hard to do and to see reliably.
    public var enableKnob: Bool = false
    /// Degrees of turning per volume step.
    public var knobStepDegrees: Double = 35
    /// The palm centre must have moved less than this (image heights) over the last 0.5 s.
    public var knobMaxMove: Double = 0.05
    /// Thumb tip to ring knuckle distance / knuckle width: the thumb is held out, not tucked.
    public var knobThumbOut: Double = 0.6
    /// A bigger turn between two frames is a keypoint glitch.
    public var knobMaxTurnPerFrame: Double = 40
    /// 3D grip: thumb tip to index tip and to middle tip both within this range (metres), as if
    /// holding a knob, and not pinched.
    public var knobGripMin3D: Double = 0.03
    public var knobGripMax3D: Double = 0.11
    /// Flip the 3D turning direction (if turning right lowers the volume on your setup).
    public var knobReverse3D: Bool = false

    // MARK: Two fingers held together, draw a circle -> volume
    /// Index and middle finger side by side (not a V): circling them clockwise = volume up.
    public var enableTwoFingerCircle: Bool = true
    /// Fingertip spread: together below the first value, apart (a V, for swipes) above the
    /// second. 3D in metres; 2D relative to the knuckle width.
    public var fingersTogether3D: Double = 0.025
    public var fingersApart3D: Double = 0.035
    public var fingersTogether2D: Double = 0.35
    public var fingersApart2D: Double = 0.5

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
    /// Off by default: sideways two-finger moves do nothing (sideways belongs to the palm / desktops).
    public var enableHorizontalSwipe: Bool = false
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
    public var palmSwipeMinDistance: Double = 0.2
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
    /// 3D (MediaPipe): palm facing the camera at least this much (0 edge-on ... 1 flat; open
    /// palms measured median 0.66-0.81) and at least this wide. MediaPipe's knuckles sit closer
    /// together than Vision's, so the 2D width threshold above blocked every palm swipe.
    public var palmMinFacing3D: Double = 0.5
    public var palmMinWidth3D: Double = 0.07
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
    /// Frames in a row before a fist reading counts for that exclusion.
    public var fistConfirmFrames: Int = 3
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
    /// 3D (MediaPipe): thumb tip to pinch fingertip distance in metres: below = pinched, above = open.
    /// (Also the "touching the middle finger" distance for taps and scrolling.)
    public var pinchClose3D: Double = 0.02
    /// Lifted off again: 2.5 cm (3.5 cm asked for too high a lift between clicks).
    public var pinchOpen3D: Double = 0.025
    /// 3D: frames in a row the thumb must touch (3D is steady enough for a short tap).
    public var pinchFrames3D: Int = 2
    /// 3D: a click must be a tap: within `tapWindow` before touching, the thumb was at least
    /// `tapLift` further from the target than when it touches. A thumb resting on the middle
    /// finger while pointing (very common) never clicks; lifting it a little and tapping does.
    public var tapWindow: Double = 0.6
    public var tapLift: Double = 0.015
    /// 3D: after the thumb taps down, wait this long (or until it lifts) before clicking; if it
    /// slides more than `tapSlideCancel3D` along the finger meanwhile, it's scrolling instead.
    public var tapConfirm: Double = 0.2
    /// (4 mm was within MediaPipe's own jitter and cancelled almost every click.)
    public var tapSlideCancel3D: Double = 0.012
    /// 3D left click target: the middle finger's first knuckle by the fingertip (DIP), or with
    /// this set, the fingertip itself. The right click is always the second knuckle (PIP).
    public var leftClickAtFingertip: Bool = false
    /// 3D: thumb sliding along the middle finger = scroll wheel. Contact = thumb tip within this
    /// distance of the finger; it must slide `scrollDeadZone3D` before scrolling starts.
    public var enableScroll: Bool = true
    public var scrollContact3D: Double = 0.02
    /// (4 mm accumulated was within MediaPipe's jitter: a resting thumb "scrolled" and froze the cursor.)
    public var scrollDeadZone3D: Double = 0.012
    /// ...as net movement within this window.
    public var scrollStartWindow: Double = 0.4
    /// Pixels scrolled per metre of sliding (15 px per millimetre).
    public var scrollPixelsPerMetre: Double = 15000
    /// true: sliding towards the fingertip scrolls down instead of up.
    public var scrollReverse: Bool = false
    /// 3D: thumb tip tapping the middle finger's second knuckle = right click.
    public var enableRightClick: Bool = true
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

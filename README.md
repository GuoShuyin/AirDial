<p align="right"><b>English</b> · <a href="README.zh-CN.md">中文</a></p>

# AirDial

Mid-air, BMW-style gestures for music on macOS, using the regular built-in webcam. No depth camera, no model training.

| Gesture | Action |
| --- | --- |
| 🤏 Thumb, index and middle finger as if holding a knob, **turn right** | Volume + (one step per 35°) |
| 🤏 Same grip, **turn left** | Volume − |
| ☝️ Index finger, **point** | Moves the mouse cursor, across all your displays |
| ☝️ While pointing, **pinch** thumb and middle finger together | Left click (one pinch = one click) |
| ✌️ Index + middle finger (V), quick swipe **up or down** | Next track |
| ✌️ V, swipe right / left | Next / previous track |
| 🖐 Open palm facing the camera, quick swipe **right** | Desktop (Space) on the left |
| 🖐 Open palm, quick swipe **left** | Desktop (Space) on the right |
| 🖐 Open palm, quick swipe **up or down** | Mission Control (all windows); do it again to close it |
| 🖐 → ✊ Close your open hand into a fist | The front window leaves full screen |
| ✊ → 🖐 Open a fist into an open hand | The front window goes full screen |

## How it works (and why no training is needed)

1. **Hand keypoints**: MediaPipe Hand Landmarker (21 joints in 2D and 3D, ~17 ms per frame including the round trip to the Python process) or, as a fallback, Apple Vision's built-in `VNDetectHumanHandPoseRequest` (2D only, ~7 ms). The camera is pinned to 30 fps: in dim light the webcam would otherwise drop to ~15 fps with long exposures that smear a moving hand.
2. **Hand shape**: with 3D joints, a finger is extended when it bends less than 60° (PIP + DIP angle) and curled above 100°, independent of the viewing angle. In 2D (Vision), compare the tip-to-wrist distance with the PIP-to-wrist distance to decide whether it is extended. This separates ☝️ one finger / ✌️ two fingers / 🖐 open palm / anything else. Ratios rather than absolute distances, so it works at any distance from the camera.
3. **Knob**: the thumb is held out (clearly seen, away from the palm), index and middle fingertips are visible, the middle finger isn't curled (that would be pointing) and ring and little finger aren't extended. A V sign often looks like that too, so the motion decides: turning rotates the thumb → fingertips direction while the hand stays in place (palm centre moved < 5% of the frame height in 0.5 s); a swipe moves the whole hand. Every 35° of turning is one volume step. To keep turning past your wrist's range, relax the grip, turn back and grip again.
   **Circles** (off by default since one finger is the cursor; `--circle-volume` turns them on): no circle fitting. AirDial adds up how much the direction of the fingertip's motion turns. One loop is ±360°; straight lines and back-and-forth motion add up to about 0. To start, the path must turn 270° or more, at least 85% of it in one direction, and be big enough, not flat and round enough. After that, every further full loop (360°) is one more volume step, so N loops give N steps. Turning back 120° from the furthest point reached stops the knob.
4. **Swipes**: the midpoint of the two fingertips moves more than 16% of the frame height within 0.45 s, with the main-axis travel at least 1.8× the cross-axis travel. Up and down both mean "next track": on a webcam a swipe often starts with a quick wind-up the other way, so the two directions can't be told apart reliably (`--vertical-prev` restores down = previous).
5. **Palm swipes** (desktops, Mission Control): the palm centre travels 25% of the frame height within 0.3 s, and the palm must look wide (index-to-little knuckle distance at least 14% of the frame height). A deliberate swipe shows the palm flat to the camera from up close (measured 0.135–0.17); a hand passing by or resting near the keyboard is edge-on or further away (0.08–0.12). With `--palm-hold` the palm must also be held still for 0.25 s first, which removes the remaining rare false triggers. Up and down both send Control+↑, which macOS itself treats as a toggle: once opens Mission Control, again closes it.
6. **Finger cursor**: the index fingertip is mapped from a "reach" rectangle in the camera frame onto your displays as arranged in System Settings → Displays: side by side horizontally, and vertically over whichever display is under that point (they may be offset). The reach rectangle starts small in the middle of the frame and grows to include wherever your fingertip goes, so it is twitchy at first and calibrates itself as you move. Moving the real mouse or trackpad pauses the finger cursor for 1.5 s.
   **Pinch to click** uses the thumb and the *middle* finger, so the index fingertip (the cursor) stays still while you click; `--pinch-index` switches to thumb + index. The rule is strict, because in 2D the fingertips often *look* close while you point at the camera (a loose thumb–index rule gave 18–37 false clicks per minute-long circle recording). The tips must almost touch (within 18% of the knuckle width), Vision must actually see the thumb (confidence ≥ 0.4), the hand must be nearly still, and all of that for 4 frames. The cursor freezes where it was just before the pinch, so the click lands where you pointed. Each click plays a short "Tink" and prints where it landed. A single slightly-off frame in the middle of a pinch doesn't restart it (in a recorded pinch test this took detected pinches from 5 to 8 of about 11, still with 0 false clicks while circling).
7. **Fist and open hand**: each shape must be seen for 4 frames in a row with the palm facing the camera, and the second must follow the first within 0.4 s. Full screen is set explicitly through the Accessibility API (`AXFullScreen`), not toggled. Some apps (Chromium / Electron based) report that attribute unreliably, so a window that exactly covers its display also counts as full screen, and if the state hasn't changed 0.6 s later AirDial sends Ctrl+Cmd+F. Each attempt prints one diagnostic line. So opening your hand never takes a window *out* of full screen and closing it never puts one *in*. After closing your hand, relaxing it open again (the natural thing to do) does not go back to full screen; show something else or take the hand away for 0.4 s first. Palm/fist readings while you point or use two fingers are ignored (the model misreads a pointing finger as a fist).
   Palm swipes and fist/open changes exclude each other: a palm swipe within 0.5 s of a fist is dropped, a palm swipe is only acted on after the hand stayed open for 0.1 s, and no palm swipe counts for 1 s after a fist/open change. So opening your hand while raising it is full screen, not also Mission Control.
8. **False-trigger protection**: One Euro filtering against jitter; a hand shape must be seen for 3 frames to start (10 frames to switch directly between two gestures). It is only dropped after 0.5 s without it, because the model misreads a finger for several frames in a row whenever it turns towards the camera. Swipes have a 0.8 s cooldown, and the reverse motion of bringing your hand back is ignored for 1.4 s. The gestures lock each other out for 0.6 s after any action.

All thresholds live in [`Sources/AirDialCore/GestureConfig.swift`](Sources/AirDialCore/GestureConfig.swift); `--sensitivity` scales the main ones.

## Install and run

Requires macOS 12+ and Xcode or the Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/GuoShuyin/AirDial.git
cd AirDial
swift build -c release          # build
swift test                      # unit tests for the gesture logic (optional)
.build/release/AirDial          # run; opens a camera preview window
```

With only the Command Line Tools (no Xcode), `swift test` cannot find a test framework. Use this instead:

```bash
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
swift test --disable-xctest --enable-swift-testing -Xswiftc -F -Xswiftc $F -Xlinker -F -Xlinker $F -Xlinker -rpath -Xlinker $F
```

### 3D hand tracking (recommended)

By default AirDial uses Google's MediaPipe Hand Landmarker, which gives 3D joints: finger bending, pinches and turning the knob are then measured in 3D and work from any camera angle. It runs offline in a small local Python process (`Support/mediapipe_hands.py`); AirDial keeps the camera and frames never leave your Mac. Without it, AirDial falls back to Apple Vision (2D only, less accurate).

```bash
python3 -m venv .venv && .venv/bin/pip install mediapipe numpy
mkdir -p models && curl -L -o models/hand_landmarker.task \
  https://storage.googleapis.com/mediapipe-models/hand_landmarker/hand_landmarker/float16/latest/hand_landmarker.task
```

`--tracker vision` forces Apple Vision; `--python PATH` / `--model PATH` point elsewhere.

On first run macOS asks for permissions. They are granted to **the app you launched AirDial from** (Terminal / iTerm / VS Code):

1. **Camera**: click Allow. If you denied it before: System Settings → Privacy & Security → Camera → enable your terminal app, then **quit and reopen** it.
2. **Accessibility** (recommended; required for the finger cursor and desktop switching): System Settings → Privacy & Security → Accessibility → enable your terminal app, then reopen it.
   With it, AirDial sends the keyboard's media keys, which work with any player (Apple Music, Spotify, YouTube in a browser...) and show the system volume HUD.
   Without it, AirDial falls back to AppleScript: system volume only, and track switching only for Music and Spotify (macOS asks for "Automation" permission the first time).

Palm swipes send Control+← / Control+→ / Control+↑. These are macOS's default "Move left/right a space" and "Mission Control" shortcuts (System Settings → Keyboard → Keyboard Shortcuts → Mission Control). Switching desktops needs at least two desktops.

### Options

```bash
.build/release/AirDial --dry-run           # recognise gestures but don't act; good for practising
.build/release/AirDial --headless          # no preview window, runs in the background (Ctrl+C to quit)
.build/release/AirDial --sensitivity 1.3   # more sensitive (0.5 strict ... 1.5 sensitive)
.build/release/AirDial --ccw-up            # reverse the circle: counter-clockwise = volume up
.build/release/AirDial --vertical-prev     # two fingers: up = next, down = previous (default: both = next)
.build/release/AirDial --no-horizontal     # disable left/right two-finger swipes
.build/release/AirDial --no-desktops       # disable all open-palm swipes
.build/release/AirDial --no-mission-control  # disable open-palm up/down = Mission Control
.build/release/AirDial --palm-follows      # palm right = desktop on the right
.build/release/AirDial --palm-hold         # strict: hold the palm still briefly before swiping
.build/release/AirDial --no-cursor         # don't move the mouse cursor with the index finger
.build/release/AirDial --pinch-index       # click with thumb + index instead of thumb + middle finger
.build/release/AirDial --circle-volume     # also change volume by circling the index finger
.build/release/AirDial --no-knob           # disable the three-finger knob
.build/release/AirDial --no-hand-shapes    # disable fist / open hand = leave / enter full screen
.build/release/AirDial --list-cameras      # list cameras (pick one with --camera NAME)
.build/release/AirDial --debug             # print the hand shape of every frame
.build/release/AirDial --log frames.csv    # write per-frame diagnostics (see below)
```

## Tips

- Keep your hand 30–60 cm from the screen and **high enough that your wrist is in the frame**. With the wrist cut off at the bottom edge, recognition gets much worse.
- Knob: hold your hand still, as if gripping a knob between thumb, index and middle finger, and turn the wrist.
- Tracks: make the V and swipe once, crisply. To swipe again quickly, relax your fingers before bringing your hand back.
- Cursor: sweep your pointing finger to the furthest left / right / top / bottom you want to reach once; after that the mapping is calibrated. To click, stop, then pinch thumb and middle finger together and hold for a moment.
- Full screen acts on the frontmost window. Click into the app you want first, not the AirDial preview.
- Desktops / Mission Control: show an open palm flat to the camera and swipe quickly. The preview says "Ready: swipe now" while the palm is recognised.
- More light is better. Backlight (a window behind you) makes it noticeably worse.

## Tuning on real recordings

`--log FILE` writes one CSV row per frame: Vision time, dropped frames, all 21 joints with their confidences, the recognised hand shape and any action. `AirDialReplay` feeds such a recording back through the gesture engine, so you can try thresholds on your own movements without the camera:

```bash
.build/release/AirDial --dry-run --log run.csv     # record while gesturing
swift build -c release --product AirDialReplay
.build/release/AirDialReplay run.csv --timeline                  # per-second view of poses and actions
.build/release/AirDialReplay run.csv --set circleStepDegrees=180 # try a different threshold
.build/release/AirDialReplay run.csv --min-conf 0.2 --trace 10-14
```

The log contains keypoint coordinates only, never images.

## Project layout

```
Sources/AirDialCore/    Gesture logic only (no camera, unit-testable)
  GestureConfig.swift   All thresholds
  HandPose.swift        Hand shape classification
  CircleTracker.swift   Circle detection
  KnobTracker.swift     Three-finger knob
  SwipeDetector.swift   Swipe detection
  HandShapeTransition.swift  Open hand <-> fist
  PointerTracker.swift  Finger cursor: self-calibrating reach, smoothing, pinch to click
  ScreenMapper.swift    Pointer position -> point on your arranged displays
  GestureEngine.swift   Debouncing, filtering, dispatch
  Geometry.swift        Vectors, One Euro filter
Sources/AirDial/        The macOS app
  HandTracker.swift     Camera + hand keypoints (MediaPipe or Vision)
  MediaPipeBackend.swift Talks to the local MediaPipe process
  MediaController.swift Media keys / AppleScript / desktop switching
  CursorController.swift Moves / clicks the real mouse cursor
  PreviewWindow.swift   Preview window and debug overlay
  main.swift            Startup, options, permissions, --log
Support/mediapipe_hands.py  The MediaPipe hand tracker process
Sources/AirDialReplay/  Replays a --log recording through the gesture engine
Tests/AirDialCoreTests/ Synthetic hand paths testing recognition and false-trigger protection
```

## Known limitations

- Vision's 2D keypoints are unreliable when a finger points straight at the camera: on a webcam it misreads a pointing finger as a fist on about a third of such frames. The time-based pose hold above bridges most of it.
- Two-finger up and down swipes can't be told apart reliably (a swipe often starts with a wind-up the other way), which is why both mean "next track".

## License

MIT

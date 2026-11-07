<p align="right"><b>English</b> · <a href="README.zh-CN.md">中文</a></p>

# AirDial

Mid-air, BMW-style gestures for music on macOS, using the regular built-in webcam. No depth camera, no model training.

| Gesture | Action |
| --- | --- |
| ☝️ Index finger, **point** | Moves the mouse cursor, across all your displays (calibrated at start-up) |
| ☝️ While pointing, **tap** thumb tip onto the middle fingertip | Left click |
| ☝️ While pointing, **tap** thumb tip onto the middle finger's second knuckle | Right click (3D tracking only) |
| 🤞 Index + middle finger **held together**, draw a circle **clockwise** | Volume + (one step per loop) |
| 🤞 Same, **counter-clockwise** | Volume − |
| ✌️ Index + middle finger **apart** (V), quick swipe **up or down** | Next track |
| 🖐 Open palm facing the camera, quick swipe **right** | Desktop (Space) on the left |
| 🖐 Open palm, quick swipe **left** | Desktop (Space) on the right |
| 🖐 Open palm, quick swipe **up or down** | Mission Control (all windows); do it again to close it |
| 🖐 → ✊ Close your open hand into a fist | The front window leaves full screen |
| ✊ → 🖐 Open a fist into an open hand | The front window goes full screen |

## How it works (and why no training is needed)

1. **Hand keypoints**: MediaPipe Hand Landmarker (21 joints in 2D and 3D, ~17 ms per frame including the round trip to the Python process) or, as a fallback, Apple Vision's built-in `VNDetectHumanHandPoseRequest` (2D only, ~7 ms). The camera is pinned to 30 fps: in dim light the webcam would otherwise drop to ~15 fps with long exposures that smear a moving hand.
2. **Hand shape**: with 3D joints, a finger is extended when it bends less than 60° (PIP + DIP angle) and curled above 100°, independent of the viewing angle. In 2D (Vision), compare the tip-to-wrist distance with the PIP-to-wrist distance to decide whether it is extended. This separates ☝️ one finger / ✌️ two fingers / 🖐 open palm / anything else. Ratios rather than absolute distances, so it works at any distance from the camera.
3. **Volume circles**: index and middle finger side by side (fingertips < 2.5 cm apart in 3D, < 35% of the knuckle width in 2D); apart (> 3.5 cm) they form a V for swipes instead. No circle fitting: AirDial adds up how much the direction of the fingertips' motion turns. One loop is ±360°; straight lines and back-and-forth motion add up to about 0. To start, the path must turn 270° or more, at least 85% of it in one direction, and be big enough, not flat and round enough. After that, every further full loop (360°) is one more volume step, so N loops give N steps. Turning back 120° from the furthest point reached stops.
   Optional alternatives: `--circle-volume` (circle with one finger; off because one finger is the cursor) and `--knob` (thumb, index and middle finger turned like a knob, measured as the hand rotating around its own axis in 3D).
4. **Swipes**: with a V, the midpoint of the two fingertips moves more than 16% of the frame height within 0.45 s, with the vertical travel at least 1.8× the sideways travel. Up and down both mean "next track": on a webcam a swipe often starts with a quick wind-up the other way, so the two directions can't be told apart reliably (`--vertical-prev` restores down = previous). Sideways two-finger moves do nothing (`--horizontal-tracks` makes them next / previous).
5. **Palm swipes** (desktops, Mission Control): the palm centre travels 25% of the frame height within 0.3 s, and the palm must look wide (index-to-little knuckle distance at least 14% of the frame height). A deliberate swipe shows the palm flat to the camera from up close (measured 0.135–0.17); a hand passing by or resting near the keyboard is edge-on or further away (0.08–0.12). With `--palm-hold` the palm must also be held still for 0.25 s first, which removes the remaining rare false triggers. Up and down both send Control+↑, which macOS itself treats as a toggle: once opens Mission Control, again closes it.
6. **Finger cursor**: at start-up AirDial shows three targets on each display (top left, centre, bottom right, displays left to right). Point at each and hold still until it chimes; about 15 s for three displays. The fingertip positions recorded there map your pointing onto the displays: piecewise-linear across displays horizontally, a straight-line fit per display vertically (displays can sit at different heights). The calibration is saved and `--no-calibrate` reuses it. Without one, a self-growing "reach" rectangle is used. Moving the real mouse or trackpad pauses the finger cursor for 1.5 s.
   **Clicks** are taps of the thumb tip: onto the middle fingertip = left click, onto the middle finger's second knuckle = right click. The middle finger is used so the index fingertip (the cursor) stays put; the cursor also freezes where it was just before the tap. With 3D joints the tip must come within 2.5 cm of the target, from more than 4 cm away within 0.6 s, so a thumb merely resting on the curled middle finger never clicks; the nearer target wins. In 2D (Vision) only the left click exists, with a strict distance relative to the knuckle width. Each click plays a short "Tink" and prints where it landed. `--pinch-index` uses the index fingertip for the left click instead.
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
.build/release/AirDial --no-calibrate      # skip the start-up cursor calibration, reuse the last one
.build/release/AirDial --vertical-prev     # two fingers: up = next, down = previous (default: both = next)
.build/release/AirDial --horizontal-tracks # two fingers right / left = next / previous track
.build/release/AirDial --no-desktops       # disable all open-palm swipes
.build/release/AirDial --no-mission-control  # disable open-palm up/down = Mission Control
.build/release/AirDial --palm-follows      # palm right = desktop on the right
.build/release/AirDial --palm-hold         # strict: hold the palm still briefly before swiping
.build/release/AirDial --no-cursor         # don't move the mouse cursor with the index finger
.build/release/AirDial --pinch-index       # left click with thumb + index instead of thumb + middle finger
.build/release/AirDial --circle-volume     # also change volume by circling the index finger
.build/release/AirDial --knob              # also change volume with the three-finger knob
.build/release/AirDial --no-hand-shapes    # disable fist / open hand = leave / enter full screen
.build/release/AirDial --list-cameras      # list cameras (pick one with --camera NAME)
.build/release/AirDial --debug             # print the hand shape of every frame
.build/release/AirDial --log frames.csv    # write per-frame diagnostics (see below)
```

## Tips

- Keep your hand 30–60 cm from the screen and **high enough that your wrist is in the frame**. With the wrist cut off at the bottom edge, recognition gets much worse.
- Volume: hold index and middle finger together (like a closed V) and draw circles about a fist wide, 0.5–2 s per loop.
- Tracks: make the V and swipe once, crisply. To swipe again quickly, relax your fingers before bringing your hand back.
- Cursor: do the start-up calibration with the same posture you'll use afterwards. To click, stop, lift the thumb a little and tap it onto the middle fingertip (left) or the middle finger's second knuckle (right).
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

[PolyForm Noncommercial 1.0.0](LICENSE): free for personal, educational, research and other noncommercial use, including changing it. **Commercial use requires a separate license from the author**; get in touch through [GitHub](https://github.com/GuoShuyin).

The MediaPipe hand model (`models/hand_landmarker.task`, downloaded separately) is Google's, under the Apache License 2.0.

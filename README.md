<p align="right"><b>English</b> · <a href="README.zh-CN.md">中文</a></p>

# AirDial

Mid-air, BMW-style gestures for music on macOS, using the regular built-in webcam. No depth camera, no model training.

| Gesture | Action |
| --- | --- |
| ☝️ Index finger only, draw a circle **clockwise** | Volume + (one step per loop, like turning a knob) |
| ☝️ Index finger only, draw a circle **counter-clockwise** | Volume − |
| ✌️ Index + middle finger (V), quick swipe **up or down** | Next track |
| ✌️ V, swipe right / left | Next / previous track |
| 🖐 Open palm, **hold still for a moment**, then swipe **right** | Desktop (Space) on the left |
| 🖐 Open palm, hold still, then swipe **left** | Desktop (Space) on the right |
| 🖐 Open palm, hold still, then swipe **up or down** | Mission Control (all windows); do it again to close it |

## How it works (and why no training is needed)

1. **Hand keypoints**: Apple Vision's built-in `VNDetectHumanHandPoseRequest`, a pretrained model that returns 21 hand joints per frame. It takes about 7 ms per frame on Apple Silicon. The camera is pinned to 30 fps: in dim light the webcam would otherwise drop to ~15 fps with long exposures that smear a moving hand.
2. **Hand shape**: for each finger, compare the tip-to-wrist distance with the PIP-to-wrist distance to decide whether it is extended. This separates ☝️ one finger / ✌️ two fingers / 🖐 open palm / anything else. Ratios rather than absolute distances, so it works at any distance from the camera.
3. **Circles**: no circle fitting. AirDial adds up how much the direction of the fingertip's motion turns. One loop is ±360°; straight lines and back-and-forth motion add up to about 0. To start, the path must turn 270° or more, at least 85% of it in one direction, and be big enough, not flat and round enough. After that, every further full loop (360°) is one more volume step, so N loops give N steps. Turning back 120° from the furthest point reached stops the knob.
4. **Swipes**: the midpoint of the two fingertips moves more than 16% of the frame height within 0.45 s, with the main-axis travel at least 1.8× the cross-axis travel. Up and down both mean "next track": on a webcam a swipe often starts with a quick wind-up the other way, so the two directions can't be told apart reliably (`--vertical-prev` restores down = previous).
5. **Palm swipes** (desktops, Mission Control): the palm centre must first be held still for 0.25 s, above the bottom 35% of the frame, and then travel 25% of the frame height within 1 s. A hand passing through the frame (reaching for the mouse) never pauses, so it doesn't trigger anything. Up and down both send Control+↑, which macOS itself treats as a toggle: once opens Mission Control, again closes it.
6. **False-trigger protection**: One Euro filtering against jitter; a hand shape must be seen for 3 frames to start (10 frames to switch directly between two gestures). It is only dropped after 0.5 s without it, because the model misreads a finger for several frames in a row whenever it turns towards the camera. Swipes have a 0.8 s cooldown, and the reverse motion of bringing your hand back is ignored for 1.4 s. The gestures lock each other out for 0.6 s after any action.

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

On first run macOS asks for permissions. They are granted to **the app you launched AirDial from** (Terminal / iTerm / VS Code):

1. **Camera**: click Allow. If you denied it before: System Settings → Privacy & Security → Camera → enable your terminal app, then **quit and reopen** it.
2. **Accessibility** (recommended, required for desktop switching): System Settings → Privacy & Security → Accessibility → enable your terminal app, then reopen it.
   With it, AirDial sends the keyboard's media keys, which work with any player (Apple Music, Spotify, YouTube in a browser...) and show the system volume HUD.
   Without it, AirDial falls back to AppleScript: system volume only, and track switching only for Music and Spotify (macOS asks for "Automation" permission the first time).

Palm swipes send Control+← / Control+→ / Control+↑. These are macOS's default "Move left/right a space" and "Mission Control" shortcuts (System Settings → Keyboard → Keyboard Shortcuts → Mission Control). Switching desktops needs at least two desktops.

### Options

```bash
.build/release/AirDial --dry-run           # recognise gestures but don't act; good for practising
.build/release/AirDial --headless          # no preview window, runs in the background (Ctrl+C to quit)
.build/release/AirDial --sensitivity 1.3   # more sensitive (0.5 strict ... 1.5 sensitive)
.build/release/AirDial --ccw-up            # reverse the knob: counter-clockwise = volume up
.build/release/AirDial --vertical-prev     # two fingers: up = next, down = previous (default: both = next)
.build/release/AirDial --no-horizontal     # disable left/right two-finger swipes
.build/release/AirDial --no-desktops       # disable all open-palm swipes
.build/release/AirDial --no-mission-control  # disable open-palm up/down = Mission Control
.build/release/AirDial --palm-follows      # palm right = desktop on the right
.build/release/AirDial --list-cameras      # list cameras (pick one with --camera NAME)
.build/release/AirDial --debug             # print the hand shape of every frame
.build/release/AirDial --log frames.csv    # write per-frame diagnostics (see below)
```

## Tips

- Keep your hand 30–60 cm from the screen and **high enough that your wrist is in the frame**. With the wrist cut off at the bottom edge, recognition gets much worse.
- Circles: about a fist wide, 0.5–2 s per loop. When the dot turns green the "knob" is engaged; keep turning to keep adjusting.
- Tracks: make the V and swipe once, crisply. To swipe again quickly, relax your fingers before bringing your hand back.
- Desktops / Mission Control: raise an open palm to the middle of the frame, hold it until the preview says "Ready: swipe now", then swipe. Without the pause nothing happens, on purpose.
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
  SwipeDetector.swift   Swipe detection
  GestureEngine.swift   Debouncing, filtering, dispatch
  Geometry.swift        Vectors, One Euro filter
Sources/AirDial/        The macOS app
  HandTracker.swift     Camera + Vision hand keypoints
  MediaController.swift Media keys / AppleScript / desktop switching
  PreviewWindow.swift   Preview window and debug overlay
  main.swift            Startup, options, permissions, --log
Sources/AirDialReplay/  Replays a --log recording through the gesture engine
Tests/AirDialCoreTests/ Synthetic hand paths testing recognition and false-trigger protection
```

## Known limitations

- Vision's 2D keypoints are unreliable when a finger points straight at the camera: on a webcam it misreads a pointing finger as a fist on about a third of such frames. The time-based pose hold above bridges most of it.
- Two-finger up and down swipes can't be told apart reliably (a swipe often starts with a wind-up the other way), which is why both mean "next track".

## License

MIT

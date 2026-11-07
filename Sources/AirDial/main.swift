import AVFoundation
import AirDialCore
import AppKit
import Foundation

// MARK: - Command line options

struct Options {
    var headless = false
    var dryRun = false
    var debug = false
    var listCameras = false
    var cameraName: String?
    var logPath: String?
    var tracker = "auto"        // auto | mediapipe | vision
    var calibrate = true
    var pythonPath: String?
    var modelPath: String?
    var config = GestureConfig()

    static let usage = """
    AirDial — mid-air gestures for music on macOS (uses the built-in webcam)

      🤞 Index + middle together, circle   clockwise = volume up, counter-clockwise = volume down
      🖐→✊ Close your open hand          front window exits full screen;  ✊→🖐 open it: full screen
      ☝️  Index finger, point           moves the mouse cursor (all displays); pinch thumb + middle finger = click
      ✌️  Two fingers apart (V), swipe   up or down = next track
      🖐  Open palm facing the camera, swipe   sideways = switch desktop, up or down = Mission Control on/off

    Usage: AirDial [options]
      --headless          No preview window (runs in the background, Ctrl+C to quit)
      --dry-run           Recognize gestures but don't change volume / tracks
      --debug             Print the raw pose of every frame
      --tracker NAME      mediapipe (3D, default when installed) or vision (Apple Vision, 2D)
      --python PATH       Python with mediapipe installed (default: .venv/bin/python3, or $AIRDIAL_PYTHON)
      --model PATH        MediaPipe hand model (default: models/hand_landmarker.task)
      --no-calibrate      Skip the start-up cursor calibration and reuse the last one
      --log FILE          Write per-frame diagnostics (CSV) to FILE
      --camera NAME       Use the camera whose name contains NAME
      --list-cameras      List cameras and exit
      --ccw-up            Counter-clockwise = volume up (reverse the knob)
      --vertical-prev     Two fingers up = next, down = previous (default: both = next)
      --swipe-down-next   With --vertical-prev: down = next, up = previous
      --horizontal-tracks Two fingers right / left = next / previous track (off by default)
      --no-vertical       Disable up/down swipes
      --no-desktops       Disable open-palm swipes (desktops and Mission Control)
      --no-mission-control  Disable open-palm up/down = Mission Control
      --no-thumbs-up      Don't hold the Fn / Globe key while you show a thumbs-up
      --no-hand-shapes    Disable fist = exit full screen, open hand = full screen
      --circle-volume     Also change volume by circling the index finger (off: it fights the cursor)
      --knob              Also use the three-finger knob for volume (turn right = up)
      --no-scroll         Disable thumb sliding along the middle finger = scroll wheel
      --scroll-reverse    Sliding towards the fingertip scrolls down
      --pinch-index       Click by pinching thumb + index (default: thumb + middle finger)
      --no-cursor         Don't move the mouse cursor with the index finger
      --palm-hold         Strict: hold the open palm still for a moment before it can swipe
      --palm-follows      Palm right = desktop on the right (default: palm right = desktop on the left)
      --sensitivity X     0.5 (strict) ... 1.5 (sensitive), default 1.0
      -h, --help          Show this help
    """

    static func parse(_ args: [String]) -> Options {
        var o = Options()
        var i = 0
        while i < args.count {
            let a = args[i]
            switch a {
            case "--headless": o.headless = true
            case "--dry-run": o.dryRun = true
            case "--debug": o.debug = true
            case "--list-cameras": o.listCameras = true
            case "--no-calibrate": o.calibrate = false
            case "--tracker":
                i += 1
                if i < args.count { o.tracker = args[i] }
            case "--python":
                i += 1
                if i < args.count { o.pythonPath = args[i] }
            case "--model":
                i += 1
                if i < args.count { o.modelPath = args[i] }
            case "--log":
                i += 1
                if i < args.count { o.logPath = args[i] }
            case "--camera":
                i += 1
                if i < args.count { o.cameraName = args[i] }
            case "--ccw-up": o.config.clockwiseIsVolumeUp = false
            case "--vertical-prev": o.config.verticalSwipeAlwaysNext = false
            case "--swipe-down-next": o.config.swipeUpIsNext = false
            case "--horizontal-tracks": o.config.enableHorizontalSwipe = true
            case "--no-vertical": o.config.enableVerticalSwipe = false
            case "--no-desktops": o.config.enablePalmSwipe = false
            case "--no-mission-control": o.config.enablePalmVerticalSwipe = false
            case "--palm-follows": o.config.palmRightGoesLeft = false
            case "--palm-hold": o.config.palmRequireHold = true
            case "--no-cursor": o.config.enablePointer = false
            case "--pinch-index": o.config.pinchFinger = .index
            case "--no-scroll": o.config.enableScroll = false
            case "--scroll-reverse": o.config.scrollReverse = true
            case "--circle-volume": o.config.enableCircleVolume = true
            case "--knob": o.config.enableKnob = true
            case "--no-hand-shapes": o.config.enableHandShapes = false
            case "--no-thumbs-up": o.config.enableThumbsUpFn = false
            case "--sensitivity":
                i += 1
                if i < args.count, let s = Double(args[i]), s > 0 {
                    let k = min(max(s, 0.3), 2.0)
                    o.config.circleStartDegrees = max(180, 270 / k)
                    o.config.circleStepDegrees = 360 / k
                    o.config.circleMinDiameter = 0.07 / k
                    o.config.swipeMinDistance = 0.16 / k
                }
            case "-h", "--help":
                print(usage)
                exit(0)
            default:
                print("Unknown option: \(a)\n")
                print(usage)
                exit(2)
            }
            i += 1
        }
        return o
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    let options: Options
    let tracker = HandTracker()
    let media = MediaController()
    let cursor = CursorController()
    let engine: GestureEngine
    var preview: PreviewWindowController?
    var trail: [Vec2] = []
    var lastDebugPose: HandPose?
    var log: FileHandle?
    var calibration: CalibrationController?

    init(options: Options) {
        self.options = options
        engine = GestureEngine(config: options.config)
        super.init()
        media.dryRun = options.dryRun
        cursor.dryRun = options.dryRun
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        ensureCameraAccess { [weak self] granted in
            guard let self = self else { return }
            guard granted else {
                print("""
                [AirDial] Camera access denied.
                  System Settings → Privacy & Security → Camera → enable the app you launched AirDial from
                  (e.g. Terminal / iTerm / VS Code), then quit and reopen that app.
                """)
                NSApp.terminate(nil)
                return
            }
            self.startTracking()
        }

        if !options.dryRun, !media.hasAccessibility {
            media.requestAccessibility()
            print("""
            [AirDial] Accessibility permission not granted yet → using AppleScript fallback
                      (system volume + Music/Spotify only).
                      For media keys that work with every player and show the volume HUD:
                      System Settings → Privacy & Security → Accessibility → enable your terminal app.
            """)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !options.headless
    }

    func applicationWillTerminate(_ notification: Notification) {
        tracker.stop()
    }

    private func ensureCameraAccess(_ done: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            done(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { done(granted) }
            }
        default:
            done(false)
        }
    }

    private func startTracking() {
        do {
            let cam = try tracker.configure(cameraNameContains: options.cameraName)
            print("[AirDial] Camera: \(cam.localizedName)")
            if options.tracker != "vision" {
                if let found = MediaPipeBackend.locate(python: options.pythonPath, model: options.modelPath),
                   let mp = MediaPipeBackend(python: found.python, script: found.script, model: found.model) {
                    tracker.mediaPipe = mp
                    print("[AirDial] Hand tracking: MediaPipe (3D joints), \(found.python)")
                } else if options.tracker == "mediapipe" {
                    print("[AirDial] MediaPipe was requested but isn't available; using Apple Vision.")
                }
            }
            if tracker.mediaPipe == nil { print("[AirDial] Hand tracking: Apple Vision (2D joints)") }
        } catch {
            print("[AirDial] \(error.localizedDescription)")
            NSApp.terminate(nil)
            return
        }

        if let path = options.logPath {
            FileManager.default.createFile(atPath: path, contents: nil)
            log = FileHandle(forWritingAtPath: path)
            log?.write(("t,vision_ms,dropped,hand_conf,wrist,indexTip,indexPIP,middleTip,middlePIP,ringTip,littleTip," +
                        "raw_pose,active_pose,tip_x,tip_y,cursor_x,cursor_y,circle_deg,engaged,action," +
                        HandTracker.logJoints.map { "\($0.0)_x,\($0.0)_y,\($0.0)_c" }.joined(separator: ",") + "," +
                        (0..<21).map { "w\($0)_x,w\($0)_y,w\($0)_z" }.joined(separator: ",") + "\n").data(using: .utf8)!)
            print("[AirDial] Logging frames to \(path)")
        }

        tracker.onFrame = { [weak self] sample, time, aspect, info in
            DispatchQueue.main.async { self?.handle(sample, time: time, aspect: aspect, info: info) }
        }

        if !options.headless {
            let p = PreviewWindowController(session: tracker.session)
            p.show()
            preview = p
        }
        tracker.start()

        if options.config.enablePointer {
            if options.calibrate && !options.dryRun {
                startCalibration()
            } else if let saved = CalibrationController.loadSaved(for: cursor.screens) {
                cursor.calibration = saved
                print("[AirDial] Cursor: using the saved calibration.")
            }
        }
        print("[AirDial] Running. ☝️ point = cursor, 🤞 circle = volume, ✌️ swipe = next track, 🖐 swipe = desktops." + (options.headless ? " Ctrl+C to quit." : ""))
    }

    @objc func startCalibration() {
        guard calibration?.isActive != true else { return }
        cursor.reloadScreens()
        let c = CalibrationController(screens: cursor.screens) { [weak self] result in
            if let r = result { self?.cursor.calibration = r }
            else if let saved = CalibrationController.loadSaved(for: self?.cursor.screens ?? []) {
                self?.cursor.calibration = saved
                print("[AirDial] Using the last saved calibration.")
            }
        }
        calibration = c
        c.start()
    }

    private func handle(_ sample: HandSample?, time: Double, aspect: Double, info: FrameInfo) {
        let actions = engine.process(sample, time: time, aspect: aspect)
        if let cal = calibration, cal.isActive {
            // Calibrating: only collect fingertip positions; no cursor moves or actions.
            cal.update(tip: engine.status.pointerLiveTip, handVisible: engine.status.rawPose != .none, aspect: aspect, time: time)
            writeLog(sample, time: time, info: info, actions: actions, note: "calibrating")
            preview?.overlay.status = engine.status
            preview?.overlay.needsDisplay = true
            return
        }
        if let p = engine.status.pointer { cursor.move(to: p, tip: engine.status.pointerTip) }
        if engine.status.scroll != 0 { cursor.scroll(pixels: engine.status.scroll) }
        for a in actions {
            switch a {
            case .pointerPress: cursor.press()
            case .pointerRelease: cursor.release()
            case .pointerRightClick: cursor.rightClick()
            default: media.perform(a)
            }
        }

        let status = engine.status
        writeLog(sample, time: time, info: info, actions: actions)
        if options.debug, status.rawPose != lastDebugPose {
            print("[pose] raw=\(status.rawPose.rawValue) active=\(status.pose.rawValue)")
            lastDebugPose = status.rawPose
        }

        guard let overlay = preview?.overlay else { return }
        if let c = status.cursor {
            trail.append(c)
            if trail.count > 45 { trail.removeFirst(trail.count - 45) }
        } else {
            trail.removeAll()
        }
        overlay.aspect = aspect
        overlay.status = status
        overlay.trail = trail
        if let a = actions.last(where: { $0 != .pointerRelease && $0 != .fnUp }) {
            overlay.lastAction = (label(for: a), Date())
        }
        overlay.needsDisplay = true
    }

    private func writeLog(_ sample: HandSample?, time: Double, info: FrameInfo, actions: [GestureAction], note: String = "") {
        guard let log = log else { return }
        let status = engine.status
        do {
            func f(_ v: Double?) -> String { v.map { String(format: "%.4f", $0) } ?? "" }
            let j = ["wrist", "indexTip", "indexPIP", "middleTip", "middlePIP", "ringTip", "littleTip"]
                .map { String(format: "%.2f", info.jointConf[$0] ?? 0) }
            let tip = sample?.tip(.index)
            var cols: [String] = [String(format: "%.4f", time), String(format: "%.1f", info.visionMs), "\(info.droppedBefore)",
                                  String(format: "%.2f", info.handConfidence)]
            cols += j
            cols += [status.rawPose.rawValue, status.pose.rawValue, f(tip?.x), f(tip?.y), f(status.cursor?.x), f(status.cursor?.y)]
            cols += [String(format: "%.0f", status.circleDegrees), status.circleEngaged ? "1" : "0",
                     (actions.map { $0.rawValue } + (note.isEmpty ? [] : [note])).joined(separator: "|")]
            if info.rawJoints.isEmpty {
                cols += Array(repeating: "", count: HandTracker.logJoints.count * 3)
            } else {
                for p in info.rawJoints {
                    cols += [String(format: "%.4f", p.x), String(format: "%.4f", p.y), String(format: "%.2f", p.c)]
                }
            }
            if info.world.count == 21 {
                for p in info.world { cols += [String(format: "%.4f", p.x), String(format: "%.4f", p.y), String(format: "%.4f", p.z)] }
            } else {
                cols += Array(repeating: "", count: 21 * 3)
            }
            log.write((cols.joined(separator: ",") + "\n").data(using: .utf8)!)
        }
    }

    private func label(for a: GestureAction) -> String {
        switch a {
        case .volumeUp: return "🔊 Volume +"
        case .volumeDown: return "🔉 Volume −"
        case .nextTrack: return "⏭ Next track"
        case .previousTrack: return "⏮ Previous track"
        case .desktopLeft: return "⬅️ Desktop on the left"
        case .desktopRight: return "➡️ Desktop on the right"
        case .missionControl: return "🪟 Mission Control"
        case .pointerPress: return "🖱 Click"
        case .pointerRelease: return ""
        case .pointerRightClick: return "🖱 Right click"
        case .fnDown: return "👍 Fn held"
        case .fnUp: return ""
        case .exitFullScreen: return "✊ Exit full screen"
        case .enterFullScreen: return "🖐 Full screen"
        }
    }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        let recal = NSMenuItem(title: "Recalibrate Cursor", action: #selector(startCalibration), keyEquivalent: "r")
        recal.target = self
        appMenu.addItem(recal)
        appMenu.addItem(withTitle: "Quit AirDial", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        NSApp.mainMenu = main
    }
}

// MARK: - Entry point

setvbuf(stdout, nil, _IOLBF, 0)  // line-buffer output even when piped
let options = Options.parse(Array(CommandLine.arguments.dropFirst()))

if options.listCameras {
    for cam in HandTracker.availableCameras() {
        print("- \(cam.localizedName)")
    }
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(options.headless ? .accessory : .regular)
let delegate = AppDelegate(options: options)
app.delegate = delegate
signal(SIGINT) { _ in exit(0) }
app.run()

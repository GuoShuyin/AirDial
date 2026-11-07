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
    var config = GestureConfig()

    static let usage = """
    AirDial — mid-air gestures for music on macOS (uses the built-in webcam)

      ☝️  Index finger, draw a circle   clockwise = volume up, counter-clockwise = volume down
      ✌️  Two fingers (V), swipe        up or down = next track (right / left = next / previous)
      🖐  Open palm facing the camera, swipe   sideways = switch desktop, up or down = Mission Control on/off

    Usage: AirDial [options]
      --headless          No preview window (runs in the background, Ctrl+C to quit)
      --dry-run           Recognize gestures but don't change volume / tracks
      --debug             Print the raw pose of every frame
      --log FILE          Write per-frame diagnostics (CSV) to FILE
      --camera NAME       Use the camera whose name contains NAME
      --list-cameras      List cameras and exit
      --ccw-up            Counter-clockwise = volume up (reverse the knob)
      --vertical-prev     Two fingers up = next, down = previous (default: both = next)
      --swipe-down-next   With --vertical-prev: down = next, up = previous
      --no-horizontal     Disable left/right swipes
      --no-vertical       Disable up/down swipes
      --no-desktops       Disable open-palm swipes (desktops and Mission Control)
      --no-mission-control  Disable open-palm up/down = Mission Control
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
            case "--log":
                i += 1
                if i < args.count { o.logPath = args[i] }
            case "--camera":
                i += 1
                if i < args.count { o.cameraName = args[i] }
            case "--ccw-up": o.config.clockwiseIsVolumeUp = false
            case "--vertical-prev": o.config.verticalSwipeAlwaysNext = false
            case "--swipe-down-next": o.config.swipeUpIsNext = false
            case "--no-horizontal": o.config.enableHorizontalSwipe = false
            case "--no-vertical": o.config.enableVerticalSwipe = false
            case "--no-desktops": o.config.enablePalmSwipe = false
            case "--no-mission-control": o.config.enablePalmVerticalSwipe = false
            case "--palm-follows": o.config.palmRightGoesLeft = false
            case "--palm-hold": o.config.palmRequireHold = true
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
    let engine: GestureEngine
    var preview: PreviewWindowController?
    var trail: [Vec2] = []
    var lastDebugPose: HandPose?
    var log: FileHandle?

    init(options: Options) {
        self.options = options
        engine = GestureEngine(config: options.config)
        super.init()
        media.dryRun = options.dryRun
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
                        HandTracker.logJoints.map { "\($0.0)_x,\($0.0)_y,\($0.0)_c" }.joined(separator: ",") + "\n").data(using: .utf8)!)
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
        print("[AirDial] Running. ☝️ draw circles for volume, ✌️ swipe for tracks." + (options.headless ? " Ctrl+C to quit." : ""))
    }

    private func handle(_ sample: HandSample?, time: Double, aspect: Double, info: FrameInfo) {
        let actions = engine.process(sample, time: time)
        for a in actions { media.perform(a) }

        let status = engine.status
        if let log = log {
            func f(_ v: Double?) -> String { v.map { String(format: "%.4f", $0) } ?? "" }
            let j = ["wrist", "indexTip", "indexPIP", "middleTip", "middlePIP", "ringTip", "littleTip"]
                .map { String(format: "%.2f", info.jointConf[$0] ?? 0) }
            let tip = sample?.tip(.index)
            var cols: [String] = [String(format: "%.4f", time), String(format: "%.1f", info.visionMs), "\(info.droppedBefore)",
                                  String(format: "%.2f", info.handConfidence)]
            cols += j
            cols += [status.rawPose.rawValue, status.pose.rawValue, f(tip?.x), f(tip?.y), f(status.cursor?.x), f(status.cursor?.y)]
            cols += [String(format: "%.0f", status.circleDegrees), status.circleEngaged ? "1" : "0",
                     actions.map { $0.rawValue }.joined(separator: "|")]
            if info.rawJoints.isEmpty {
                cols += Array(repeating: "", count: HandTracker.logJoints.count * 3)
            } else {
                for p in info.rawJoints {
                    cols += [String(format: "%.4f", p.x), String(format: "%.4f", p.y), String(format: "%.2f", p.c)]
                }
            }
            log.write((cols.joined(separator: ",") + "\n").data(using: .utf8)!)
        }
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
        if let a = actions.last {
            overlay.lastAction = (label(for: a), Date())
        }
        overlay.needsDisplay = true
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
        }
    }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
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

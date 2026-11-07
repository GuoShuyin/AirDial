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
    var config = GestureConfig()

    static let usage = """
    AirDial — mid-air gestures for music on macOS (uses the built-in webcam)

      ☝️  Index finger, draw a circle   clockwise = volume up, counter-clockwise = volume down
      ✌️  Two fingers (V), swipe        up / right = next track, down / left = previous track

    Usage: AirDial [options]
      --headless          No preview window (runs in the background, Ctrl+C to quit)
      --dry-run           Recognize gestures but don't change volume / tracks
      --debug             Print the raw pose of every frame
      --camera NAME       Use the camera whose name contains NAME
      --list-cameras      List cameras and exit
      --ccw-up            Counter-clockwise = volume up (reverse the knob)
      --swipe-down-next   Two fingers down = next track (reverse vertical swipe)
      --no-horizontal     Disable left/right swipes
      --no-vertical       Disable up/down swipes
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
            case "--camera":
                i += 1
                if i < args.count { o.cameraName = args[i] }
            case "--ccw-up": o.config.clockwiseIsVolumeUp = false
            case "--swipe-down-next": o.config.swipeUpIsNext = false
            case "--no-horizontal": o.config.enableHorizontalSwipe = false
            case "--no-vertical": o.config.enableVerticalSwipe = false
            case "--sensitivity":
                i += 1
                if i < args.count, let s = Double(args[i]), s > 0 {
                    let k = min(max(s, 0.3), 2.0)
                    o.config.circleStartDegrees = max(180, 270 / k)
                    o.config.circleStepDegrees = 90 / k
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

        tracker.onFrame = { [weak self] sample, time, aspect in
            DispatchQueue.main.async { self?.handle(sample, time: time, aspect: aspect) }
        }

        if !options.headless {
            let p = PreviewWindowController(session: tracker.session)
            p.show()
            preview = p
        }
        tracker.start()
        print("[AirDial] Running. ☝️ draw circles for volume, ✌️ swipe for tracks." + (options.headless ? " Ctrl+C to quit." : ""))
    }

    private func handle(_ sample: HandSample?, time: Double, aspect: Double) {
        let actions = engine.process(sample, time: time)
        for a in actions { media.perform(a) }

        let status = engine.status
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
        case .volumeUp: return "🔊 音量 +"
        case .volumeDown: return "🔉 音量 −"
        case .nextTrack: return "⏭ 下一首"
        case .previousTrack: return "⏮ 上一首"
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

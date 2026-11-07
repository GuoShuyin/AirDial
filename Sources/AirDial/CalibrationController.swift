import AppKit
import AirDialCore
import Foundation

/// Start-up calibration of the finger cursor: shows targets on every display one after another;
/// you point at each and hold still until it chimes. Saved to
/// ~/Library/Application Support/AirDial/calibration.json.
final class CalibrationController {
    private struct Target { var screen: Int; var x: Double; var y: Double }

    private let screens: [CGRect]          // global, top-left origin
    private let nsScreens: [NSScreen]
    private var targets: [Target] = []
    private var index = 0
    private var samples: [PointerCalibration.Sample] = []
    private var steady: [(t: Double, p: Vec2)] = []
    private var visibleTime = 0.0          // time with a hand in view on the current dot
    private var lastUpdate: Double?
    private var started = false            // first dot shown (after you start pointing)
    private var pointingSince: Double?
    private var windows: [NSWindow] = []
    private var views: [TargetView] = []
    private let chime = NSSound(named: "Tink")
    private let onDone: (PointerCalibration?) -> Void

    /// Hold the fingertip within this distance (camera units) for `holdTime` to record a target.
    /// The ring only starts once the finger has settled; any movement resets it.
    var holdRadius = 0.008
    var holdTime = 0.8
    /// After a dot appears, this long is for moving your finger there; nothing is recorded.
    var moveGrace = 1.0
    private var dotShownAt: Double?
    /// Give up on a target after this much time *with a hand in view* (it is skipped).
    /// Time without a hand doesn't count: the calibration simply waits for you.
    var targetTimeout = 12.0
    /// Point for this long to begin.
    var startHold = 0.5

    private(set) var isActive = false

    static var savedURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AirDial")
        return dir.appendingPathComponent("calibration.json")
    }

    static func loadSaved(for screens: [CGRect]) -> PointerCalibration? {
        guard let data = try? Data(contentsOf: savedURL),
              let c = try? JSONDecoder().decode(PointerCalibration.self, from: data), c.isValid(for: screens) else { return nil }
        return c
    }

    init(screens: [CGRect], onDone: @escaping (PointerCalibration?) -> Void) {
        self.screens = screens
        nsScreens = NSScreen.screens
        self.onDone = onDone
        // Left to right, so the sequence follows the display arrangement.
        let order = screens.indices.sorted { screens[$0].minX < screens[$1].minX }
        for s in order {
            for t in PointerCalibration.targets { targets.append(Target(screen: s, x: t.x, y: t.y)) }
        }
    }

    func start() {
        isActive = true
        for (i, s) in nsScreens.enumerated() where i < screens.count {
            let w = NSWindow(contentRect: s.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.level = .statusBar
            w.ignoresMouseEvents = true
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            let v = TargetView(frame: NSRect(origin: .zero, size: s.frame.size))
            w.contentView = v
            w.orderFrontRegardless()
            windows.append(w)
            views.append(v)
        }
        print("[AirDial] Calibration: point your index finger at each dot and hold still until it chimes (\(targets.count) dots).")
        refresh()
    }

    private func refresh() {
        for (i, v) in views.enumerated() {
            v.progress = 0
            guard started else {
                v.target = nil
                v.caption = "AirDial calibration: raise your index finger and point at this screen to begin"
                v.needsDisplay = true
                continue
            }
            if index < targets.count, targets[index].screen == i {
                v.target = CGPoint(x: targets[index].x, y: targets[index].y)
                v.caption = "Point at the dot with your index finger and hold still (\(index + 1)/\(targets.count))"
            } else {
                v.target = nil
                if index < targets.count {
                    let active = screens[targets[index].screen]
                    let side = active.midX < screens[i].minX ? "← to the left" : (active.midX > screens[i].maxX ? "to the right →" : "on another display")
                    v.caption = "Calibrating: the dot is on the display \(side)"
                } else {
                    v.caption = ""
                }
            }
            v.needsDisplay = true
        }
    }

    /// Feed every frame: the smoothed fingertip while pointing (or nil), and whether any hand is in view.
    func update(tip: Vec2?, handVisible: Bool, time t: Double) {
        guard isActive, index < targets.count else { return }
        let dt = lastUpdate.map { min(t - $0, 0.2) } ?? 0
        lastUpdate = t

        // Wait until you start pointing.
        if !started {
            if tip != nil {
                let since = pointingSince ?? t
                pointingSince = since
                if t - since >= startHold {
                    started = true
                    print("[AirDial] Calibration started.")
                    refresh()
                }
            } else {
                pointingSince = nil
            }
            return
        }

        if handVisible { visibleTime += dt }
        if visibleTime > targetTimeout {
            print("[AirDial] Calibration: skipped dot \(index + 1) (no steady pointing).")
            advance()
            return
        }
        // Time to move to the new dot first.
        if dotShownAt == nil { dotShownAt = t }
        if let shown = dotShownAt, t - shown < moveGrace { steady.removeAll(); return }
        guard let tip = tip else { steady.removeAll(); views.forEach { $0.progress = 0; $0.needsDisplay = true }; return }
        steady.append((t, tip))
        // Keep only the stretch where the fingertip stayed within holdRadius of the latest point.
        while let first = steady.first, first.p.distance(to: tip) > holdRadius { steady.removeFirst() }
        let held = (steady.last?.t ?? t) - (steady.first?.t ?? t)
        let screen = targets[index].screen
        if screen < views.count { views[screen].progress = min(held / holdTime, 1); views[screen].needsDisplay = true }
        guard held >= holdTime else { return }

        let n = Double(steady.count)
        let mean = Vec2(steady.reduce(0) { $0 + $1.p.x } / n, steady.reduce(0) { $0 + $1.p.y } / n)
        samples.append(.init(screen: screen, targetX: targets[index].x, targetY: targets[index].y, tip: mean))
        chime?.stop()
        chime?.play()
        advance()
    }

    private func advance() {
        index += 1
        steady.removeAll()
        visibleTime = 0
        dotShownAt = nil
        if index >= targets.count { finish() } else { refresh() }
    }

    private func finish() {
        isActive = false
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        views.removeAll()
        let c = PointerCalibration(samples: samples, screens: screens)
        guard c.isValid(for: screens) else {
            print("[AirDial] Calibration incomplete (\(samples.count) of \(targets.count) dots); using automatic reach instead.")
            onDone(nil)
            return
        }
        do {
            try FileManager.default.createDirectory(at: CalibrationController.savedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(c).write(to: CalibrationController.savedURL)
        } catch {
            print("[AirDial] Couldn't save the calibration: \(error.localizedDescription)")
        }
        print("[AirDial] Calibration done (\(samples.count) of \(targets.count) dots).")
        onDone(c)
    }
}

/// Draws the current calibration target on one display.
private final class TargetView: NSView {
    var target: CGPoint?        // fractions, x right, y down
    var caption = ""
    var progress = 0.0

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(target == nil ? 0.15 : 0.35).setFill()
        bounds.fill()
        guard let t = target else { return }
        let c = NSPoint(x: bounds.width * t.x, y: bounds.height * (1 - t.y))
        let ring = NSBezierPath(ovalIn: NSRect(x: c.x - 40, y: c.y - 40, width: 80, height: 80))
        ring.lineWidth = 4
        NSColor.white.setStroke()
        ring.stroke()
        if progress > 0 {
            let arc = NSBezierPath()
            arc.appendArc(withCenter: c, radius: 40, startAngle: 90, endAngle: 90 - 360 * progress, clockwise: true)
            arc.lineWidth = 8
            NSColor.systemGreen.setStroke()
            arc.stroke()
        }
        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: NSRect(x: c.x - 10, y: c.y - 10, width: 20, height: 20)).fill()

        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 22, weight: .semibold), .foregroundColor: NSColor.white]
        let s = NSAttributedString(string: caption, attributes: attrs)
        let size = s.size()
        let y = t.y < 0.5 ? c.y - 90 - size.height : c.y + 70
        s.draw(at: NSPoint(x: min(max(c.x - size.width / 2, 20), bounds.width - size.width - 20), y: y))
    }
}

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
    /// The finger must first move this far (camera units) after a dot appears: otherwise a finger
    /// still resting from the previous step gets recorded before you even saw the new dot.
    var mustMove = 0.04
    private var anchor: Vec2?
    private var moved = false
    private let newDotSound = NSSound(named: "Pop")
    /// Give up on a target after this much time *with a hand in view* (it is skipped).
    /// Time without a hand doesn't count: the calibration simply waits for you.
    var targetTimeout = 12.0
    /// Calibration begins once your index finger has been in the middle of the camera picture for
    /// `startHold` (moving is fine), followed by a `startDelay` countdown.
    var startHold = 0.3
    var startDelay = 2.0
    private var countdownFrom: Double?

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
        for t in PointerCalibration.targets(screenCount: screens.count, order: order) {
            targets.append(Target(screen: t.screen, x: t.x, y: t.y))
        }
    }

    func start() {
        isActive = true
        for (i, s) in nsScreens.enumerated() where i < screens.count {
            // Created for that screen explicitly (rect relative to it), then placed on its frame:
            // a plain global rect left the window off the MacBook display.
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: s.frame.size), styleMask: .borderless,
                             backing: .buffered, defer: false, screen: s)
            w.setFrame(s.frame, display: true)
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
                v.caption = "AirDial calibration: hold up your index finger in the middle of the camera picture to begin"
                v.needsDisplay = true
                continue
            }
            v.active = index < targets.count && targets[index].screen == i
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

    /// Feed every frame: the smoothed fingertip while pointing (or nil), whether any hand is in
    /// view, and the camera frame aspect (fingertip x runs from 0 to aspect).
    func update(tip: Vec2?, handVisible: Bool, aspect: Double, time t: Double) {
        guard isActive, index < targets.count else { return }
        let dt = lastUpdate.map { min(t - $0, 0.2) } ?? 0
        lastUpdate = t

        if !started {
            if let from = countdownFrom {
                // Counting down: show it, then start.
                let left = startDelay - (t - from)
                if left <= 0 {
                    started = true
                    print("[AirDial] Calibration started.")
                    refresh()
                    newDotSound?.play()
                } else {
                    let text = "Index finger found. Starting in \(Int(left.rounded(.up)))…"
                    for v in views where v.caption != text { v.caption = text; v.needsDisplay = true }
                }
                return
            }
            // Wait for an index finger in the middle of the picture (moving is fine).
            if let tip = tip, (0.25...0.75).contains(tip.x / aspect), (0.2...0.8).contains(tip.y) {
                let since = pointingSince ?? t
                pointingSince = since
                if t - since >= startHold { countdownFrom = t }
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
        if let shown = dotShownAt, t - shown < moveGrace {
            steady.removeAll()
            if anchor == nil, let tip = tip { anchor = tip }
            return
        }
        guard let tip = tip else { steady.removeAll(); views.forEach { $0.progress = 0; $0.needsDisplay = true }; return }
        if !moved {
            if anchor == nil { anchor = tip }
            if let a = anchor, tip.distance(to: a) >= mustMove { moved = true } else { return }
        }
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
        anchor = nil
        moved = false
        if index >= targets.count { finish() } else { refresh(); newDotSound?.stop(); newDotSound?.play() }
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
    var active = false

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(target == nil ? 0.15 : 0.35).setFill()
        bounds.fill()
        if active {
            // A bright frame around the display that has the dot.
            let frame = NSBezierPath(rect: bounds.insetBy(dx: 6, dy: 6))
            frame.lineWidth = 12
            NSColor.systemYellow.setStroke()
            frame.stroke()
        }
        guard let t = target else {
            drawCaption(at: NSPoint(x: bounds.midX, y: bounds.midY))
            return
        }
        let c = NSPoint(x: bounds.width * t.x, y: bounds.height * (1 - t.y))
        let r: CGFloat = 60
        let ring = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        ring.lineWidth = 6
        NSColor.white.setStroke()
        ring.stroke()
        if progress > 0 {
            let arc = NSBezierPath()
            arc.appendArc(withCenter: c, radius: r, startAngle: 90, endAngle: 90 - 360 * progress, clockwise: true)
            arc.lineWidth = 12
            NSColor.systemGreen.setStroke()
            arc.stroke()
        }
        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: NSRect(x: c.x - 16, y: c.y - 16, width: 32, height: 32)).fill()

        drawCaption(at: NSPoint(x: c.x, y: t.y < 0.5 ? c.y - 110 : c.y + 110))
    }

    private func drawCaption(at p: NSPoint) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 26, weight: .semibold), .foregroundColor: NSColor.white]
        let s = NSAttributedString(string: caption, attributes: attrs)
        let size = s.size()
        s.draw(at: NSPoint(x: min(max(p.x - size.width / 2, 20), bounds.width - size.width - 20), y: p.y - size.height / 2))
    }
}

import AppKit
import AirDialCore
import CoreGraphics
import Foundation

/// Moves the real mouse cursor to where the index finger points, across all displays as they are
/// arranged in System Settings → Displays, and clicks on a thumb-index pinch.
///
/// The mapping onto the displays is `ScreenMapper` (side by side horizontally, per display vertically).
///
/// When you move the real mouse or trackpad, finger control pauses for a moment instead of
/// fighting you.
final class CursorController {
    var dryRun = false
    /// After the real mouse moves, ignore the finger for this long (seconds).
    var userOverridePause: TimeInterval = 1.5

    private var screens: [CGRect] = []   // global display coordinates (origin top-left of main display, y down)
    private var lastPosted: CGPoint?
    private var pausedUntil = Date.distantPast
    private var buttonDown = false
    private var warnedAccessibility = false

    init() {
        reloadScreens()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.reloadScreens() }
    }

    func reloadScreens() {
        let all = NSScreen.screens
        guard let main = all.first else { screens = []; return }
        let mainHeight = main.frame.height
        // AppKit: origin bottom-left of the main display, y up. Quartz: origin top-left, y down.
        screens = all.map { s in
            CGRect(x: s.frame.minX, y: mainHeight - s.frame.maxY, width: s.frame.width, height: s.frame.height)
        }
        let desc = screens.map { "\(Int($0.width))x\(Int($0.height))@(\(Int($0.minX)),\(Int($0.minY)))" }.joined(separator: " ")
        print("[AirDial] Displays for the finger cursor: \(desc)")
    }

    /// Global point for a normalized pointer position.
    func point(for p: Vec2) -> CGPoint? { ScreenMapper.point(for: p, screens: screens) }

    private var currentMouse: CGPoint? { CGEvent(source: nil)?.location }

    private func canPost() -> Bool {
        guard !dryRun else { return false }
        guard AXIsProcessTrusted() else {
            if !warnedAccessibility {
                warnedAccessibility = true
                print("[AirDial] The finger cursor needs Accessibility permission for your terminal app.")
            }
            return false
        }
        return true
    }

    /// Called every frame while pointing.
    func move(to p: Vec2) {
        guard canPost(), let target = point(for: p) else { return }
        // Did the user move the real mouse since our last move?
        if let last = lastPosted, let now = currentMouse, hypot(now.x - last.x, now.y - last.y) > 3, !buttonDown {
            pausedUntil = Date().addingTimeInterval(userOverridePause)
            lastPosted = nil
        }
        guard Date() >= pausedUntil else { return }
        if let last = lastPosted, hypot(target.x - last.x, target.y - last.y) < 1 { return }
        let type: CGEventType = buttonDown ? .leftMouseDragged : .mouseMoved
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: target, mouseButton: .left)?.post(tap: .cghidEventTap)
        lastPosted = target
    }

    func press() {
        guard canPost(), Date() >= pausedUntil, let at = lastPosted ?? currentMouse else { return }
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: at, mouseButton: .left)?.post(tap: .cghidEventTap)
        buttonDown = true
    }

    func release() {
        guard buttonDown else { return }
        buttonDown = false
        guard let at = lastPosted ?? currentMouse else { return }
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: at, mouseButton: .left)?.post(tap: .cghidEventTap)
    }
}

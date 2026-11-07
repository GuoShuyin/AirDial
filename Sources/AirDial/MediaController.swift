import AppKit
import AirDialCore
import ApplicationServices
import Foundation

/// Performs the actual music/volume actions.
///
/// Preferred path: simulate the keyboard's media keys (volume up/down, next, previous).
/// This works with any player (Music, Spotify, browser, ...) and shows the system volume HUD,
/// but needs Accessibility permission for the app running AirDial (e.g. Terminal).
/// Fallback without that permission: AppleScript (system volume + Music/Spotify).
final class MediaController {
    // NX_KEYTYPE_* from IOKit/hidsystem/ev_keymap.h
    private enum MediaKey: Int32 {
        case soundUp = 0
        case soundDown = 1
        case next = 17
        case previous = 18
    }

    var dryRun = false
    /// Volume step for the AppleScript fallback (0-100 scale).
    var fallbackVolumeStep = 6

    var hasAccessibility: Bool { AXIsProcessTrusted() }

    /// The last app other than AirDial that was frontmost. Clicking the AirDial preview makes it
    /// the front app, and window actions should still go to the app you were using.
    private var lastOtherApp: NSRunningApplication?

    init() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
               app.processIdentifier != getpid() {
                self?.lastOtherApp = app
            }
        }
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != getpid() { lastOtherApp = front }
    }

    /// Shows the system prompt asking the user to grant Accessibility permission.
    @discardableResult
    func requestAccessibility() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func perform(_ action: GestureAction) {
        if action == .pointerPress || action == .pointerRelease || action == .pointerRightClick { return }  // CursorController
        print("[AirDial] \(action.rawValue)\(dryRun ? " (dry run)" : "")")
        guard !dryRun else { return }

        if action == .exitFullScreen || action == .enterFullScreen {
            guard hasAccessibility else {
                print("[AirDial] Full screen control needs Accessibility permission for your terminal app.")
                return
            }
            setFrontWindowFullScreen(action == .enterFullScreen)
            return
        }

        if action == .desktopLeft || action == .desktopRight || action == .missionControl {
            guard hasAccessibility else {
                print("[AirDial] Desktops and Mission Control need Accessibility permission for your terminal app.")
                return
            }
            switch action {
            case .desktopLeft: postControlArrow(123)
            case .desktopRight: postControlArrow(124)
            default: postControlArrow(126)  // Control+Up toggles Mission Control
            }
            return
        }

        if hasAccessibility {
            switch action {
            case .volumeUp: postMediaKey(.soundUp)
            case .volumeDown: postMediaKey(.soundDown)
            case .nextTrack: postMediaKey(.next)
            case .previousTrack: postMediaKey(.previous)
            case .desktopLeft, .desktopRight, .missionControl, .pointerPress, .pointerRelease, .pointerRightClick,
                 .exitFullScreen, .enterFullScreen: break
            }
            return
        }

        switch action {
        case .volumeUp:
            runAppleScript("set volume output volume ((output volume of (get volume settings)) + \(fallbackVolumeStep))")
        case .volumeDown:
            runAppleScript("set volume output volume ((output volume of (get volume settings)) - \(fallbackVolumeStep))")
        case .nextTrack:
            tellPlayer("next track")
        case .previousTrack:
            tellPlayer("previous track")
        case .desktopLeft, .desktopRight, .missionControl, .pointerPress, .pointerRelease, .pointerRightClick,
             .exitFullScreen, .enterFullScreen:
            break
        }
    }

    private func postMediaKey(_ key: MediaKey) {
        func send(down: Bool) {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00)
            let data1 = Int((key.rawValue << 16) | ((down ? 0xA : 0xB) << 8))
            let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: flags,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: data1,
                data2: -1
            )
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
        send(down: true)
        send(down: false)
    }

    /// Puts the front window into / out of full screen.
    ///
    /// Some apps (e.g. Chromium / Electron based ones) report `AXFullScreen` unreliably, so the
    /// window also counts as full screen when it exactly covers its display. The state is set
    /// through the Accessibility API; if it hasn't changed 0.6 s later, Ctrl+Cmd+F (the toggle)
    /// is sent, which is safe then because we know the window is in the other state.
    private func setFrontWindowFullScreen(_ on: Bool) {
        guard var app = NSWorkspace.shared.frontmostApplication else { return }
        if app.processIdentifier == getpid() {
            // The AirDial preview is in front: act on the app you were using before it.
            guard let other = lastOtherApp, !other.isTerminated else {
                print("[AirDial] Full screen: no other app to act on yet; click into the app you want first.")
                return
            }
            other.activate()
            app = other
        }
        let name = app.localizedName ?? "front app"
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let windowRef = value, CFGetTypeID(windowRef) == AXUIElementGetTypeID() else {
            print("[AirDial] Full screen: no focused window in \(name).")
            return
        }
        let window = windowRef as! AXUIElement
        let (ax, covers) = fullScreenState(window)
        let isFull = (ax ?? false) || covers
        let axText = ax.map { $0 ? "yes" : "no" } ?? "unreadable"
        guard isFull != on else {
            print("[AirDial] Full screen: \(name) already \(on ? "full screen" : "windowed") (AXFullScreen \(axText), covers display \(covers)).")
            return
        }
        let set = AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, (on ? kCFBooleanTrue : kCFBooleanFalse)!)
        print("[AirDial] Full screen: \(name) \(on ? "enter" : "exit") (AXFullScreen \(axText), covers display \(covers), set result \(set.rawValue)).")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            let (ax2, covers2) = self?.fullScreenState(window) ?? (nil, false)
            let nowFull = (ax2 ?? false) || covers2
            if nowFull != on {
                print("[AirDial] Full screen: \(name) didn't change; sending Ctrl+Cmd+F.")
                self?.postKey(3, [.maskCommand, .maskControl])
            }
        }
    }

    /// (AXFullScreen if readable, whether the window exactly covers a display).
    private func fullScreenState(_ window: AXUIElement) -> (Bool?, Bool) {
        var fs: CFTypeRef?
        let ax: Bool? = AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &fs) == .success ? (fs as? Bool) : nil
        var posRef: CFTypeRef?, sizeRef: CFTypeRef?
        var pos = CGPoint.zero, size = CGSize.zero
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let p = posRef, let z = sizeRef,
              AXValueGetValue(p as! AXValue, .cgPoint, &pos), AXValueGetValue(z as! AXValue, .cgSize, &size) else {
            return (ax, false)
        }
        // Display frames in global (top-left origin) coordinates, like AX positions.
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let covers = NSScreen.screens.contains { s in
            let f = CGRect(x: s.frame.minX, y: mainHeight - s.frame.maxY, width: s.frame.width, height: s.frame.height)
            return abs(f.minX - pos.x) <= 2 && abs(f.minY - pos.y) <= 2 && abs(f.width - size.width) <= 2 && abs(f.height - size.height) <= 2
        }
        return (ax, covers)
    }

    private func postKey(_ key: CGKeyCode, _ flags: CGEventFlags) {
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
        }
    }

    /// Control + ←/→/↑: the default shortcuts "Move left/right a space" and "Mission Control".
    private func postControlArrow(_ key: CGKeyCode) {
        let src = CGEventSource(stateID: .hidSystemState)
        // Real arrow-key presses carry the fn and numeric-pad flags; the shortcut matches those.
        let flags: CGEventFlags = [.maskControl, .maskSecondaryFn, .maskNumericPad]
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
        }
    }

    private func tellPlayer(_ command: String) {
        let running = NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier }
        if running.contains("com.spotify.client") {
            runAppleScript("tell application \"Spotify\" to \(command)")
        } else if running.contains("com.apple.Music") {
            runAppleScript("tell application \"Music\" to \(command)")
        } else {
            print("[AirDial] No Music/Spotify running. Grant Accessibility permission to control any player via media keys.")
        }
    }

    private func runAppleScript(_ source: String) {
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error = error {
            print("[AirDial] AppleScript error: \(error)")
        }
    }
}

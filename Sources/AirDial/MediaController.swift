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

    /// Shows the system prompt asking the user to grant Accessibility permission.
    @discardableResult
    func requestAccessibility() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func perform(_ action: GestureAction) {
        print("[AirDial] \(action.rawValue)\(dryRun ? " (dry run)" : "")")
        guard !dryRun else { return }

        if action == .desktopLeft || action == .desktopRight {
            guard hasAccessibility else {
                print("[AirDial] Switching desktops needs Accessibility permission for your terminal app.")
                return
            }
            postSpaceSwitch(left: action == .desktopLeft)
            return
        }

        if hasAccessibility {
            switch action {
            case .volumeUp: postMediaKey(.soundUp)
            case .volumeDown: postMediaKey(.soundDown)
            case .nextTrack: postMediaKey(.next)
            case .previousTrack: postMediaKey(.previous)
            case .desktopLeft, .desktopRight: break
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
        case .desktopLeft, .desktopRight:
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

    /// Control + ←/→: the default Mission Control shortcuts "Move left/right a space".
    private func postSpaceSwitch(left: Bool) {
        let key: CGKeyCode = left ? 123 : 124
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

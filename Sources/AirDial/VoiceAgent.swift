import AirDialCore
import AppKit
import Foundation

/// Voice commands for an AI agent, on top of hold-to-talk dictation (thumbs-up = Fn held).
///
/// Wispr Flow (and similar apps) put the dictated text on the clipboard and paste it. After the
/// thumbs-up ends, AirDial watches the clipboard for a few seconds; if the dictated text contains
/// the trigger word ("AGI"), it undoes the paste (Cmd+Z) and hands the rest of the sentence to a
/// Claude computer-use agent (`Support/agent.py`) working on the display under the mouse cursor.
/// Esc stops the agent.
final class VoiceAgent {
    var enabled = true
    var triggerWord = "AGI"
    /// How long to wait for the dictation app to paste after Fn is released.
    var clipboardWait: TimeInterval = 6
    /// Called with short status lines for the preview overlay.
    var onStatus: ((String) -> Void)?
    /// Posts Cmd+Z (provided by MediaController so modifiers are released afterwards).
    var undo: (() -> Void)?

    private var watchTimer: Timer?
    private var process: Process?
    private var escMonitor: Any?
    private let python: String?
    private let script: String?

    init(python: String?, script: String?) {
        self.python = python
        self.script = script
        escMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { self?.stop(reason: "Stopped (Esc).") }   // Esc
        }
    }

    var isRunning: Bool { process?.isRunning == true }

    /// The thumbs-up (Fn) was just released: watch for the dictated text.
    func dictationEnded() {
        guard enabled, !isRunning else { return }
        watchTimer?.invalidate()
        let pb = NSPasteboard.general
        let startCount = pb.changeCount
        let deadline = Date().addingTimeInterval(clipboardWait)
        var seen = startCount
        watchTimer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { [weak self] t in
            guard let self = self else { t.invalidate(); return }
            if Date() > deadline {
                t.invalidate()
                self.report(seen == startCount ? "Dictation: no text arrived from the dictation app."
                                               : "Dictation: no \"\(self.triggerWord)\" in it, typed normally.")
                return
            }
            guard pb.changeCount != seen else { return }
            seen = pb.changeCount
            guard let text = pb.string(forType: .string), let command = self.command(in: text) else {
                if pb.string(forType: .string) != nil { t.invalidate(); self.report("Dictation: no \"\(self.triggerWord)\" in it, typed normally.") }
                return
            }
            t.invalidate()
            // Let the paste land, then take it back out and run the command instead.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                self.undo?()
                self.start(command: command)
            }
        }
    }

    /// The command if `text` contains the trigger word (as a word), with the word removed.
    func command(in text: String) -> String? { TriggerWord.command(in: text, word: triggerWord) }

    /// The API key from the environment or the repository's .env file (never printed).
    private func apiKey() -> String? {
        if let k = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !k.isEmpty { return k }
        guard let script = script else { return nil }
        let root = URL(fileURLWithPath: script).deletingLastPathComponent().deletingLastPathComponent()
        guard let text = try? String(contentsOf: root.appendingPathComponent(".env"), encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0] == "ANTHROPIC_API_KEY" {
                let v = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                return v.isEmpty ? nil : v
            }
        }
        return nil
    }

    private func start(command: String) {
        guard let python = python, let script = script else {
            report("Agent: Python or Support/agent.py not found."); return
        }
        guard let key = apiKey() else {
            report("Agent: put ANTHROPIC_API_KEY in the .env file first."); return
        }
        // All displays, in global (top-left origin) points: the agent sees them as one screen.
        let mouse = CGEvent(source: nil)?.location ?? .zero
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let displays = NSScreen.screens.map { s in
            CGRect(x: s.frame.minX, y: mainHeight - s.frame.maxY, width: s.frame.width, height: s.frame.height)
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: python)
        p.arguments = [script, "--command", command,
                       "--displays", displays.map { "\(Int($0.minX)),\(Int($0.minY)),\(Int($0.width)),\(Int($0.height))" }
                           .joined(separator: ";"),
                       "--cursor", "\(Int(mouse.x)),\(Int(mouse.y))"]
        var env = ProcessInfo.processInfo.environment
        env["ANTHROPIC_API_KEY"] = key
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        // Python tracebacks etc. go to a log file instead of being lost.
        let logDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/AirDial")
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        let logURL = logDir.appendingPathComponent("agent.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        p.standardError = (try? FileHandle(forWritingTo: logURL)) ?? FileHandle.nullDevice
        var reported = false
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            for line in s.split(separator: "\n") {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
                let text = (obj["status"] ?? obj["done"] ?? obj["error"]).map { "\($0)" } ?? ""
                let prefix = obj["done"] != nil ? "Agent done: " : (obj["error"] != nil ? "Agent error: " : "Agent: ")
                if obj["done"] != nil || obj["error"] != nil { reported = true }
                DispatchQueue.main.async { self?.report(prefix + text) }
            }
        }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                self?.process = nil
                if proc.terminationStatus != 0, !reported, proc.terminationReason == .exit {
                    self?.report("Agent error: it stopped unexpectedly; details in ~/Library/Logs/AirDial/agent.log")
                }
            }
        }
        do {
            try p.run()
            process = p
            report("Agent: \(command)  (Esc to stop)")
        } catch {
            report("Agent: couldn't start: \(error.localizedDescription)")
        }
    }

    func stop(reason: String) {
        guard let p = process, p.isRunning else { return }
        p.terminate()
        process = nil
        report(reason)
    }

    private func report(_ s: String) {
        print("[AirDial] \(s)")
        onStatus?(s)
    }
}

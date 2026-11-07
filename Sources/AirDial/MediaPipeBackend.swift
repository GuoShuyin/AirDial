import CoreVideo
import Foundation

/// Runs MediaPipe Hand Landmarker (3D hand joints) in a local Python process
/// (`Support/mediapipe_hands.py`). AirDial keeps the camera; each frame's BGRA pixels go to the
/// process over a pipe and the joints come back as one JSON line. Fully offline.
final class MediaPipeBackend {
    struct Hand {
        var score: Float
        var image: [(x: Double, y: Double)]   // normalized, x right / y down, unmirrored camera image
        var world: [(x: Double, y: Double, z: Double)]  // metres, MediaPipe world landmarks
    }

    private let process = Process()
    private let toChild = Pipe()
    private let fromChild = Pipe()
    private var buffer = Data()

    /// Locates the Python interpreter, sidecar script and model, or returns nil with a reason.
    static func locate(python: String?, model: String?) -> (python: String, script: String, model: String)? {
        let fm = FileManager.default
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        // The repository root: the working directory, or three levels above .build/release/AirDial.
        let roots = [fm.currentDirectoryPath, exe.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().path]
        func first(_ candidates: [String]) -> String? { candidates.first { fm.isExecutableFile(atPath: $0) || fm.fileExists(atPath: $0) } }

        let env = ProcessInfo.processInfo.environment
        let pythonPath = python ?? env["AIRDIAL_PYTHON"] ?? first(roots.map { "\($0)/.venv/bin/python3" })
        let scriptPath = first(roots.map { "\($0)/Support/mediapipe_hands.py" })
        let modelPath = model ?? first(roots.map { "\($0)/models/hand_landmarker.task" })
        guard let p = pythonPath, fm.isExecutableFile(atPath: p) else {
            print("[AirDial] MediaPipe: no Python found (pass --python PATH or create .venv, see README).")
            return nil
        }
        guard let s = scriptPath else { print("[AirDial] MediaPipe: Support/mediapipe_hands.py not found."); return nil }
        guard let m = modelPath, fm.fileExists(atPath: m) else {
            print("[AirDial] MediaPipe: models/hand_landmarker.task not found (see README).")
            return nil
        }
        return (p, s, m)
    }

    init?(python: String, script: String, model: String) {
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [script, "--model", model]
        process.standardInput = toChild
        process.standardOutput = fromChild
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            print("[AirDial] MediaPipe: could not start \(python): \(error.localizedDescription)")
            return nil
        }
        // Wait for the model to load ({"ready": true}).
        guard let line = readLine(), line.contains("ready") else {
            print("[AirDial] MediaPipe: the tracker process didn't start (is mediapipe installed for \(python)?).")
            process.terminate()
            return nil
        }
    }

    deinit { if process.isRunning { process.terminate() } }

    var isRunning: Bool { process.isRunning }

    private func readLine() -> String? {
        let handle = fromChild.fileHandleForReading
        while true {
            if let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                return String(data: line, encoding: .utf8)
            }
            let chunk = handle.availableData
            if chunk.isEmpty { return nil }  // the process exited
            buffer.append(chunk)
        }
    }

    /// Sends one BGRA frame and waits for the result. Returns nil if the process died.
    func detect(_ pixelBuffer: CVPixelBuffer, time: Double) -> [Hand]? {
        guard process.isRunning, CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let w = UInt32(CVPixelBufferGetWidth(pixelBuffer))
        let h = UInt32(CVPixelBufferGetHeight(pixelBuffer))
        let bpr = UInt32(CVPixelBufferGetBytesPerRow(pixelBuffer))

        var header = Data()
        withUnsafeBytes(of: time.bitPattern.littleEndian) { header.append(contentsOf: $0) }
        for v in [w, h, bpr] { withUnsafeBytes(of: v.littleEndian) { header.append(contentsOf: $0) } }
        let pixels = Data(bytesNoCopy: base, count: Int(h * bpr), deallocator: .none)
        do {
            try toChild.fileHandleForWriting.write(contentsOf: header)
            try toChild.fileHandleForWriting.write(contentsOf: pixels)
        } catch {
            return nil
        }
        guard let line = readLine(), let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hands = obj["hands"] as? [[String: Any]] else { return nil }
        return hands.compactMap { h in
            guard let img = h["image"] as? [[Double]], img.count == 21 else { return nil }
            let world = (h["world"] as? [[Double]]) ?? []
            return Hand(score: Float((h["score"] as? Double) ?? 1),
                        image: img.map { ($0[0], $0[1]) },
                        world: world.count == 21 ? world.map { ($0[0], $0[1], $0[2]) } : [])
        }
    }
}

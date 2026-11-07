import AVFoundation
import AirDialCore
import CoreMedia
import Foundation
import Vision

/// Per-frame diagnostics (for `--log`).
struct FrameInfo {
    var visionMs: Double = 0
    var droppedBefore = 0          // frames the camera dropped since the previous delivered frame
    var handConfidence: Float = 0  // observation confidence (0 if no hand)
    var jointConf: [String: Float] = [:]
    /// All joints in AirDial coordinates (mirrored, y up, units of image height) + confidence, in `HandTracker.logJoints` order.
    var rawJoints: [(x: Double, y: Double, c: Float)] = []
}

/// Captures webcam frames and runs Apple Vision's pretrained hand-pose model on each one.
final class HandTracker: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let videoQueue = DispatchQueue(label: "airdial.video", qos: .userInteractive)
    private let request: VNDetectHumanHandPoseRequest = {
        let r = VNDetectHumanHandPoseRequest()
        r.maximumHandCount = 1
        return r
    }()

    /// Minimum per-joint confidence to trust a keypoint.
    /// Vision's per-joint confidences are low on a webcam (median ~0.4–0.6 even when the hand
    /// itself is detected with confidence 1.0); 0.3 threw away 25–40% of index-tip / wrist readings.
    var minJointConfidence: Float = 0.1

    /// Called on the video queue with the hand (nil if none), frame timestamp (s) and frame aspect (w/h).
    var onFrame: ((HandSample?, Double, Double, FrameInfo) -> Void)?
    private var droppedCount = 0

    static func availableCameras() -> [AVCaptureDevice] {
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        if #available(macOS 14.0, *) {
            types += [.external, .continuityCamera]
        } else {
            types += [.externalUnknown]
        }
        return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified).devices
    }

    func configure(cameraNameContains name: String?) throws -> AVCaptureDevice {
        let cams = HandTracker.availableCameras()
        let device: AVCaptureDevice?
        if let name = name?.lowercased(), !name.isEmpty {
            device = cams.first { $0.localizedName.lowercased().contains(name) }
        } else {
            // Prefer the built-in FaceTime camera over an iPhone (Continuity Camera).
            device = cams.first { $0.deviceType == .builtInWideAngleCamera } ?? AVCaptureDevice.default(for: .video)
        }
        guard let camera = device else {
            throw NSError(domain: "AirDial", code: 1, userInfo: [NSLocalizedDescriptionKey: "No camera found"])
        }

        session.beginConfiguration()
        // 640x480 is plenty for hand pose and keeps Vision fast (~30 fps on Apple Silicon).
        if session.canSetSessionPreset(.vga640x480) {
            session.sessionPreset = .vga640x480
        } else if session.canSetSessionPreset(.medium) {
            session.sessionPreset = .medium
        }

        let input = try AVCaptureDeviceInput(device: camera)
        guard session.canAddInput(input) else {
            throw NSError(domain: "AirDial", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot use camera \(camera.localizedName)"])
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        output.setSampleBufferDelegate(self, queue: videoQueue)
        guard session.canAddOutput(output) else {
            throw NSError(domain: "AirDial", code: 3, userInfo: [NSLocalizedDescriptionKey: "Cannot add video output"])
        }
        session.addOutput(output)
        session.commitConfiguration()
        lockFrameRate(camera, fps: 30)
        let fmt = camera.activeFormat
        let dims = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
        let rates = fmt.videoSupportedFrameRateRanges.map { String(format: "%.0f-%.0f", $0.minFrameRate, $0.maxFrameRate) }
        let minD = CMTimeGetSeconds(camera.activeVideoMinFrameDuration)
        let maxD = CMTimeGetSeconds(camera.activeVideoMaxFrameDuration)
        print("[AirDial] Format \(dims.width)x\(dims.height), supported fps \(rates.joined(separator: ",")), " +
              String(format: "active frame duration %.4f-%.4f s", minD, maxD))
        return camera
    }

    /// Joint order used by `--log` (and by the replay tool).
    static let logJoints: [(String, VNHumanHandPoseObservation.JointName)] = [
        ("wrist", .wrist),
        ("thumbCMC", .thumbCMC), ("thumbMP", .thumbMP), ("thumbIP", .thumbIP), ("thumbTip", .thumbTip),
        ("indexMCP", .indexMCP), ("indexPIP", .indexPIP), ("indexDIP", .indexDIP), ("indexTip", .indexTip),
        ("middleMCP", .middleMCP), ("middlePIP", .middlePIP), ("middleDIP", .middleDIP), ("middleTip", .middleTip),
        ("ringMCP", .ringMCP), ("ringPIP", .ringPIP), ("ringDIP", .ringDIP), ("ringTip", .ringTip),
        ("littleMCP", .littleMCP), ("littlePIP", .littlePIP), ("littleDIP", .littleDIP), ("littleTip", .littleTip),
    ]

    /// In dim light the webcam lowers its frame rate to expose longer, which smears a moving hand.
    /// Pinning the frame rate caps the exposure time (1/30 s), trading brightness for sharpness.
    private func lockFrameRate(_ camera: AVCaptureDevice, fps: Double) {
        guard camera.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.maxFrameRate >= fps - 0.01 }) else { return }
        do {
            try camera.lockForConfiguration()
            let d = CMTime(value: 1, timescale: CMTimeScale(fps))
            camera.activeVideoMinFrameDuration = d
            camera.activeVideoMaxFrameDuration = d
            camera.unlockForConfiguration()
        } catch {
            print("[AirDial] Could not lock frame rate: \(error.localizedDescription)")
        }
    }

    func start() {
        videoQueue.async { [session] in session.startRunning() }
    }

    func stop() {
        videoQueue.async { [session] in session.stopRunning() }
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let time = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        var aspect = 4.0 / 3.0
        if let pb = CMSampleBufferGetImageBuffer(sampleBuffer) {
            let w = Double(CVPixelBufferGetWidth(pb))
            let h = Double(CVPixelBufferGetHeight(pb))
            if h > 0 { aspect = w / h }
        }

        var info = FrameInfo()
        info.droppedBefore = droppedCount
        droppedCount = 0

        let handler = VNImageRequestHandler(cmSampleBuffer: sampleBuffer, orientation: .up, options: [:])
        var sample: HandSample?
        let t0 = CFAbsoluteTimeGetCurrent()
        do {
            try handler.perform([request])
            if let obs = request.results?.first {
                sample = makeSample(obs, time: time, aspect: aspect)
                info.handConfidence = obs.confidence
                if let pts = try? obs.recognizedPoints(.all) {
                    let names: [(String, VNHumanHandPoseObservation.JointName)] = [
                        ("wrist", .wrist), ("indexTip", .indexTip), ("indexPIP", .indexPIP),
                        ("middleTip", .middleTip), ("middlePIP", .middlePIP),
                        ("ringTip", .ringTip), ("littleTip", .littleTip),
                    ]
                    for (k, n) in names { info.jointConf[k] = pts[n]?.confidence ?? 0 }
                    info.rawJoints = HandTracker.logJoints.map { _, n in
                        guard let p = pts[n] else { return (0, 0, 0) }
                        return ((1.0 - Double(p.location.x)) * aspect, Double(p.location.y), p.confidence)
                    }
                }
            }
        } catch {
            // A failed frame is simply treated as "no hand".
        }
        info.visionMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        onFrame?(sample, time, aspect, info)
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        droppedCount += 1
    }

    private func makeSample(_ obs: VNHumanHandPoseObservation, time: Double, aspect: Double) -> HandSample? {
        guard let points = try? obs.recognizedPoints(.all) else { return nil }

        // Vision: normalized, origin bottom-left, NOT mirrored (camera's point of view).
        // AirDial: mirrored (like looking in a mirror), y up, units of image height.
        func pt(_ name: VNHumanHandPoseObservation.JointName) -> Vec2? {
            guard let p = points[name], p.confidence >= minJointConfidence else { return nil }
            return Vec2((1.0 - Double(p.location.x)) * aspect, Double(p.location.y))
        }

        let fingers: [Finger: HandSample.FingerJoints] = [
            .index: .init(tip: pt(.indexTip), pip: pt(.indexPIP), mcp: pt(.indexMCP)),
            .middle: .init(tip: pt(.middleTip), pip: pt(.middlePIP), mcp: pt(.middleMCP)),
            .ring: .init(tip: pt(.ringTip), pip: pt(.ringPIP), mcp: pt(.ringMCP)),
            .little: .init(tip: pt(.littleTip), pip: pt(.littlePIP), mcp: pt(.littleMCP)),
        ]
        return HandSample(time: time, wrist: pt(.wrist), fingers: fingers)
    }
}

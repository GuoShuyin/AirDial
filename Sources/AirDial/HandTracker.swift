import AVFoundation
import AirDialCore
import CoreMedia
import Foundation
import Vision

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
    var minJointConfidence: Float = 0.3

    /// Called on the video queue with the hand (nil if none), frame timestamp (s) and frame aspect (w/h).
    var onFrame: ((HandSample?, Double, Double) -> Void)?

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
        return camera
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

        let handler = VNImageRequestHandler(cmSampleBuffer: sampleBuffer, orientation: .up, options: [:])
        var sample: HandSample?
        do {
            try handler.perform([request])
            if let obs = request.results?.first {
                sample = makeSample(obs, time: time, aspect: aspect)
            }
        } catch {
            // A failed frame is simply treated as "no hand".
        }
        onFrame?(sample, time, aspect)
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

import AVFoundation
import AirDialCore
import AppKit

/// Draws the tracked fingertip trail, current pose and last action on top of the camera preview.
final class OverlayView: NSView {
    var aspect: Double = 4.0 / 3.0
    var status = GestureStatus()
    var trail: [Vec2] = []
    var lastAction: (text: String, time: Date)?

    override var isFlipped: Bool { false }

    /// Rect where the (aspect-fit) video is drawn inside this view.
    private var videoRect: NSRect {
        AVMakeRect(aspectRatio: NSSize(width: aspect, height: 1), insideRect: bounds)
    }

    private func toView(_ p: Vec2) -> NSPoint {
        let r = videoRect
        return NSPoint(x: r.minX + CGFloat(p.x / aspect) * r.width, y: r.minY + CGFloat(p.y) * r.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        // Trail
        if trail.count > 1 {
            let path = NSBezierPath()
            path.lineWidth = 4
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: toView(trail[0]))
            for p in trail.dropFirst() { path.line(to: toView(p)) }
            let color: NSColor = status.pose == .point ? .systemTeal : .systemOrange
            color.withAlphaComponent(0.8).setStroke()
            path.stroke()
        }
        // Cursor
        if let c = status.cursor {
            let v = toView(c)
            let dot = NSBezierPath(ovalIn: NSRect(x: v.x - 9, y: v.y - 9, width: 18, height: 18))
            (status.circleEngaged ? NSColor.systemGreen : NSColor.white).setFill()
            dot.fill()
        }

        // Status text
        let poseText: String
        switch status.pose {
        case .point: poseText = "☝️ 单指：转圈调音量"
        case .twoFingers: poseText = "✌️ 双指：上下/左右滑切歌"
        case .openPalm: poseText = "🖐 手掌：左右挥切换桌面"
        case .other: poseText = "未识别为手势"
        case .none: poseText = "没有检测到手"
        }
        var lines = [poseText]
        if status.pose == .point {
            lines.append(String(format: "旋转累计 %.0f°%@", status.circleDegrees, status.circleEngaged ? "  (已激活)" : ""))
        }
        drawLabel(lines.joined(separator: "\n"), at: NSPoint(x: 14, y: bounds.height - 14), size: 16, topAligned: true)

        // Big flash for the last action
        if let a = lastAction, Date().timeIntervalSince(a.time) < 0.9 {
            drawLabel(a.text, at: NSPoint(x: bounds.midX, y: bounds.midY), size: 44, centered: true)
        }
    }

    private func drawLabel(_ text: String, at p: NSPoint, size: CGFloat, topAligned: Bool = false, centered: Bool = false) {
        let shadow = NSShadow()
        shadow.shadowColor = .black
        shadow.shadowBlurRadius = 4
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: .semibold),
            .foregroundColor: NSColor.white,
            .shadow: shadow,
        ]
        let s = NSAttributedString(string: text, attributes: attrs)
        let sz = s.size()
        var origin = p
        if topAligned { origin.y -= sz.height }
        if centered { origin = NSPoint(x: p.x - sz.width / 2, y: p.y - sz.height / 2) }
        s.draw(at: origin)
    }
}

final class PreviewWindowController {
    let window: NSWindow
    let overlay: OverlayView

    init(session: AVCaptureSession) {
        let frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "AirDial"
        window.isReleasedWhenClosed = false

        let container = NSView(frame: frame)
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspect
        preview.frame = container.bounds
        preview.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        if let conn = preview.connection, conn.isVideoMirroringSupported {
            conn.automaticallyAdjustsVideoMirroring = false
            conn.isVideoMirrored = true   // mirror view so it matches the gesture coordinates
        }
        container.layer?.addSublayer(preview)

        overlay = OverlayView(frame: container.bounds)
        overlay.autoresizingMask = [.width, .height]
        container.addSubview(overlay)

        window.contentView = container
        window.center()
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

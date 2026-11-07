import CoreGraphics
import Foundation

/// Maps the fingertip position in the camera frame to a point on the displays, from a short
/// calibration where you point at targets on every display.
///
/// Each sample says: while pointing at `target` (a fraction of display `screen`, x right, y down)
/// the fingertip was at `tip` (AirDial camera coordinates: x to your right, y up).
///
/// Horizontally the samples of all displays form one piecewise-linear curve (fingertip x ->
/// global x), so pointing further right moves across displays in order. Vertically one scale
/// (pixels per unit of fingertip height) comes from the display calibrated at several heights,
/// and each display's own sample lines it up, because displays sit at different heights.
public struct PointerCalibration: Codable, Equatable {
    public struct Sample: Codable, Equatable {
        public var screen: Int
        public var targetX: Double   // fraction of the display width, 0 = left
        public var targetY: Double   // fraction of the display height, 0 = top
        public var tipX: Double
        public var tipY: Double

        public init(screen: Int, targetX: Double, targetY: Double, tip: Vec2) {
            self.screen = screen
            self.targetX = targetX
            self.targetY = targetY
            tipX = tip.x
            tipY = tip.y
        }
    }

    public var samples: [Sample]
    /// The display frames (global, top-left origin) the calibration was made for.
    public var screens: [CGRect]

    public init(samples: [Sample], screens: [CGRect]) {
        self.samples = samples
        self.screens = screens
    }

    /// The targets to show: the centre of every display, plus the top and bottom centre of the
    /// main display (index 0) for the vertical scale. Fractions of the display, x right, y down.
    public static func targets(screenCount: Int, order: [Int]) -> [(screen: Int, x: Double, y: Double)] {
        var t = order.map { (screen: $0, x: 0.5, y: 0.5) }
        if screenCount > 0 {
            t.append((screen: 0, x: 0.5, y: 0.15))
            t.append((screen: 0, x: 0.5, y: 0.85))
        }
        return t
    }

    /// Usable when it was made for the same display layout and covers every display.
    public func isValid(for current: [CGRect]) -> Bool {
        guard current.count == screens.count, zip(current, screens).allSatisfy({ $0.equalTo($1) }) else { return false }
        return Set(samples.map { $0.screen }).count == screens.count
    }

    private func globalX(_ s: Sample) -> Double { Double(screens[s.screen].minX) + s.targetX * Double(screens[s.screen].width) }

    /// Fingertip -> global point.
    public func point(for tip: Vec2) -> CGPoint? {
        guard !samples.isEmpty, !screens.isEmpty else { return nil }

        // Horizontal: piecewise linear through the samples, sorted by fingertip x. Samples that
        // would make the curve run backwards (pointing errors) are dropped.
        var xs = samples.map { (tip: $0.tipX, g: globalX($0)) }.sorted { $0.tip < $1.tip }
        var mono: [(tip: Double, g: Double)] = []
        for p in xs where mono.last.map({ p.g > $0.g && p.tip > $0.tip + 1e-4 }) ?? true { mono.append(p) }
        xs = mono
        let gx: Double
        if xs.count == 1 {
            gx = xs[0].g
        } else {
            // Find the segment (extrapolating with the end segments).
            var i = 0
            while i < xs.count - 2, tip.x > xs[i + 1].tip { i += 1 }
            let a = xs[i], b = xs[i + 1]
            gx = a.g + (tip.x - a.tip) * (b.g - a.g) / (b.tip - a.tip)
        }
        let minX = Double(screens.map { $0.minX }.min()!), maxX = Double(screens.map { $0.maxX }.max()!) - 1
        let x = min(max(gx, minX), maxX)

        // Which display is that? The one containing x, else the nearest.
        let index = screens.indices.first { x >= Double(screens[$0].minX) && x < Double(screens[$0].maxX) }
            ?? screens.indices.min { abs(Double(screens[$0].midX) - x) < abs(Double(screens[$1].midX) - x) }!
        let screen = screens[index]

        // Vertical, in pixels: one scale (pixels per unit of fingertip height) from the display(s)
        // calibrated at several heights, and each display's own samples to line it up.
        func gy(_ s: Sample) -> Double { Double(screens[s.screen].minY) + s.targetY * Double(screens[s.screen].height) }
        var num = 0.0, den = 0.0
        for i in screens.indices {
            let own = samples.filter { $0.screen == i }
            guard own.count >= 2, Set(own.map { $0.targetY }).count >= 2 else { continue }
            let mt = own.map { $0.tipY }.reduce(0, +) / Double(own.count)
            let mg = own.map(gy).reduce(0, +) / Double(own.count)
            for s in own { num += (s.tipY - mt) * (gy(s) - mg); den += (s.tipY - mt) * (s.tipY - mt) }
        }
        // Fallback: the fingertip's full height range spans the main display's height.
        let slope = den > 1e-9 ? num / den : -Double(screens[0].height) / 0.4
        var own = samples.filter { $0.screen == index }
        if own.isEmpty { own = samples }
        let mt = own.map { $0.tipY }.reduce(0, +) / Double(own.count)
        let mg = own.map(gy).reduce(0, +) / Double(own.count)
        let yRaw = mg + slope * (tip.y - mt)
        let y = min(max(yRaw, Double(screen.minY)), Double(screen.maxY) - 1)
        return CGPoint(x: x, y: y)
    }
}

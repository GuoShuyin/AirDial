import CoreGraphics
import Foundation

/// Maps the fingertip position in the camera frame to a point on the displays, from a short
/// calibration where you point at targets on every display.
///
/// Each sample says: while pointing at `target` (a fraction of display `screen`, x right, y down)
/// the fingertip was at `tip` (AirDial camera coordinates: x to your right, y up).
///
/// Horizontally the samples of all displays form one piecewise-linear curve (fingertip x ->
/// global x), so pointing further right moves across displays in order. Vertically each display
/// gets its own straight-line fit (fingertip y -> y on that display), because displays sit at
/// different heights.
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

    /// The targets to show on each display, as fractions (x right, y down).
    public static let targets: [(x: Double, y: Double)] = [(0.1, 0.1), (0.5, 0.5), (0.9, 0.9)]

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

        // Vertical: straight-line fit of that display's samples (or all samples if it has < 2).
        var own = samples.filter { $0.screen == index }
        if own.count < 2 { own = samples }
        let ys = own.map { (tip: $0.tipY, frac: $0.targetY) }
        let mt = ys.map { $0.tip }.reduce(0, +) / Double(ys.count)
        let mf = ys.map { $0.frac }.reduce(0, +) / Double(ys.count)
        let cov = ys.reduce(0) { $0 + ($1.tip - mt) * ($1.frac - mf) }
        let varT = ys.reduce(0) { $0 + ($1.tip - mt) * ($1.tip - mt) }
        let slope = varT > 1e-9 ? cov / varT : -2.0   // fallback: higher fingertip = higher on screen
        let frac = mf + slope * (tip.y - mt)
        let y = Double(screen.minY) + min(max(frac, 0), 1) * Double(screen.height - 1)
        return CGPoint(x: x, y: y)
    }
}

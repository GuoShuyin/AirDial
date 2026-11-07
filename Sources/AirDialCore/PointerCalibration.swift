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
    /// `detailed` (the display with the camera, where pointing is hardest) also gets its four
    /// corners, and then has its own full 2D mapping.
    public static func targets(screenCount: Int, order: [Int], detailed: Int? = nil) -> [(screen: Int, x: Double, y: Double)] {
        var t: [(screen: Int, x: Double, y: Double)] = []
        for s in order {
            if s == detailed {
                t += [(s, 0.5, 0.5), (s, 0.1, 0.1), (s, 0.9, 0.1), (s, 0.9, 0.9), (s, 0.1, 0.9)]
            } else {
                t.append((s, 0.5, 0.5))
            }
        }
        if screenCount > 0, detailed != 0 {
            t.append((screen: 0, x: 0.5, y: 0.15))
            t.append((screen: 0, x: 0.5, y: 0.85))
        }
        return t
    }

    /// Least-squares affine map fingertip -> global point from a display's own samples, if it has
    /// at least 4 spread out (corners): handles the perspective tilt of pointing at that display.
    private func affine(for screen: Int) -> ((Vec2) -> CGPoint)? {
        let own = samples.filter { $0.screen == screen }
        guard own.count >= 4, Set(own.map { $0.targetX }).count >= 2, Set(own.map { $0.targetY }).count >= 2 else { return nil }
        let r = screens[screen]
        // Normal equations for [gx gy] = [tx ty 1] * M.
        var ata = [[Double]](repeating: [0, 0, 0], count: 3)
        var atx = [0.0, 0, 0], aty = [0.0, 0, 0]
        for s in own {
            let row = [s.tipX, s.tipY, 1]
            let gx = Double(r.minX) + s.targetX * Double(r.width), gy = Double(r.minY) + s.targetY * Double(r.height)
            for i in 0..<3 {
                for j in 0..<3 { ata[i][j] += row[i] * row[j] }
                atx[i] += row[i] * gx
                aty[i] += row[i] * gy
            }
        }
        func solve(_ a: [[Double]], _ b: [Double]) -> [Double]? {
            var m = a.enumerated().map { $0.element + [b[$0.offset]] }
            for col in 0..<3 {
                guard let p = (col..<3).max(by: { abs(m[$0][col]) < abs(m[$1][col]) }), abs(m[p][col]) > 1e-12 else { return nil }
                m.swapAt(col, p)
                for r in 0..<3 where r != col {
                    let f = m[r][col] / m[col][col]
                    for k in col..<4 { m[r][k] -= f * m[col][k] }
                }
            }
            return (0..<3).map { m[$0][3] / m[$0][$0] }
        }
        guard let mx = solve(ata, atx), let my = solve(ata, aty) else { return nil }
        return { tip in CGPoint(x: mx[0] * tip.x + mx[1] * tip.y + mx[2], y: my[0] * tip.x + my[1] * tip.y + my[2]) }
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

        // A display with its own full (corner) calibration claims the points that map onto it.
        for i in screens.indices {
            guard let map = affine(for: i) else { continue }
            let p = map(tip), r = screens[i]
            let mx = r.width * 0.02, my = r.height * 0.02
            if p.x >= r.minX - mx, p.x < r.maxX + mx, p.y >= r.minY - my, p.y < r.maxY + my {
                return CGPoint(x: min(max(p.x, r.minX), r.maxX - 1), y: min(max(p.y, r.minY), r.maxY - 1))
            }
        }

        // Horizontal: piecewise linear through the display centres (horizontally centred
        // samples), sorted by fingertip x. Samples that would make the curve run backwards
        // (pointing errors) are dropped.
        let centred = samples.filter { $0.targetX == 0.5 }
        var xs = (centred.isEmpty ? samples : centred).map { (tip: $0.tipX, g: globalX($0)) }.sorted { $0.tip < $1.tip }
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
        if let map = affine(for: index) {
            let p = map(tip)
            return CGPoint(x: min(max(p.x, screen.minX), screen.maxX - 1), y: min(max(p.y, screen.minY), screen.maxY - 1))
        }

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

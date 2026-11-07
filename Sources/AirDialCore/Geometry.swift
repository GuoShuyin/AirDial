import Foundation

/// 2D point/vector. Coordinates used by AirDialCore are "user view" coordinates:
/// mirrored like a mirror (your right is on the right), y points up,
/// and both axes are measured in units of image height (so x ranges 0...aspect).
public struct Vec2: Equatable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = Vec2(0, 0)

    public static func + (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x + b.x, a.y + b.y) }
    public static func - (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x - b.x, a.y - b.y) }
    public static func * (a: Vec2, s: Double) -> Vec2 { Vec2(a.x * s, a.y * s) }

    public var length: Double { (x * x + y * y).squareRoot() }

    public func distance(to o: Vec2) -> Double { (self - o).length }

    public func dot(_ o: Vec2) -> Double { x * o.x + y * o.y }

    /// z component of the 2D cross product. Positive = `o` is counter-clockwise from self.
    public func cross(_ o: Vec2) -> Double { x * o.y - y * o.x }

    public static func midpoint(_ a: Vec2, _ b: Vec2) -> Vec2 { Vec2((a.x + b.x) / 2, (a.y + b.y) / 2) }
}

/// One Euro filter (Casiez et al. 2012): smooths jitter when the hand is still,
/// but adds little lag when it moves fast.
public struct OneEuroFilter {
    public var minCutoff: Double
    public var beta: Double
    public var dCutoff: Double

    private var lastValue: Double?
    private var lastDeriv: Double = 0
    private var lastTime: Double?

    public init(minCutoff: Double = 1.2, beta: Double = 0.6, dCutoff: Double = 1.0) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.dCutoff = dCutoff
    }

    private static func alpha(cutoff: Double, dt: Double) -> Double {
        let tau = 1.0 / (2 * Double.pi * cutoff)
        return 1.0 / (1.0 + tau / dt)
    }

    public mutating func reset() {
        lastValue = nil
        lastTime = nil
        lastDeriv = 0
    }

    public mutating func filter(_ value: Double, time: Double) -> Double {
        guard let prev = lastValue, let prevT = lastTime, time > prevT else {
            lastValue = value
            lastTime = time
            return value
        }
        let dt = time - prevT
        let deriv = (value - prev) / dt
        let aD = OneEuroFilter.alpha(cutoff: dCutoff, dt: dt)
        let smoothedDeriv = lastDeriv + aD * (deriv - lastDeriv)
        let cutoff = minCutoff + beta * abs(smoothedDeriv)
        let a = OneEuroFilter.alpha(cutoff: cutoff, dt: dt)
        let result = prev + a * (value - prev)
        lastValue = result
        lastDeriv = smoothedDeriv
        lastTime = time
        return result
    }
}

public struct OneEuroFilter2D {
    private var fx: OneEuroFilter
    private var fy: OneEuroFilter

    public init(minCutoff: Double = 1.2, beta: Double = 0.6) {
        fx = OneEuroFilter(minCutoff: minCutoff, beta: beta)
        fy = OneEuroFilter(minCutoff: minCutoff, beta: beta)
    }

    public mutating func reset() {
        fx.reset()
        fy.reset()
    }

    public mutating func filter(_ p: Vec2, time: Double) -> Vec2 {
        Vec2(fx.filter(p.x, time: time), fy.filter(p.y, time: time))
    }
}

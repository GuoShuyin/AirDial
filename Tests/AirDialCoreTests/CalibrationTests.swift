import CoreGraphics
import Foundation
import Testing
@testable import AirDialCore

struct CalibrationTests {
    // The user's layout (global display coordinates, y down): MacBook left, main middle, right.
    let screens = [
        CGRect(x: -1512, y: 681, width: 1512, height: 982),
        CGRect(x: 0, y: 0, width: 3440, height: 1440),
        CGRect(x: 3440, y: -605, width: 2560, height: 1440),
    ]

    /// A user whose fingertip x runs 0.4 ... 1.0 across the three displays (not proportional to
    /// their pixel widths) and whose fingertip height differs per display.
    func fakeCalibration() -> PointerCalibration {
        let tipX: [[Double]] = [[0.40, 0.45, 0.50], [0.55, 0.70, 0.85], [0.88, 0.94, 1.00]]
        let tipYTop = [0.55, 0.70, 0.80], tipYBottom = [0.35, 0.40, 0.50]
        var samples: [PointerCalibration.Sample] = []
        for s in 0..<3 {
            for (k, t) in PointerCalibration.targets.enumerated() {
                let y = tipYTop[s] + (tipYBottom[s] - tipYTop[s]) * (t.y - 0.1) / 0.8
                samples.append(.init(screen: s, targetX: t.x, targetY: t.y, tip: Vec2(tipX[s][k], y)))
            }
        }
        return PointerCalibration(samples: samples, screens: screens)
    }

    @Test func testPointingAtACalibratedSpotLandsThere() {
        let c = fakeCalibration()
        // Centre of the main display was calibrated at fingertip (0.70, 0.55).
        let p = c.point(for: Vec2(0.70, 0.55))!
        #expect(abs(p.x - 1720) < 5 && abs(p.y - 720) < 5)
        // Centre of the right display: fingertip (0.94, 0.65).
        let q = c.point(for: Vec2(0.94, 0.65))!
        #expect(screens[2].contains(q))
        #expect(abs(q.x - (3440 + 1280)) < 5 && abs(q.y - (-605 + 720)) < 5)
        // Left display centre: fingertip (0.45, 0.45).
        let r = c.point(for: Vec2(0.45, 0.45))!
        #expect(screens[0].contains(r))
    }

    @Test func testBeyondTheCalibratedRangeStaysOnTheEdgeDisplays() {
        let c = fakeCalibration()
        #expect(screens[0].contains(c.point(for: Vec2(0.2, 0.5))!))
        #expect(screens[2].contains(c.point(for: Vec2(1.3, 0.5))!))
    }

    @Test func testCalibrationIsInvalidAfterTheDisplaysChange() {
        let c = fakeCalibration()
        #expect(c.isValid(for: screens))
        #expect(!c.isValid(for: Array(screens.prefix(2))))
    }

    @Test func testCalibrationRoundTripsThroughJSON() throws {
        let c = fakeCalibration()
        let d = try JSONDecoder().decode(PointerCalibration.self, from: JSONEncoder().encode(c))
        #expect(d == c)
    }
}

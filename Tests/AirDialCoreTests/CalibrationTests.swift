import CoreGraphics
import Foundation
import Testing
@testable import AirDialCore

struct CalibrationTests {
    // The user's layout in NSScreen order (global display coordinates, y down):
    // 0 = main (middle), 1 = MacBook (left), 2 = right.
    let screens = [
        CGRect(x: 0, y: 0, width: 3440, height: 1440),
        CGRect(x: -1512, y: 681, width: 1512, height: 982),
        CGRect(x: 3440, y: -605, width: 2560, height: 1440),
    ]

    /// A user whose fingertip x is 0.45 / 0.70 / 0.94 at the three display centres and whose
    /// fingertip height runs 0.70 (top) ... 0.40 (bottom) on the main display.
    func fakeCalibration() -> PointerCalibration {
        let order = [1, 0, 2]   // left to right
        let tipXCentre = [0.70, 0.45, 0.94], tipYCentre = [0.55, 0.45, 0.65]
        var samples: [PointerCalibration.Sample] = []
        for t in PointerCalibration.targets(screenCount: 3, order: order) {
            let y = t.y == 0.5 ? tipYCentre[t.screen] : 0.55 + (0.5 - t.y) / 0.35 * 0.15
            samples.append(.init(screen: t.screen, targetX: t.x, targetY: t.y, tip: Vec2(tipXCentre[t.screen], y)))
        }
        return PointerCalibration(samples: samples, screens: screens)
    }

    @Test func testPointingAtACalibratedSpotLandsThere() {
        let c = fakeCalibration()
        // Centre of the main display was calibrated at fingertip (0.70, 0.55).
        let p = c.point(for: Vec2(0.70, 0.55))!
        #expect(abs(p.x - 1720) < 5 && abs(p.y - 720) < 5)
        // Its top centre (15% down) at fingertip y 0.70.
        let top = c.point(for: Vec2(0.70, 0.70))!
        #expect(abs(top.y - 0.15 * 1440) < 5)
        // Centre of the right display: fingertip (0.94, 0.65).
        let q = c.point(for: Vec2(0.94, 0.65))!
        #expect(screens[2].contains(q))
        #expect(abs(q.x - (3440 + 1280)) < 5 && abs(q.y - (-605 + 720)) < 5)
        // Left display centre: fingertip (0.45, 0.45).
        let r = c.point(for: Vec2(0.45, 0.45))!
        #expect(screens[1].contains(r))
    }

    @Test func testBeyondTheCalibratedRangeStaysOnTheEdgeDisplays() {
        let c = fakeCalibration()
        #expect(screens[1].contains(c.point(for: Vec2(0.2, 0.5))!))
        #expect(screens[2].contains(c.point(for: Vec2(1.3, 0.5))!))
    }

    @Test func testCalibrationIsInvalidAfterTheDisplaysChange() {
        let c = fakeCalibration()
        #expect(c.isValid(for: screens))
        #expect(!c.isValid(for: Array(screens.prefix(2))))
        #expect(PointerCalibration.targets(screenCount: 3, order: [1, 0, 2]).count == 5)
    }

    @Test func testTheCameraDisplayGetsCornersAndItsOwnMapping() {
        // MacBook (index 1) has the camera: 5 dots there, centres elsewhere, main top/bottom.
        let targets = PointerCalibration.targets(screenCount: 3, order: [1, 0, 2], detailed: 1)
        #expect(targets.filter { $0.screen == 1 }.count == 5)
        #expect(targets.count == 9)
        // A tilted fingertip grid on the MacBook (perspective): x also shifts with height.
        var samples: [PointerCalibration.Sample] = []
        for t in targets {
            let tip: Vec2
            switch t.screen {
            case 1: tip = Vec2(0.40 + 0.10 * t.x + 0.03 * t.y, 0.50 - 0.15 * t.y)
            case 0: tip = Vec2(0.70, 0.55 + (0.5 - t.y) / 0.35 * 0.15)
            default: tip = Vec2(0.94, 0.65)
            }
            samples.append(.init(screen: t.screen, targetX: t.x, targetY: t.y, tip: tip))
        }
        let c = PointerCalibration(samples: samples, screens: screens)
        // Bottom-right corner of the MacBook: target (0.9, 0.9).
        let p = c.point(for: Vec2(0.40 + 0.09 + 0.027, 0.50 - 0.135))!
        #expect(abs(p.x - (-1512 + 0.9 * 1512)) < 10)
        #expect(abs(p.y - (681 + 0.9 * 982)) < 10)
    }

    @Test func testCalibrationRoundTripsThroughJSON() throws {
        let c = fakeCalibration()
        let d = try JSONDecoder().decode(PointerCalibration.self, from: JSONEncoder().encode(c))
        #expect(d == c)
    }
}

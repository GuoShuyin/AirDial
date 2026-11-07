import CoreGraphics
import Foundation

/// Maps a normalized pointer position (u, v) in [0, 1]² (v up) onto the user's displays,
/// given in global display coordinates (origin top-left of the main display, y down).
///
/// Horizontally the displays are treated as laid side by side: u runs from the left edge of
/// the leftmost display to the right edge of the rightmost one. Vertically v runs over the
/// display(s) under that x, so pointing up reaches the top of whichever display the cursor is
/// on even when the displays are offset vertically.
public enum ScreenMapper {
    public static func point(for p: Vec2, screens: [CGRect]) -> CGPoint? {
        guard !screens.isEmpty else { return nil }
        let minX = screens.map { $0.minX }.min()!
        let maxX = screens.map { $0.maxX }.max()!
        var x = minX + CGFloat(min(max(p.x, 0), 1)) * (maxX - minX - 1)

        // Displays under this x (or the nearest one if x falls into a gap between displays).
        var column = screens.filter { x >= $0.minX && x < $0.maxX }
        if column.isEmpty, let nearest = screens.min(by: { distanceX(x, $0) < distanceX(x, $1) }) {
            column = [nearest]
            x = min(max(x, nearest.minX), nearest.maxX - 1)
        }
        let top = column.map { $0.minY }.min()!
        let bottom = column.map { $0.maxY }.max()!
        var y = top + CGFloat(1 - min(max(p.y, 0), 1)) * (bottom - top - 1)
        // Stacked displays with a vertical gap: snap into the nearest one.
        if !column.contains(where: { $0.contains(CGPoint(x: x, y: y)) }),
           let nearest = column.min(by: { distanceY(y, $0) < distanceY(y, $1) }) {
            y = min(max(y, nearest.minY), nearest.maxY - 1)
        }
        return CGPoint(x: x, y: y)
    }

    private static func distanceX(_ x: CGFloat, _ r: CGRect) -> CGFloat { x < r.minX ? r.minX - x : (x >= r.maxX ? x - r.maxX : 0) }
    private static func distanceY(_ y: CGFloat, _ r: CGRect) -> CGFloat { y < r.minY ? r.minY - y : (y >= r.maxY ? y - r.maxY : 0) }
}

import Foundation

public enum SwipeDirection: String {
    case up, down, left, right

    var opposite: SwipeDirection {
        switch self {
        case .up: return .down
        case .down: return .up
        case .left: return .right
        case .right: return .left
        }
    }
}

/// Detects a quick two-finger swipe from the midpoint of the index & middle fingertips.
public struct SwipeDetector {
    private var history: [(t: Double, p: Vec2)] = []
    private var cooldownUntil: Double = -.infinity
    private var lastSwipe: (dir: SwipeDirection, t: Double)?

    public init() {}

    /// Called when the two-finger pose is (re)entered or lost.
    /// Clearing history means a swipe must start *after* the pose is formed.
    /// The return lockout is also lifted: relaxing your fingers before bringing
    /// the hand back is the intended way to repeat a swipe quickly.
    public mutating func resetMotion() {
        history.removeAll()
        lastSwipe = nil
    }

    public mutating func add(_ p: Vec2, time t: Double, config c: GestureConfig) -> SwipeDirection? {
        history.append((t, p))
        while let first = history.first, t - first.t > c.swipeWindow {
            history.removeFirst()
        }
        guard t >= cooldownUntil, history.count >= 3 else { return nil }

        // Compare against every older sample in the window (not just the oldest),
        // so a swipe that starts after a short pause is still caught.
        var best: (dir: SwipeDirection, dist: Double)?
        for old in history.dropLast() {
            let dx = p.x - old.p.x
            let dy = p.y - old.p.y
            if c.enableVerticalSwipe, abs(dy) >= c.swipeMinDistance, abs(dy) >= c.swipeAxisRatio * abs(dx) {
                let dir: SwipeDirection = dy > 0 ? .up : .down
                if best == nil || abs(dy) > best!.dist { best = (dir, abs(dy)) }
            }
            if c.enableHorizontalSwipe, abs(dx) >= c.swipeMinDistance, abs(dx) >= c.swipeAxisRatio * abs(dy) {
                let dir: SwipeDirection = dx > 0 ? .right : .left
                if best == nil || abs(dx) > best!.dist { best = (dir, abs(dx)) }
            }
        }
        guard let hit = best else { return nil }

        if let last = lastSwipe, hit.dir == last.dir.opposite, t - last.t < c.swipeReturnLockout {
            // This is almost certainly the hand returning to its start position.
            history.removeAll()
            return nil
        }

        cooldownUntil = t + c.swipeCooldown
        lastSwipe = (hit.dir, t)
        history.removeAll()
        return hit.dir
    }
}

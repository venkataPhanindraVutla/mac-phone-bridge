import Foundation

/// At most `limit` frames in any `span`-long window (SPEC section 23: 240 in any 1 s).
public struct RateWindow: Sendable {
    public let limit: Int
    public let span: TimeInterval
    /// Times of the frames still in the window, oldest first.
    private var times: [TimeInterval] = []
    private var head = 0

    public init(limit: Int = 240, span: TimeInterval = 1) {
        self.limit = limit
        self.span = span
    }

    /// Whether a frame at `at` fits; one that fits is counted.
    public mutating func admit(at: Date) -> Bool {
        let t = at.timeIntervalSinceReferenceDate
        expire(before: t)
        guard times.count - head < limit else { return false }
        times.append(t)
        return true
    }

    /// Counts a frame that acts whatever the window holds (button-up, laser-off).
    public mutating func record(at: Date) {
        let t = at.timeIntervalSinceReferenceDate
        expire(before: t)
        times.append(t)
    }

    private mutating func expire(before t: TimeInterval) {
        while head < times.count, times[head] <= t - span { head += 1 }
        // Compact now and then, so the array stays about `limit` long.
        if head > limit {
            times.removeFirst(head)
            head = 0
        }
    }
}

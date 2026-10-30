import Foundation

/// The phases of continuous scrolls, as a trackpad gives them: the first scroll after a pause
/// begins a gesture, later ones change it, and a pause of `gap` ends it.
struct ScrollPhases {
    enum Phase: Equatable {
        case began, changed

        /// The `.scrollWheelEventScrollPhase` value (kCGScrollPhaseBegan, kCGScrollPhaseChanged).
        var cgValue: Int64 { self == .began ? 1 : 2 }
    }

    /// The `.scrollWheelEventScrollPhase` value of the zero-delta event that ends a gesture.
    static let endedValue: Int64 = 4
    /// A pause this long ends the gesture.
    static let gap: TimeInterval = 0.15

    private var lastAt: TimeInterval?

    /// The phase of a scroll at `t` (monotonic seconds).
    mutating func next(at t: TimeInterval) -> Phase {
        defer { lastAt = t }
        guard let last = lastAt, t - last < Self.gap else { return .began }
        return .changed
    }

    /// Whether a gesture is under way and has been quiet for `gap` by `t`.
    func endDue(at t: TimeInterval) -> Bool {
        guard let last = lastAt else { return false }
        return t - last >= Self.gap
    }

    mutating func end() { lastAt = nil }
}

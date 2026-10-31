import Foundation

/// The phone audio's jitter buffer rules (Global Constraints: a 60 ms target, the oldest audio
/// beyond 150 ms dropped, 40 ms before playing again after an underrun).
///
/// Asked with how much audio is queued each time that changes; it answers:
/// - `wait` before playing starts until the target is queued, and after an underrun (nothing
///   queued) until the refill amount is;
/// - `dropOldest` when more than the maximum is queued (a burst after a stall, or the phone's clock
///   running faster than the Mac's): drop that much of the oldest audio, back down to the target;
/// - `play` otherwise.
public struct JitterPolicy: Sendable {
    public enum Action: Equatable, Sendable {
        case play
        case dropOldest(ms: Double)
        case wait
    }

    public let targetMs: Double
    public let maxMs: Double
    public let refillMs: Double
    /// Not playing: waiting until this much is queued.
    private var waitingFor: Double?

    public init(targetMs: Double = 60, maxMs: Double = 150, refillMs: Double = 40) {
        self.targetMs = targetMs
        self.maxMs = maxMs
        self.refillMs = refillMs
        waitingFor = targetMs
    }

    public mutating func next(queuedMs: Double) -> Action {
        if let threshold = waitingFor {
            guard queuedMs >= threshold else { return .wait }
            waitingFor = nil
        }
        if queuedMs <= 0 {
            waitingFor = refillMs
            return .wait
        }
        if queuedMs > maxMs { return .dropOldest(ms: queuedMs - targetMs) }
        return .play
    }
}

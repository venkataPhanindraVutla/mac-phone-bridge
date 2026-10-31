import Foundation

/// How late video packets arrive, from their PTS and arrival times alone (the phone's clock is
/// never compared with the Mac's). A packet's offset is (arrival − PTS); the earliest offset in
/// the window is "on time", and a packet's lateness is how far its offset is above that.
/// A packet that arrives earlier than any in the window (a burst after a stall) reads 0.
public struct LatenessMeter: Sendable {
    private struct Sample: Sendable {
        let arrival: ContinuousClock.Instant
        let offsetMs: Double
        let latenessMs: Double
    }

    private let window: Duration
    /// The first arrival: offsets are measured from it, so they stay small numbers.
    private var base: ContinuousClock.Instant?
    /// The window's samples, oldest first.
    private var samples: [Sample] = []

    public init(window: Duration = .seconds(10)) {
        self.window = window
    }

    /// lateness = (arrival − pts) − min over the window of (arrival − pts), in ms
    public mutating func record(pts: UInt64, arrival: ContinuousClock.Instant) -> Double {
        let base = self.base ?? arrival
        self.base = base
        let offset = Self.ms(arrival - base) - Double(pts) / 1_000
        if let keep = samples.firstIndex(where: { arrival - $0.arrival <= window }) {
            samples.removeFirst(keep)
        } else {
            samples.removeAll()
        }
        let low = samples.reduce(offset) { min($0, $1.offsetMs) }
        let lateness = offset - low
        samples.append(Sample(arrival: arrival, offsetMs: offset, latenessMs: lateness))
        return lateness
    }

    /// The median lateness of the packets that arrived in the `last` before `now`; nil when none did.
    public func median(last: Duration, now: ContinuousClock.Instant) -> Double? {
        let recent = samples.filter { now - $0.arrival <= last }.map(\.latenessMs).sorted()
        guard !recent.isEmpty else { return nil }
        let mid = recent.count / 2
        return recent.count % 2 == 1 ? recent[mid] : (recent[mid - 1] + recent[mid]) / 2
    }

    /// Forgets everything: the next packet is on time (a new stream, whose PTS may start over).
    public mutating func reset() {
        base = nil
        samples = []
    }

    static func ms(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1_000 + Double(d.components.attoseconds) / 1e15
    }
}

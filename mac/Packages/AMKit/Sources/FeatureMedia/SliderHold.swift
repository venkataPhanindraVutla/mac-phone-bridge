/// A Now Playing slider's own value: shown while it is dragged, and after release until the
/// phone's next `media.state` (or a timeout), so the thumb does not jump back to the old value
/// while the seek or volume change is on its way.
public struct SliderHold: Equatable, Sendable {
    /// One release: the value to send, and the ID its timeout names.
    public struct Release: Equatable, Sendable {
        public let value: Double
        public let id: Int
    }

    /// The value to show instead of the phone's; nil: show the phone's.
    public private(set) var value: Double?
    /// The release waiting for the phone's answer; nil while dragging or idle.
    private var awaiting: Int?
    private var releases = 0

    public init() {}

    public mutating func drag(_ value: Double) {
        self.value = value
        awaiting = nil
    }

    /// Let go: the value to send, or nil when the slider was not moved.
    public mutating func release() -> Release? {
        guard let value else { return nil }
        releases += 1
        awaiting = releases
        return Release(value: value, id: releases)
    }

    /// The phone's next state: a released value gives way to it (a drag under way does not).
    public mutating func stateArrived() {
        guard awaiting != nil else { return }
        value = nil
        awaiting = nil
    }

    /// No state came for release `id` in time: show the phone's value again.
    public mutating func timedOut(_ id: Int) {
        guard awaiting == id else { return }
        value = nil
        awaiting = nil
    }
}

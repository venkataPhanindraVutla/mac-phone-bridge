import Foundation

/// How a local Focus transition relates to the last state applied from the phone (SPEC section 21).
public enum Echo: Equatable, Sendable {
    /// The applied state coming back within the window: not sent.
    case suppress
    /// The applied state coming back later, with no other transition in between: sent as `SYNC`.
    case sync
    /// The user's own change: sent as `USER`.
    case user
}

/// Remembers the last state applied from the peer, so its echo is not sent back. The same rule as
/// the phone's `EchoGuard`: each local transition is classified once, which clears what was
/// applied, so only the first matching transition can be an echo.
public struct EchoGuard {
    private let window: TimeInterval
    private var last: (on: Bool, at: Date)?

    public init(window: TimeInterval = 10) {
        self.window = window
    }

    /// The state last applied and not yet classified (internal, for tests).
    var lastApplied: Bool? { last?.on }

    /// The peer's state was applied here at `at`.
    public mutating func applied(_ on: Bool, at: Date) {
        last = (on, at)
    }

    /// A local transition to `on` at `at`.
    public mutating func classify(_ on: Bool, at: Date) -> Echo {
        defer { last = nil }
        guard let last, last.on == on else { return .user }
        return at.timeIntervalSince(last.at) < window ? .suppress : .sync
    }
}

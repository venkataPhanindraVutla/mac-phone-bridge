/// Mac-driven keep-alive (SPEC 7, `liveness.v1`): when both sides list the capability, the Mac
/// pings every interval and the phone answers, so an idle phone needs no timer of its own.
public enum Liveness {
    public static let capability = "liveness.v1"
    /// The Mac's ping interval (SPEC 7).
    public static let defaultInterval: Duration = .seconds(30)
    /// Consecutive silent intervals before the Mac drops the phone (SPEC 7).
    public static let defaultMissedLimit = 3
}

enum LivenessAction: Equatable {
    case sendPing
    case drop
}

/// The drop rule of SPEC 7. A tick is one Mac ping interval; any envelope from the phone resets
/// the silent count. The phone is dropped at the `missedLimit`-th consecutive silent tick.
struct LivenessMonitor {
    private let missedLimit: Int
    /// A new monitor counts the hello as received, so the first tick is never silent.
    private var receivedSinceTick = true
    private var missed = 0

    init(missedLimit: Int = Liveness.defaultMissedLimit) {
        precondition(missedLimit >= 1, "missedLimit must be at least 1")
        self.missedLimit = missedLimit
    }

    /// Any incoming envelope.
    mutating func received() {
        receivedSinceTick = true
    }

    mutating func tick() -> LivenessAction {
        missed = receivedSinceTick ? 0 : missed + 1
        receivedSinceTick = false
        return missed >= missedLimit ? .drop : .sendPing
    }
}

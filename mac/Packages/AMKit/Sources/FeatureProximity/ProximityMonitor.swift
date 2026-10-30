import Foundation

/// The auto-lock settings: how weak the phone's signal may get, and for how long, before the Mac locks.
public struct ProximityConfig: Equatable, Sendable {
    public static let thresholdRange: ClosedRange<Int> = -95...(-55)
    public static let delayRange: ClosedRange<TimeInterval> = 10...120
    /// Samples older than this, counted back from the newest, are dropped.
    public static let window: TimeInterval = 10
    /// The phone is absent once its newest sample is older than this.
    public static let absentAfter: TimeInterval = 20

    /// Signals below this are FAR. Clamped to `thresholdRange`.
    public var thresholdDBm: Int = -80 {
        didSet { thresholdDBm = Self.clamp(thresholdDBm) }
    }
    /// How long FAR, and the Mac idle, before it locks. Clamped to `delayRange`.
    public var delay: TimeInterval = 30 {
        didSet { delay = Self.clamp(delay) }
    }

    public init(thresholdDBm: Int = -80, delay: TimeInterval = 30) {
        self.thresholdDBm = Self.clamp(thresholdDBm)
        self.delay = Self.clamp(delay)
    }

    static func clamp(_ dBm: Int) -> Int {
        min(max(dBm, thresholdRange.lowerBound), thresholdRange.upperBound)
    }

    static func clamp(_ delay: TimeInterval) -> TimeInterval {
        guard delay.isFinite else { return 30 }
        return min(max(delay, delayRange.lowerBound), delayRange.upperBound)
    }
}

public enum Zone: Equatable, Sendable { case near, far }

/// Why the Mac won't lock right now. Any one of them makes `evaluate` say `.none`.
public enum Blocker: Hashable, Sendable {
    case featureOff, noPhone, bluetoothOff, bluetoothUnauthorized, lockUnavailable, screenLocked, asleep, phoneNotAdvertising
    /// Ruling R32: the phone has had no LAN session with this Mac now or in the last 30 minutes, so
    /// this Mac can't know whether it is still advertising.
    case noRecentSession
}

public enum Decision: Equatable, Sendable {
    case none
    /// Seconds until the lock, if the phone stays away and the Mac stays idle.
    case countdown(TimeInterval)
    case lock
}

/// Decides when to lock from the phone's beacon signal (SPEC section 22; PRD F-15). Pure: the
/// caller hands it samples, the time and the Mac's idle time.
///
/// Conservative by design, since a false lock at the desk is the failure that matters:
/// - It arms only once the phone has been NEAR since launch, `reset()` (wake, a setting or phone
///   change) or the last lock.
/// - It locks only when the phone has been FAR for the delay *and* nobody has touched the Mac for
///   the delay.
/// - Any blocker disarms it and restarts the FAR clock, so the phone must be seen NEAR again after,
///   say, Bluetooth comes back on.
public struct ProximityMonitor {
    public var config: ProximityConfig
    /// False until the first NEAR, and again after a lock, a blocker or `reset()`.
    public private(set) var armed = false
    /// When the current FAR stretch began, while armed.
    public private(set) var farSince: Date?
    /// In time order; the last is the newest, and none is more than `window` older than it.
    private var samples: [(at: Date, rssi: Int)] = []

    public init(config: ProximityConfig) {
        self.config = config
    }

    /// One sighting of the phone's beacon, which becomes the newest: samples dated after it (the
    /// clock went back) are dropped with those more than `window` older. A non-negative RSSI
    /// (CoreBluetooth's 127 = none) is ignored.
    public mutating func sample(rssi: Int, at date: Date) {
        guard rssi < 0 else { return }
        samples.removeAll { $0.at > date || date.timeIntervalSince($0.at) > ProximityConfig.window }
        samples.append((date, rssi))
    }

    /// Wake, a setting change or a phone change: forget the samples and wait for NEAR again.
    public mutating func reset() {
        samples.removeAll()
        farSince = nil
        armed = false
    }

    /// The median of the kept samples (the upper middle for an even count); nil when the newest
    /// is older than `absentAfter`.
    public func smoothedRSSI(at date: Date) -> Int? {
        guard let newest = samples.last?.at,
              date.timeIntervalSince(newest) <= ProximityConfig.absentAfter else { return nil }
        let sorted = samples.map(\.rssi).sorted()
        return sorted[sorted.count / 2]
    }

    public func zone(at date: Date) -> Zone {
        guard let rssi = smoothedRSSI(at: date), rssi >= config.thresholdDBm else { return .far }
        return .near
    }

    /// Called every second while the feature is on.
    ///
    /// `testMode` skips the idle check and never disarms, so Settings can show "Would lock now"
    /// while someone sits at the Mac. The caller must not lock in test mode.
    public mutating func evaluate(now: Date, idle: TimeInterval, blockers: Set<Blocker>, testMode: Bool) -> Decision {
        guard blockers.isEmpty else {
            armed = false
            farSince = nil
            return .none
        }
        switch zone(at: now) {
        case .near:
            armed = true
            farSince = nil
            return .none
        case .far:
            guard armed else { return .none }
            let since = farSince ?? now
            farSince = since
            let remaining = config.delay - now.timeIntervalSince(since)
            if remaining > 0 || (!testMode && idle < config.delay) {
                return .countdown(max(remaining, 0))
            }
            if !testMode {
                armed = false
                farSince = nil
            }
            return .lock
        }
    }
}

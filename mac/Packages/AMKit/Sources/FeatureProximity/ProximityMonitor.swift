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

    // Ruling R33: stricter than "FAR for the delay", for no false locks at the desk.

    /// A phone that vanishes while its signal was at least this far above the threshold didn't walk
    /// away (it would have faded first).
    public static let closeMargin = 5
    /// The Mac must be idle this long: the delay, but never under 60 s.
    public var idleRequired: TimeInterval { max(delay, 60) }
    /// Still heard but below the threshold: FAR must hold this long.
    public var weakHold: TimeInterval { max(2 * delay, 60) }
    /// Vanished from close range: the absence counts as FAR only after max(4 × delay, 120 s), and
    /// then the delay runs, so this is the whole hold from when the absence began.
    public var vanishHold: TimeInterval { max(4 * delay, 120) + delay }

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
    /// Ruling R33: the scanner has reported no advertisement from any device for 20 s, so silence
    /// from the phone means nothing.
    case scannerStalled
    /// Ruling R33: something keeps the screen awake (a video call, video playback, a presentation),
    /// so someone is likely watching without touching the Mac.
    case macInUse
}

public enum Decision: Equatable, Sendable {
    case none
    /// Seconds until the lock, if the phone stays away and the Mac stays idle.
    case countdown(TimeInterval)
    case lock
}

/// Decides when to lock from the phone's beacon signal (SPEC section 22; PRD F-15). Pure: the
/// caller hands it samples, the time and the Mac's idle time. Times are seconds on a monotonic
/// clock (a wall-clock step must not shorten a hold).
///
/// Conservative by design, since a false lock at the desk is the failure that matters:
/// - It arms only once the phone has been NEAR since launch, `reset()` (wake, a setting or phone
///   change) or the last lock.
/// - It locks only when the phone has been FAR for the hold *and* nobody has touched the Mac for
///   `idleRequired`. The hold depends on how the phone went FAR (ruling R33), and a FAR stretch
///   keeps the longest hold any part of it needed:
///   - not heard, the last signal under threshold + 5 dB: the delay;
///   - still heard but under the threshold: `weakHold`;
///   - not heard, the last signal at least threshold + 5 dB (vanished from close range): `vanishHold`.
/// - Any blocker disarms it and restarts the FAR clock, so the phone must be seen NEAR again after,
///   say, Bluetooth comes back on.
/// - Ruling R37: an absence that begins within `sessionDropWindow` of the phone's LAN session ending
///   (either order; `sessionEnded(at:)`) is unknown, not FAR: a killed app or a rebooting phone drops
///   both at once, while a walk-away drops the beacon well before Wi-Fi. It stays unknown until the
///   next sighting or `sessionStarted()`, from which an absence counts again. It keeps `armed` as it is.
public struct ProximityMonitor {
    /// Ruling R37: how close together the last sighting and the session's end make a vanish unknown.
    public static let sessionDropWindow: TimeInterval = 15

    public var config: ProximityConfig
    /// False until the first NEAR, and again after a lock, a blocker or `reset()`.
    public private(set) var armed = false
    /// When the current FAR stretch began, while armed.
    public private(set) var farSince: TimeInterval?
    /// When the last FAR stretch began; kept after a lock (for the log and tests).
    public private(set) var lastFarStart: TimeInterval?
    /// The longest hold the current FAR stretch has needed.
    public private(set) var farHold: TimeInterval = 0
    /// In time order; the last is the newest, and none is more than `window` older than it.
    private var samples: [(at: TimeInterval, rssi: Int)] = []
    /// When the phone's last LAN session ended, until the next one starts (ruling R37).
    private var sessionEndedAt: TimeInterval?

    public init(config: ProximityConfig) {
        self.config = config
    }

    /// One sighting of the phone's beacon, which becomes the newest: samples dated after it (the
    /// clock went back) are dropped with those more than `window` older. A non-negative RSSI
    /// (CoreBluetooth's 127 = none) is ignored.
    public mutating func sample(rssi: Int, at time: TimeInterval) {
        guard rssi < 0 else { return }
        samples.removeAll { $0.at > time || time - $0.at > ProximityConfig.window }
        samples.append((time, rssi))
    }

    /// Wake, a setting change or a phone change: forget the samples and the session's end, and
    /// wait for NEAR again.
    public mutating func reset() {
        samples.removeAll()
        sessionEndedAt = nil
        disarm()
    }

    /// The phone's LAN session ended (ruling R37).
    public mutating func sessionEnded(at time: TimeInterval) {
        sessionEndedAt = time
    }

    /// The phone has a LAN session again: an absence counts as FAR from here on (ruling R37).
    public mutating func sessionStarted() {
        sessionEndedAt = nil
    }

    /// Absent, and the last sighting was within `sessionDropWindow` of the session's end.
    private func absenceUnknown(at time: TimeInterval) -> Bool {
        guard let ended = sessionEndedAt, let last = samples.last?.at, smoothedRSSI(at: time) == nil else { return false }
        return abs(last - ended) <= Self.sessionDropWindow
    }

    /// The median of the kept samples (the upper middle for an even count); nil when the newest
    /// is older than `absentAfter`.
    public func smoothedRSSI(at time: TimeInterval) -> Int? {
        guard let newest = samples.last?.at, time - newest <= ProximityConfig.absentAfter else { return nil }
        return median
    }

    public func zone(at time: TimeInterval) -> Zone {
        guard let rssi = smoothedRSSI(at: time), rssi >= config.thresholdDBm else { return .far }
        return .near
    }

    /// The median of the kept samples, heard recently or not: while absent, the last smoothed value.
    private var median: Int? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.map(\.rssi).sorted()
        return sorted[sorted.count / 2]
    }

    /// How long FAR must hold right now; nil when NEAR.
    private func hold(at time: TimeInterval) -> TimeInterval? {
        if let rssi = smoothedRSSI(at: time) {
            return rssi >= config.thresholdDBm ? nil : config.weakHold
        }
        if let last = median, last >= config.thresholdDBm + ProximityConfig.closeMargin { return config.vanishHold }
        return config.delay
    }

    private mutating func disarm() {
        armed = false
        farSince = nil
        farHold = 0
    }

    /// Called every second while the feature is on.
    ///
    /// `testMode` skips the idle check and never disarms, so Settings can show "Would lock now"
    /// while someone sits at the Mac; the holds are the same. The caller must not lock in test mode.
    public mutating func evaluate(now: TimeInterval, idle: TimeInterval, blockers: Set<Blocker>, testMode: Bool) -> Decision {
        guard blockers.isEmpty else {
            disarm()
            return .none
        }
        if absenceUnknown(at: now) {
            farSince = nil
            farHold = 0
            return .none
        }
        guard let hold = hold(at: now) else {
            armed = true
            farSince = nil
            farHold = 0
            return .none
        }
        guard armed else { return .none }
        let since = farSince ?? now
        if farSince == nil { lastFarStart = now }
        farSince = since
        farHold = max(farHold, hold)
        let remaining = farHold - (now - since)
        if remaining > 0 || (!testMode && idle < config.idleRequired) {
            return .countdown(max(remaining, 0))
        }
        if !testMode { disarm() }
        return .lock
    }
}

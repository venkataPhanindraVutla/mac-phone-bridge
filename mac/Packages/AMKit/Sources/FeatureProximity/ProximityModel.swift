import AMProtocol
import ConnectionCore
import Foundation
import Observation
import os
import SwiftProtobuf

/// Locks this Mac when the chosen phone goes away (PRD F-15; SPEC section 22). It never unlocks.
///
/// It runs whether or not the phone is connected: it needs only the paired phones, this Mac's
/// discovery key, and what the phone last said about advertising. Every second while the setting
/// is on, `tick()` asks `ProximityMonitor`, which locks only when the phone has been away and the
/// Mac idle for the delay, and only after the phone has been seen near.
///
/// It won't lock (`blockers`) while the setting is off, the phone or key is missing, Bluetooth is
/// off or not allowed, locking isn't available, the screen is locked or asleep, the phone's last
/// `proximity.availability` wasn't enabled (kept per phone across sessions; nil is off), the
/// phone has had no LAN session with this Mac now or in the last 30 minutes (ruling R32: this Mac
/// can't hear that the phone stopped advertising without one), the scanner has heard nothing from
/// any device for 20 s, or something keeps the screen awake (ruling R33). A stalled scan is
/// restarted at most every 30 s.
///
/// The monitor runs on a monotonic clock (`uptime`); the wall clock (`now`) is used only for the
/// beacon epoch and the session stamps.
///
/// Bluetooth access is asked for only by `setEnabled(true)` (or at launch with the setting on).
/// The `proximity` log has one line per lock, with the smoothed RSSI, and nothing else.
@MainActor
@Observable
public final class ProximityModel: SessionFeature {
    /// Ruling R32: how long after a LAN session with the phone ends it may still lock.
    nonisolated public static let sessionGrace: TimeInterval = 30 * 60
    /// Ruling R33: no advertisement from any device for this long means the scan has stalled.
    nonisolated public static let stallAfter: TimeInterval = 20
    /// Ruling R33: a stalled scan is restarted at most this often.
    nonisolated public static let rescanEvery: TimeInterval = 30
    nonisolated static let enabledKey = "autoLockEnabled"
    nonisolated static let phoneKey = "autoLockPhoneID"
    nonisolated static let thresholdKey = "autoLockThreshold"
    nonisolated static let delayKey = "autoLockDelay"
    nonisolated static func availabilityKey(_ phoneID: String) -> String { "proximityAvailability." + phoneID }
    nonisolated static func reasonKey(_ phoneID: String) -> String { "proximityAvailabilityReason." + phoneID }
    nonisolated static func sessionKey(_ phoneID: String) -> String { "proximityLastSession." + phoneID }

    public let messagePrefixes = ["proximity."]

    /// "Lock this Mac when <phone> is away".
    public private(set) var enabled: Bool
    /// The phone that setting is for.
    public private(set) var phoneID: String?
    /// Saved, and a change starts over: the phone must be seen near again.
    public var config: ProximityConfig {
        didSet {
            guard config != oldValue else { return }
            defaults.set(config.thresholdDBm, forKey: Self.thresholdKey)
            defaults.set(config.delay, forKey: Self.delayKey)
            monitor.config = config
            monitor.reset()
        }
    }
    /// Settings' "Test mode": shows what would happen, and never locks. Switching it starts over.
    public var testMode = false {
        didSet { if testMode != oldValue { monitor.reset() } }
    }
    public private(set) var smoothedRSSI: Int?
    public private(set) var zone: Zone = .far
    public private(set) var decision: Decision = .none
    public private(set) var blockers: Set<Blocker> = []
    public private(set) var idleSeconds: TimeInterval = 0
    /// The scanner's state, for Settings (unknown is shown as nothing, though it blocks).
    public private(set) var scannerState: ScannerState
    /// Why the chosen phone last said it wasn't advertising; nil when it was, or hasn't said.
    public private(set) var phoneAvailabilityReason: AMAvailabilityReason?

    @ObservationIgnored private let scanner: any BeaconScanner
    @ObservationIgnored private let locker: any ScreenLocker
    @ObservationIgnored private let activity: any MacActivity
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let uptime: () -> TimeInterval
    @ObservationIgnored private let tickInterval: Duration?
    @ObservationIgnored private(set) var monitor: ProximityMonitor
    @ObservationIgnored private var phones: [PairedPhone] = []
    @ObservationIgnored private var discoveryKey: Data?
    @ObservationIgnored private var matcher: BeaconMatcher?
    /// The chosen phone's fingerprint and the key the matcher was made for.
    @ObservationIgnored private var matcherFingerprint: Data?
    @ObservationIgnored private var matcherKey: Data?
    /// When the scanner last reported any advertisement (monotonic), and last restarted the scan.
    @ObservationIgnored private var lastHeard: TimeInterval?
    @ObservationIgnored private var lastRescan: TimeInterval?
    /// The phone in session now, whatever it shares.
    @ObservationIgnored private var sessionPhoneID: String?
    @ObservationIgnored private var tickTask: Task<Void, Never>?

    private static let log = Logger(subsystem: "io.github.anmirror.mac", category: "proximity")

    /// `uptime` is a monotonic clock in seconds. `tickInterval` nil runs no timer (tests call `tick()`).
    public init(scanner: any BeaconScanner, locker: any ScreenLocker, activity: any MacActivity,
                defaults: UserDefaults, now: @escaping () -> Date = Date.init,
                uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                tickInterval: Duration? = .seconds(1)) {
        self.scanner = scanner
        self.locker = locker
        self.activity = activity
        self.defaults = defaults
        self.now = now
        self.uptime = uptime
        self.tickInterval = tickInterval
        let phoneID = defaults.string(forKey: Self.phoneKey)
        self.phoneID = phoneID
        enabled = defaults.bool(forKey: Self.enabledKey) && phoneID != nil
        let config = ProximityConfig(
            thresholdDBm: defaults.object(forKey: Self.thresholdKey) as? Int ?? -80,
            delay: defaults.object(forKey: Self.delayKey) as? Double ?? 30)
        self.config = config
        monitor = ProximityMonitor(config: config)
        scannerState = scanner.state
        phoneAvailabilityReason = phoneID.flatMap { Self.storedReason($0, defaults) }
        scanner.onState = { [weak self] state in self?.scannerChanged(state) }
        scanner.onBeacon = { [weak self] data, rssi in self?.beacon(data, rssi: rssi) }
        scanner.onHeartbeat = { [weak self] in self?.heard() }
        activity.onWake = { [weak self] in self?.monitor.reset() }
        if enabled {
            lastHeard = uptime()
            scanner.start()
        }
        updateTicking()
        updateBlockers()
    }

    // MARK: settings

    /// The paired phones and this Mac's discovery key, on launch and whenever pairing changes.
    public func setPhones(_ phones: [PairedPhone], discoveryKey: Data?) {
        self.phones = phones
        self.discoveryKey = discoveryKey
        updateMatcher()
    }

    /// The Settings switch. Turning it on for `phoneID` starts the scanner, which is when macOS
    /// asks for Bluetooth access, and only then. Either way it starts over: the phone must be seen
    /// near before it can lock.
    public func setEnabled(_ on: Bool, phoneID: String?) {
        if on {
            guard let phoneID else { return }
            self.phoneID = phoneID
            defaults.set(phoneID, forKey: Self.phoneKey)
            phoneAvailabilityReason = Self.storedReason(phoneID, defaults)
        }
        enabled = on
        defaults.set(on, forKey: Self.enabledKey)
        updateMatcher()
        monitor.reset()
        // A fresh start gets the stall window before it counts as stalled.
        lastHeard = on ? uptime() : nil
        lastRescan = nil
        if on { scanner.start() } else { scanner.stop() }
        updateTicking()
        updateBlockers()
    }

    // MARK: SessionFeature

    public func connected(phoneID: String, phoneName: String, shared: Set<String>) async {
        sessionPhoneID = phoneID
        markSession(phoneID)
        // A phone without the capability doesn't advertise.
        if !shared.contains("proximity.v1") { setAvailability(false, reason: .unspecified, phoneID: phoneID) }
        updateBlockers()
    }

    public func disconnected() {
        if let id = sessionPhoneID { markSession(id) }
        sessionPhoneID = nil
        updateBlockers()
    }

    public func message(_ envelope: AMEnvelope) async {
        guard let id = sessionPhoneID, envelope.type == MessageType.proximityAvailability.rawValue,
              let a = try? AMFeatureAvailability(serializedBytes: envelope.payload) else { return }
        setAvailability(a.enabled, reason: a.reason, phoneID: id)
        updateBlockers()
    }

    public func forget(phoneID: String) async {
        for key in [Self.availabilityKey(phoneID), Self.reasonKey(phoneID), Self.sessionKey(phoneID)] {
            defaults.removeObject(forKey: key)
        }
        if sessionPhoneID == phoneID { sessionPhoneID = nil }
        phones.removeAll { $0.id == phoneID }
        guard self.phoneID == phoneID else {
            updateBlockers()
            return
        }
        self.phoneID = nil
        defaults.removeObject(forKey: Self.phoneKey)
        phoneAvailabilityReason = nil
        if enabled { setEnabled(false, phoneID: nil) } else { updateMatcher(); updateBlockers() }
    }

    // MARK: ticking

    /// One evaluation; every second while the setting is on.
    public func tick() {
        let time = uptime()
        idleSeconds = activity.idleSeconds()
        updateBlockers()
        if blockers.contains(.scannerStalled), lastRescan.map({ time - $0 >= Self.rescanEvery }) ?? true {
            lastRescan = time
            scanner.rescan()
        }
        smoothedRSSI = monitor.smoothedRSSI(at: time)
        zone = monitor.zone(at: time)
        let farSince = monitor.farSince
        decision = monitor.evaluate(now: time, idle: idleSeconds, blockers: blockers, testMode: testMode)
        guard decision == .lock, !testMode else { return }
        let rssi = smoothedRSSI.map(String.init) ?? "none"
        let far = Int(farSince.map { time - $0 } ?? 0)
        let idle = Int(idleSeconds)
        let rc = locker.lock().map(String.init) ?? "none"
        Self.log.notice(
            "lock rssi=\(rssi, privacy: .public) far=\(far, privacy: .public)s idle=\(idle, privacy: .public)s rc=\(rc, privacy: .public)")
    }

    /// Whether a session that ended at `ended` (unix seconds) is recent at `now`. A stamp in the
    /// future (the wall clock stepped back) is not.
    nonisolated static func isRecent(sessionEnded ended: Double?, now: Date) -> Bool {
        guard let ended else { return false }
        let elapsed = now.timeIntervalSince1970 - ended
        return elapsed >= 0 && elapsed <= sessionGrace
    }

    /// Whether a scan last heard at `lastHeard` has stalled at `time` (both monotonic).
    nonisolated static func isStalled(lastHeard: TimeInterval?, at time: TimeInterval) -> Bool {
        guard let lastHeard else { return true }
        return time - lastHeard > stallAfter
    }

    // MARK: private

    private func beacon(_ data: Data, rssi: Int) {
        guard enabled else { return }
        heard()
        guard let matcher,
              matcher.matches(data, unixSeconds: Int64(now().timeIntervalSince1970.rounded(.down))) else { return }
        monitor.sample(rssi: rssi, at: uptime())
    }

    private func heard() {
        guard enabled else { return }
        lastHeard = uptime()
    }

    private func scannerChanged(_ state: ScannerState) {
        scannerState = state
        // Scanning (re)starts now: give it the stall window.
        if state == .poweredOn, enabled { lastHeard = uptime() }
        updateBlockers()
    }

    private func updateMatcher() {
        let phone = phones.first { $0.id == phoneID }
        let new = phone.flatMap { p in discoveryKey.map { BeaconMatcher(discoveryKey: $0, phoneFingerprint: p.fingerprint) } }
        let key = new == nil ? nil : discoveryKey
        let changed = (matcher == nil) != (new == nil) || phone?.fingerprint != matcherFingerprint || key != matcherKey
        matcher = new
        matcherFingerprint = phone?.fingerprint
        matcherKey = key
        if changed { monitor.reset() }
        updateBlockers()
    }

    /// Stores the phone's flag; for the chosen phone a change starts over, so the phone must be
    /// seen near again after its switch comes back on (ruling R32).
    private func setAvailability(_ on: Bool, reason: AMAvailabilityReason, phoneID id: String) {
        let previous = defaults.object(forKey: Self.availabilityKey(id)) as? Bool
        defaults.set(on, forKey: Self.availabilityKey(id))
        if on { defaults.removeObject(forKey: Self.reasonKey(id)) } else { defaults.set(reason.rawValue, forKey: Self.reasonKey(id)) }
        guard id == phoneID else { return }
        phoneAvailabilityReason = on ? nil : reason
        if previous != on { monitor.reset() }
    }

    private static func storedReason(_ id: String, _ defaults: UserDefaults) -> AMAvailabilityReason? {
        guard defaults.object(forKey: availabilityKey(id)) as? Bool == false else { return nil }
        return (defaults.object(forKey: reasonKey(id)) as? Int).flatMap(AMAvailabilityReason.init(rawValue:)) ?? .unspecified
    }

    private func markSession(_ id: String) {
        defaults.set(now().timeIntervalSince1970, forKey: Self.sessionKey(id))
    }

    private func recentSession(_ id: String) -> Bool {
        sessionPhoneID == id
            || Self.isRecent(sessionEnded: defaults.object(forKey: Self.sessionKey(id)) as? Double, now: now())
    }

    private func updateBlockers() {
        var b = Set<Blocker>()
        if !enabled { b.insert(.featureOff) }
        if phoneID == nil || matcher == nil { b.insert(.noPhone) }
        switch scanner.state {
        case .poweredOn:
            if enabled, Self.isStalled(lastHeard: lastHeard, at: uptime()) { b.insert(.scannerStalled) }
        case .unauthorized: b.insert(.bluetoothUnauthorized)
        case .poweredOff, .unsupported, .unknown: b.insert(.bluetoothOff)
        }
        if !locker.available { b.insert(.lockUnavailable) }
        if activity.screenLocked { b.insert(.screenLocked) }
        if activity.asleep { b.insert(.asleep) }
        if activity.screenKeptAwake { b.insert(.macInUse) }
        if let id = phoneID {
            if defaults.object(forKey: Self.availabilityKey(id)) as? Bool != true { b.insert(.phoneNotAdvertising) }
            if !recentSession(id) { b.insert(.noRecentSession) }
        }
        if b != blockers { blockers = b }
    }

    private func updateTicking() {
        guard let interval = tickInterval else { return }
        if enabled, tickTask == nil {
            tickTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: interval)
                    guard !Task.isCancelled, let self else { return }
                    self.tick()
                }
            }
        } else if !enabled, let task = tickTask {
            task.cancel()
            tickTask = nil
        }
    }
}

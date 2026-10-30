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
/// `proximity.availability` wasn't enabled (kept per phone across sessions; nil is off), or the
/// phone has had no LAN session with this Mac now or in the last 30 minutes (ruling R32: this Mac
/// can't hear that the phone stopped advertising without one).
///
/// Bluetooth access is asked for only by `setEnabled(true)` (or at launch with the setting on).
/// The `proximity` log has one line per lock, with the smoothed RSSI, and nothing else.
@MainActor
@Observable
public final class ProximityModel: SessionFeature {
    /// Ruling R32: how long after a LAN session with the phone ends it may still lock.
    nonisolated public static let sessionGrace: TimeInterval = 30 * 60
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
    @ObservationIgnored private let tickInterval: Duration?
    @ObservationIgnored private(set) var monitor: ProximityMonitor
    @ObservationIgnored private var phones: [PairedPhone] = []
    @ObservationIgnored private var discoveryKey: Data?
    @ObservationIgnored private var matcher: BeaconMatcher?
    /// The chosen phone's fingerprint the matcher was made for.
    @ObservationIgnored private var matcherFingerprint: Data?
    /// The phone in session now, whatever it shares.
    @ObservationIgnored private var sessionPhoneID: String?
    @ObservationIgnored private var tickTask: Task<Void, Never>?

    private static let log = Logger(subsystem: "io.github.anmirror.mac", category: "proximity")

    /// `tickInterval` nil runs no timer (tests call `tick()`).
    public init(scanner: any BeaconScanner, locker: any ScreenLocker, activity: any MacActivity,
                defaults: UserDefaults, now: @escaping () -> Date = Date.init,
                tickInterval: Duration? = .seconds(1)) {
        self.scanner = scanner
        self.locker = locker
        self.activity = activity
        self.defaults = defaults
        self.now = now
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
        activity.onWake = { [weak self] in self?.monitor.reset() }
        if enabled { scanner.start() }
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
        let date = now()
        idleSeconds = activity.idleSeconds()
        updateBlockers(at: date)
        smoothedRSSI = monitor.smoothedRSSI(at: date)
        zone = monitor.zone(at: date)
        let farSince = monitor.farSince
        decision = monitor.evaluate(now: date, idle: idleSeconds, blockers: blockers, testMode: testMode)
        guard decision == .lock, !testMode else { return }
        let rssi = smoothedRSSI.map(String.init) ?? "none"
        let far = Int(farSince.map { date.timeIntervalSince($0) } ?? 0)
        let idle = Int(idleSeconds)
        Self.log.notice("lock rssi=\(rssi, privacy: .public) far=\(far, privacy: .public)s idle=\(idle, privacy: .public)s")
        if !locker.lock() { Self.log.error("lock failed") }
    }

    // MARK: private

    private func beacon(_ data: Data, rssi: Int) {
        guard enabled, let matcher else { return }
        let date = now()
        guard matcher.matches(data, unixSeconds: Int64(date.timeIntervalSince1970.rounded(.down))) else { return }
        monitor.sample(rssi: rssi, at: date)
    }

    private func scannerChanged(_ state: ScannerState) {
        scannerState = state
        updateBlockers()
    }

    private func updateMatcher() {
        let phone = phones.first { $0.id == phoneID }
        let new = phone.flatMap { p in discoveryKey.map { BeaconMatcher(discoveryKey: $0, phoneFingerprint: p.fingerprint) } }
        let changed = (matcher == nil) != (new == nil) || phone?.fingerprint != matcherFingerprint
        matcher = new
        matcherFingerprint = phone?.fingerprint
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

    private func recentSession(_ id: String, at date: Date) -> Bool {
        if sessionPhoneID == id { return true }
        guard let ended = defaults.object(forKey: Self.sessionKey(id)) as? Double else { return false }
        return date.timeIntervalSince1970 - ended <= Self.sessionGrace
    }

    private func updateBlockers(at date: Date? = nil) {
        let date = date ?? now()
        var b = Set<Blocker>()
        if !enabled { b.insert(.featureOff) }
        if phoneID == nil || matcher == nil { b.insert(.noPhone) }
        switch scanner.state {
        case .poweredOn: break
        case .unauthorized: b.insert(.bluetoothUnauthorized)
        case .poweredOff, .unsupported, .unknown: b.insert(.bluetoothOff)
        }
        if !locker.available { b.insert(.lockUnavailable) }
        if activity.screenLocked { b.insert(.screenLocked) }
        if activity.asleep { b.insert(.asleep) }
        if let id = phoneID {
            if defaults.object(forKey: Self.availabilityKey(id)) as? Bool != true { b.insert(.phoneNotAdvertising) }
            if !recentSession(id, at: date) { b.insert(.noRecentSession) }
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

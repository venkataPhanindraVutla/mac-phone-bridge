import AMProtocol
import ConnectionCore
import Foundation
import SwiftProtobuf
import Testing
@testable import FeatureProximity

// MARK: fakes

@MainActor
private final class FakeScanner: BeaconScanner {
    var state: ScannerState = .poweredOn {
        didSet { onState?(state) }
    }
    var onState: ((ScannerState) -> Void)?
    var onBeacon: ((Data, Int) -> Void)?
    var onHeartbeat: (() -> Void)?
    private(set) var starts = 0
    private(set) var stops = 0
    private(set) var rescans = 0
    func start() { starts += 1 }
    func stop() { stops += 1 }
    func rescan() { rescans += 1 }
}

@MainActor
private final class FakeLocker: ScreenLocker {
    var available = true
    private(set) var locks = 0
    func lock() -> Int32? {
        locks += 1
        return 0
    }
}

@MainActor
private final class FakeActivity: MacActivity {
    var idle: TimeInterval = 1_000
    var screenLocked = false
    var asleep = false
    var screenKeptAwake = false
    var onWake: (() -> Void)?
    func idleSeconds() -> TimeInterval { idle }
}

/// The wall clock and the monotonic one, advanced together unless a test steps the wall clock.
private final class Clock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    var uptime: TimeInterval = 10_000
    func advance(_ s: TimeInterval) {
        now = now.addingTimeInterval(s)
        uptime += s
    }
}

/// NEAR at the default −80 dBm, but within 5 dB of it: losing it is plain absence (the delay).
private let near = -78

private let key = Data(repeating: 0x42, count: 32)
private let phoneA = PairedPhone(id: "phone-a", name: "Pixel", model: "P", certificateDER: Data([1, 2, 3]),
                                 pairedAt: Date(timeIntervalSince1970: 0))
private let phoneB = PairedPhone(id: "phone-b", name: "Galaxy", model: "G", certificateDER: Data([4, 5, 6]),
                                 pairedAt: Date(timeIntervalSince1970: 0))

@MainActor
private struct Rig {
    let scanner = FakeScanner()
    let locker = FakeLocker()
    let activity = FakeActivity()
    let clock = Clock()
    let defaults: UserDefaults
    let model: ProximityModel

    /// A model with phone A selected, enabled, connected, and its availability on.
    init(defaults: UserDefaults? = nil, enable: Bool = true, connect: Bool = true, available: Bool = true) async {
        let d = defaults ?? Self.freshDefaults()
        self.defaults = d
        let clock = clock
        model = ProximityModel(scanner: scanner, locker: locker, activity: activity, defaults: d,
                               now: { clock.now }, uptime: { clock.uptime }, tickInterval: nil)
        model.setPhones([phoneA, phoneB], discoveryKey: key)
        if enable { model.setEnabled(true, phoneID: phoneA.id) }
        if connect { await model.connected(phoneID: phoneA.id, phoneName: phoneA.name, shared: ["proximity.v1"]) }
        if available { await availability(true) }
    }

    static func freshDefaults() -> UserDefaults {
        let name = "ProximityModelTests." + UUID().uuidString
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func availability(_ on: Bool, reason: AMAvailabilityReason = .offByUser) async {
        var a = AMFeatureAvailability()
        a.enabled = on
        a.reason = on ? .unspecified : reason
        var e = AMEnvelope()
        e.type = MessageType.proximityAvailability.rawValue
        e.payload = try! a.serializedData()
        await model.message(e)
    }

    /// The beacon of `phone` for the current epoch at `rssi`.
    func beacon(_ phone: PairedPhone = phoneA, rssi: Int, epochOffset: Int64 = 0) {
        let epoch = PairingCrypto.epoch(unixSeconds: Int64(clock.now.timeIntervalSince1970)) + epochOffset
        let id = PairingCrypto.bleID(discoveryKey: key, phoneFingerprint: phone.fingerprint, epoch: epoch)
        scanner.onBeacon?(id, rssi)
    }

    /// `seconds` ticks, one a second, with the phone at `rssi` (nil: not heard). `heard` is whether
    /// the scanner reports any advertisement at all (other devices nearby) that second.
    func ticks(_ seconds: Int, rssi: Int?, phone: PairedPhone = phoneA, heard: Bool = true) {
        for _ in 0..<seconds {
            clock.advance(1)
            if heard { scanner.onHeartbeat?() }
            if let rssi { beacon(phone, rssi: rssi) }
            model.tick()
        }
    }

    /// Near for 5 s, then gone for long enough to lock at the default 30 s delay.
    func walkAway() {
        ticks(5, rssi: near)
        ticks(80, rssi: nil)
    }
}

// MARK: the Review Focus cases

@MainActor @Test func walkingAwayLocksOnce() async {
    let rig = await Rig()
    rig.walkAway()
    #expect(rig.locker.locks == 1)
    #expect(rig.model.decision == .none) // disarmed after the lock
}

@MainActor @Test func phoneSwitchOffNeverLocks() async {
    let rig = await Rig()
    await rig.availability(false)
    rig.walkAway()
    #expect(rig.locker.locks == 0)
    #expect(rig.model.blockers.contains(.phoneNotAdvertising))
    // Remembered after the session ends and in a new model on the same defaults.
    rig.model.disconnected()
    let again = await Rig(defaults: rig.defaults, enable: false, connect: false, available: false)
    again.walkAway()
    #expect(again.locker.locks == 0)
    #expect(again.model.blockers.contains(.phoneNotAdvertising))
}

@MainActor @Test func neverHeardAvailabilityNeverLocks() async {
    let rig = await Rig(available: false)
    rig.walkAway()
    #expect(rig.locker.locks == 0)
    #expect(rig.model.blockers.contains(.phoneNotAdvertising))
}

@MainActor @Test func phoneWithoutTheCapabilityNeverLocks() async {
    let rig = await Rig(connect: false, available: false)
    await rig.model.connected(phoneID: phoneA.id, phoneName: phoneA.name, shared: ["status.v1"])
    rig.walkAway()
    #expect(rig.locker.locks == 0)
    #expect(rig.model.blockers.contains(.phoneNotAdvertising))
}

@MainActor @Test func availabilityIsRemembered() async {
    let rig = await Rig()
    rig.model.disconnected()
    // A new launch: the phone isn't connected, but it last said it was advertising, and the session
    // ended a moment ago.
    let again = await Rig(defaults: rig.defaults, enable: false, connect: false, available: false)
    #expect(again.model.enabled)
    #expect(again.model.phoneID == phoneA.id)
    again.walkAway()
    #expect(again.locker.locks == 1)
}

@MainActor @Test func availabilityReasonIsRemembered() async {
    let rig = await Rig()
    await rig.availability(false, reason: .unavailable)
    rig.model.disconnected()
    let again = await Rig(defaults: rig.defaults, enable: false, connect: false, available: false)
    #expect(again.model.phoneAvailabilityReason == .unavailable)
}

@MainActor @Test func availabilityBackToEnabledRequiresNearAgain() async {
    let rig = await Rig()
    rig.ticks(5, rssi: near) // armed
    await rig.availability(false)
    rig.ticks(1, rssi: near)
    await rig.availability(true)
    // Away from here on: never seen near since the switch came back on.
    rig.ticks(120, rssi: nil)
    #expect(rig.locker.locks == 0)
    // Near again, then away: locks.
    rig.walkAway()
    #expect(rig.locker.locks == 1)
}

@MainActor @Test func noLockWhenNoSessionFor30Minutes() async {
    let rig = await Rig()
    rig.ticks(5, rssi: near)
    rig.model.disconnected()
    // 31 minutes at the desk with no LAN session, then away.
    for _ in 0..<(31 * 60) {
        rig.clock.advance(1)
        rig.beacon(rssi: near)
        rig.model.tick()
    }
    rig.ticks(120, rssi: nil)
    #expect(rig.locker.locks == 0)
    #expect(rig.model.blockers.contains(.noRecentSession))
    // The phone reconnects: walking away locks again.
    await rig.model.connected(phoneID: phoneA.id, phoneName: phoneA.name, shared: ["proximity.v1"])
    rig.walkAway()
    #expect(rig.locker.locks == 1)
}

@MainActor @Test func sessionThatJustEndedStillLocks() async {
    let rig = await Rig()
    rig.ticks(5, rssi: near)
    // Walking out of Wi-Fi range drops the session as the phone leaves.
    rig.model.disconnected()
    rig.ticks(80, rssi: nil)
    #expect(rig.locker.locks == 1)
}

@MainActor @Test func neverConnectedPhoneNeverLocks() async {
    let rig = await Rig(connect: false, available: false)
    // Availability is remembered from somewhere, but no session has ever been seen.
    rig.defaults.set(true, forKey: "proximityAvailability." + phoneA.id)
    rig.walkAway()
    #expect(rig.locker.locks == 0)
    #expect(rig.model.blockers.contains(.noRecentSession))
}

@MainActor @Test func otherPairedPhoneDoesNotCountAsNearInTheModel() async {
    let rig = await Rig()
    // Phone B is at the desk; phone A (selected) never shows up.
    rig.ticks(200, rssi: -50, phone: phoneB)
    #expect(rig.model.smoothedRSSI == nil)
    #expect(rig.locker.locks == 0)
    // A is near, then leaves while B stays: B's beacons don't keep the Mac unlocked.
    rig.ticks(5, rssi: near)
    rig.ticks(80, rssi: -50, phone: phoneB)
    #expect(rig.locker.locks == 1)
}

@MainActor @Test func previousEpochBeaconCountsAsNear() async {
    let rig = await Rig()
    for _ in 0..<5 {
        rig.clock.advance(1)
        rig.beacon(rssi: near, epochOffset: -1)
        rig.model.tick()
    }
    #expect(rig.model.zone == .near)
    #expect(rig.model.smoothedRSSI == near)
}

@MainActor @Test func neverLocksWhileTheMacIsInUseInTheModel() async {
    let rig = await Rig()
    rig.activity.idle = 3
    rig.walkAway()
    #expect(rig.locker.locks == 0)
    if case .countdown = rig.model.decision {} else { Issue.record("expected a countdown, got \(rig.model.decision)") }
}

@MainActor @Test func screenLockedOrAsleepNeverLocks() async {
    let locked = await Rig()
    locked.activity.screenLocked = true
    locked.walkAway()
    #expect(locked.locker.locks == 0)
    #expect(locked.model.blockers.contains(.screenLocked))

    let asleep = await Rig()
    asleep.activity.asleep = true
    asleep.walkAway()
    #expect(asleep.locker.locks == 0)
    #expect(asleep.model.blockers.contains(.asleep))
}

@MainActor @Test func bluetoothOffOrUnauthorizedNeverLocks() async {
    for state in [ScannerState.poweredOff, .unauthorized, .unsupported, .unknown] {
        let rig = await Rig()
        rig.ticks(5, rssi: near)
        rig.scanner.state = state
        rig.ticks(120, rssi: nil)
        #expect(rig.locker.locks == 0, "state \(state)")
        #expect(rig.model.blockers.contains(state == .unauthorized ? .bluetoothUnauthorized : .bluetoothOff))
    }
}

@MainActor @Test func wakeClearsSamplesInTheModel() async {
    let rig = await Rig()
    rig.ticks(5, rssi: near)
    rig.activity.onWake?()
    rig.model.tick()
    #expect(rig.model.smoothedRSSI == nil)
    rig.ticks(120, rssi: nil)
    #expect(rig.locker.locks == 0)
}

@MainActor @Test func featureOffNeverLocks() async {
    let rig = await Rig(enable: false)
    rig.walkAway()
    #expect(rig.locker.locks == 0)
    #expect(rig.model.blockers.contains(.featureOff))
}

@MainActor @Test func testModeNeverLocksTheMac() async {
    let rig = await Rig()
    rig.model.testMode = true
    rig.activity.idle = 0
    rig.walkAway()
    #expect(rig.locker.locks == 0)
    #expect(rig.model.decision == .lock) // "Would lock now"
    #expect(rig.model.zone == .far)
    #expect(rig.model.idleSeconds == 0)
}

// MARK: the rest

@MainActor @Test func bluetoothPromptOnlyWhenEnabled() async {
    let rig = await Rig(enable: false, connect: true, available: true)
    rig.ticks(10, rssi: nil)
    #expect(rig.scanner.starts == 0)
    rig.model.setEnabled(true, phoneID: phoneA.id)
    #expect(rig.scanner.starts == 1)
    rig.model.setEnabled(false, phoneID: phoneA.id)
    #expect(rig.scanner.stops == 1)
    // A launch with the setting already on starts the scanner (the switch is on).
    let d = Rig.freshDefaults()
    d.set(true, forKey: "autoLockEnabled")
    d.set(phoneA.id, forKey: "autoLockPhoneID")
    let launched = await Rig(defaults: d, enable: false, connect: false, available: false)
    #expect(launched.scanner.starts == 1)
}

@MainActor @Test func turningOnRequiresNearAgain() async {
    let rig = await Rig()
    rig.ticks(5, rssi: near)
    rig.model.setEnabled(false, phoneID: phoneA.id)
    rig.model.setEnabled(true, phoneID: phoneA.id)
    rig.ticks(120, rssi: nil)
    #expect(rig.locker.locks == 0)
}

@MainActor @Test func lockUnavailableIsReported() async {
    let rig = await Rig()
    rig.locker.available = false
    rig.walkAway()
    #expect(rig.locker.locks == 0)
    #expect(rig.model.blockers.contains(.lockUnavailable))
}

@MainActor @Test func lockCallsLockerOnce() async {
    let rig = await Rig()
    rig.walkAway()
    rig.ticks(600, rssi: nil)
    #expect(rig.locker.locks == 1)
}

@MainActor @Test func forgetClearsSettingForThatPhone() async {
    let rig = await Rig()
    await rig.model.forget(phoneID: phoneB.id)
    #expect(rig.model.enabled)
    #expect(rig.model.phoneID == phoneA.id)
    await rig.model.forget(phoneID: phoneA.id)
    #expect(!rig.model.enabled)
    #expect(rig.model.phoneID == nil)
    #expect(rig.scanner.stops == 1)
    #expect(rig.defaults.object(forKey: "autoLockPhoneID") == nil)
    #expect(rig.defaults.bool(forKey: "autoLockEnabled") == false)
    #expect(rig.defaults.object(forKey: "proximityAvailability." + phoneA.id) == nil)
    #expect(rig.defaults.object(forKey: "proximityLastSession." + phoneA.id) == nil)
    rig.walkAway()
    #expect(rig.locker.locks == 0)
}

@MainActor @Test func unpairedSelectedPhoneIsNoPhone() async {
    let rig = await Rig()
    rig.model.setPhones([phoneB], discoveryKey: key)
    rig.walkAway()
    #expect(rig.locker.locks == 0)
    #expect(rig.model.blockers.contains(.noPhone))
    let noKey = await Rig()
    noKey.model.setPhones([phoneA, phoneB], discoveryKey: nil)
    noKey.walkAway()
    #expect(noKey.locker.locks == 0)
    #expect(noKey.model.blockers.contains(.noPhone))
}

@MainActor @Test func configIsSavedAndResetsTheMonitor() async {
    let rig = await Rig()
    rig.ticks(5, rssi: near)
    rig.model.config.thresholdDBm = -70
    rig.model.config.delay = 600
    #expect(rig.model.config.delay == 120)
    #expect(rig.defaults.integer(forKey: "autoLockThreshold") == -70)
    #expect(rig.defaults.double(forKey: "autoLockDelay") == 120)
    // The change cleared the samples: away from here never locks.
    rig.ticks(300, rssi: nil)
    #expect(rig.locker.locks == 0)
    let again = await Rig(defaults: rig.defaults, enable: false, connect: false, available: false)
    #expect(again.model.config == ProximityConfig(thresholdDBm: -70, delay: 120))
}

@MainActor @Test func stateFromTheScannerShowsAtOnce() async {
    let rig = await Rig()
    rig.scanner.state = .poweredOff
    #expect(rig.model.blockers.contains(.bluetoothOff))
    #expect(rig.model.scannerState == .poweredOff)
}

@MainActor @Test func beaconsAreIgnoredWhileOff() async {
    let rig = await Rig(enable: false)
    rig.ticks(5, rssi: near)
    #expect(rig.model.smoothedRSSI == nil)
}

// MARK: ruling R33

@MainActor @Test func stalledScannerNeverLocks() async {
    let rig = await Rig()
    rig.ticks(5, rssi: near)
    // The scanner stops reporting anything at all: that is not the phone leaving.
    rig.ticks(300, rssi: nil, heard: false)
    #expect(rig.locker.locks == 0)
    #expect(rig.model.blockers.contains(.scannerStalled))
    // It asks for a fresh scan, at most once every 30 s: stalled from about 21 s, so 9 or 10 times.
    #expect((9...10).contains(rig.scanner.rescans))
}

@MainActor @Test func heartbeatClearsStalled() async {
    let rig = await Rig()
    rig.ticks(5, rssi: near)
    rig.ticks(25, rssi: nil, heard: false)
    #expect(rig.model.blockers.contains(.scannerStalled))
    // Other devices are heard again, but the phone is not: stalled clears, and the stall disarmed
    // it, so no lock follows.
    rig.ticks(1, rssi: nil)
    #expect(!rig.model.blockers.contains(.scannerStalled))
    rig.ticks(300, rssi: nil)
    #expect(rig.locker.locks == 0)
    // The phone near again, then away: locks.
    rig.walkAway()
    #expect(rig.locker.locks == 1)
}

@MainActor @Test func phoneBeaconCountsAsHeard() async {
    let rig = await Rig()
    // Only the phone is on the air: its own beacons keep the scanner from looking stalled.
    rig.ticks(60, rssi: near, heard: false)
    #expect(!rig.model.blockers.contains(.scannerStalled))
    #expect(rig.scanner.rescans == 0)
}

@MainActor @Test func notStalledRightAfterTurningOn() async {
    let rig = await Rig(enable: false)
    rig.ticks(100, rssi: nil, heard: false)
    rig.model.setEnabled(true, phoneID: phoneA.id)
    rig.model.tick()
    #expect(!rig.model.blockers.contains(.scannerStalled))
}

@MainActor @Test func powerAssertionBlocksLock() async {
    let rig = await Rig()
    // A video call keeps the screen awake while the person sits still with the phone in a bag.
    rig.activity.screenKeptAwake = true
    rig.walkAway()
    #expect(rig.locker.locks == 0)
    #expect(rig.model.blockers.contains(.macInUse))
    // Shown in test mode too.
    rig.model.testMode = true
    rig.walkAway()
    #expect(rig.model.decision == .none)
    #expect(rig.model.blockers.contains(.macInUse))
}

@MainActor @Test func idleBelowSixtySecondsNeverLocksInTheModel() async {
    let rig = await Rig()
    rig.activity.idle = 59
    rig.walkAway()
    rig.ticks(300, rssi: nil)
    #expect(rig.locker.locks == 0)
    rig.activity.idle = 60
    rig.ticks(1, rssi: nil)
    #expect(rig.locker.locks == 1)
}

@MainActor @Test func futureSessionStampIsNotRecent() async {
    let rig = await Rig()
    rig.model.disconnected()
    // The wall clock steps back an hour: the stored end is now in the future.
    rig.clock.now = rig.clock.now.addingTimeInterval(-3_600)
    rig.walkAway()
    #expect(rig.locker.locks == 0)
    #expect(rig.model.blockers.contains(.noRecentSession))
}

@MainActor @Test func wallClockStepDoesNotMoveTheHolds() async {
    let rig = await Rig()
    rig.ticks(5, rssi: near)
    // Away; ten seconds in, the wall clock jumps forward a day. The holds run on the monotonic
    // clock, so the lock still comes at the plain-absence time, not at once.
    rig.ticks(30, rssi: nil)
    rig.clock.now = rig.clock.now.addingTimeInterval(86_400)
    rig.ticks(20, rssi: nil)
    #expect(rig.locker.locks == 0)
    rig.ticks(10, rssi: nil)
    #expect(rig.locker.locks == 1)
}

@MainActor @Test func discoveryKeyChangeResets() async {
    let rig = await Rig()
    rig.ticks(5, rssi: near)
    // A new discovery key: beacons made with the old one no longer match, and the monitor starts over.
    rig.model.setPhones([phoneA, phoneB], discoveryKey: Data(repeating: 0x43, count: 32))
    #expect(!rig.model.monitor.armed)
    rig.ticks(120, rssi: nil)
    #expect(rig.locker.locks == 0)
}

// MARK: the pure time rules

@Test func sessionRecencyRules() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let t = now.timeIntervalSince1970
    #expect(ProximityModel.isRecent(sessionEnded: t, now: now))
    #expect(ProximityModel.isRecent(sessionEnded: t - 30 * 60, now: now))
    #expect(!ProximityModel.isRecent(sessionEnded: t - 30 * 60 - 1, now: now))
    #expect(!ProximityModel.isRecent(sessionEnded: t + 1, now: now)) // the clock stepped back
    #expect(!ProximityModel.isRecent(sessionEnded: nil, now: now))
}

@Test func stallRules() {
    #expect(!ProximityModel.isStalled(lastHeard: 100, at: 120))
    #expect(ProximityModel.isStalled(lastHeard: 100, at: 120.5))
    #expect(ProximityModel.isStalled(lastHeard: nil, at: 0))
}

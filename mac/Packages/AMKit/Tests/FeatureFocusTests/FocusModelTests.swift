import AMProtocol
import Foundation
import SwiftProtobuf
import Testing
@testable import FeatureFocus

/// Focus status as the test sets it.
@MainActor
private final class FakeReader: FocusReader {
    var authorization: FocusAuthorization
    /// What `requestAuthorization` grants.
    var grant: FocusAuthorization = .authorized
    var focused: Bool?
    var requests = 0
    var reads = 0

    init(_ authorization: FocusAuthorization = .authorized, focused: Bool? = false) {
        self.authorization = authorization
        self.focused = focused
    }

    func requestAuthorization() async -> FocusAuthorization {
        requests += 1
        authorization = grant
        return grant
    }

    func isFocused() -> Bool? {
        reads += 1
        return focused
    }
}

/// A runner whose `run` can be held until the test releases it.
private final class FakeRunner: ShortcutRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var _names: [String]?
    private var _result: ShortcutRunResult = .ok
    private var _hold = false
    private var _runs: [String] = []
    private var held: [CheckedContinuation<Void, Never>] = []

    init(names: [String]? = [FocusModel.onShortcut, FocusModel.offShortcut]) { _names = names }

    var names: [String]? {
        get { lock.withLock { _names } }
        set { lock.withLock { _names = newValue } }
    }
    var result: ShortcutRunResult {
        get { lock.withLock { _result } }
        set { lock.withLock { _result = newValue } }
    }
    var hold: Bool {
        get { lock.withLock { _hold } }
        set { lock.withLock { _hold = newValue } }
    }
    var runs: [String] { lock.withLock { _runs } }

    func list() async -> [String]? { names }

    func run(_ name: String) async -> ShortcutRunResult {
        let holding = lock.withLock { () -> Bool in
            _runs.append(name)
            return _hold
        }
        if holding {
            await withCheckedContinuation { c in lock.withLock { held.append(c) } }
        }
        return result
    }

    func release() {
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            defer { held = [] }
            return held
        }
        waiting.forEach { $0.resume() }
    }
}

@MainActor
private final class Sent {
    var states: [AMDndState] = []
    var availabilities: [AMDndAvailability] = []
}

/// A clock the test moves by hand.
private final class TestClock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_000_000)
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

@MainActor
private struct Rig {
    let model: FocusModel
    let reader: FakeReader
    let runner: FakeRunner
    let sent: Sent
    let clock: TestClock
}

@MainActor
private func rig(enabled: Bool = true, reader: FakeReader? = nil, runner: FakeRunner? = nil,
                 pollInterval: Duration = .seconds(3600)) -> Rig {
    let reader = reader ?? FakeReader()
    let runner = runner ?? FakeRunner()
    let sent = Sent()
    let clock = TestClock()
    let model = FocusModel(
        reader: reader, shortcuts: runner, enabled: enabled,
        send: { type, message in
            switch type {
            case .dndState: if let s = message as? AMDndState { sent.states.append(s) }
            case .dndAvailability: if let a = message as? AMDndAvailability { sent.availabilities.append(a) }
            default: Issue.record("unexpected \(type)")
            }
        },
        pollInterval: pollInterval,
        now: { clock.now })
    return Rig(model: model, reader: reader, runner: runner, sent: sent, clock: clock)
}

private let shared: Set<String> = ["status.v1", "dnd.v1"]

private func envelope<M: SwiftProtobuf.Message>(_ type: MessageType, _ message: M) -> AMEnvelope {
    var e = AMEnvelope()
    e.channel = .dnd
    e.type = type.rawValue
    e.payload = (try? message.serializedData()) ?? Data()
    return e
}

private func feature(_ enabled: Bool, _ reason: AMAvailabilityReason = .unspecified) -> AMFeatureAvailability {
    var f = AMFeatureAvailability()
    f.enabled = enabled
    f.reason = reason
    return f
}

private func phoneAvailability(sends: Bool = true, applies: Bool,
                               reason: AMAvailabilityReason = .unspecified) -> AMEnvelope {
    var a = AMDndAvailability()
    a.sends = feature(sends, sends ? .unspecified : .offByUser)
    a.applies = feature(applies, reason)
    return envelope(.dndAvailability, a)
}

private func phoneState(_ on: Bool, origin: AMDndOrigin = .user, snapshot: Bool = false) -> AMEnvelope {
    var s = AMDndState()
    s.on = on
    s.origin = origin
    s.snapshot = snapshot
    return envelope(.dndState, s)
}

/// Connects and waits for the shortcut check that connecting starts.
@MainActor
private func connect(_ r: Rig) async {
    await r.model.connected(phoneID: "phone-1", phoneName: "Pixel", shared: shared)
    await r.model.shortcutCheck?.value
}

/// Applies the phone's state and waits for the shortcut to finish.
@MainActor
private func receive(_ r: Rig, _ e: AMEnvelope) async {
    await r.model.message(e)
    await r.model.runTask?.value
}

@MainActor @Test func availabilityReflectsSettingAuthorizationAndShortcuts() async {
    func expect(_ a: AMDndAvailability?, sends: AMAvailabilityReason?, applies: AMAvailabilityReason?,
                sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(a?.sends.enabled == (sends == nil), sourceLocation: sourceLocation)
        #expect(a?.sends.reason == sends ?? .unspecified, sourceLocation: sourceLocation)
        #expect(a?.applies.enabled == (applies == nil), sourceLocation: sourceLocation)
        #expect(a?.applies.reason == applies ?? .unspecified, sourceLocation: sourceLocation)
    }

    let off = rig(enabled: false)
    await connect(off)
    expect(off.sent.availabilities.last, sends: .offByUser, applies: .offByUser)
    #expect(off.sent.states.isEmpty)

    let denied = rig(reader: FakeReader(.denied), runner: FakeRunner(names: nil))
    await connect(denied)
    expect(denied.sent.availabilities.last, sends: .needsPermission, applies: .needsSetup)

    let undetermined = rig(reader: FakeReader(.notDetermined), runner: FakeRunner(names: ["Other"]))
    await connect(undetermined)
    expect(undetermined.sent.availabilities.last, sends: .needsPermission, applies: .needsSetup)

    let unavailable = rig(reader: FakeReader(.unavailable))
    await connect(unavailable)
    expect(unavailable.sent.availabilities.last, sends: .unavailable, applies: nil)
    #expect(unavailable.model.shortcutsInstalled == true)

    let on = rig()
    await connect(on)
    expect(on.sent.availabilities.last, sends: nil, applies: nil)
    // On connect, when sending: one snapshot of the Mac's Focus.
    #expect(on.sent.states.count == 1)
    #expect(on.sent.states.first?.snapshot == true)
    #expect(on.sent.states.first?.on == false)

    // On change: turning the setting off sends both off at once.
    await on.model.setEnabled(false)
    expect(on.sent.availabilities.last, sends: .offByUser, applies: .offByUser)
    // Unchanged availability is not sent again.
    let count = on.sent.availabilities.count
    await on.model.checkShortcuts()
    #expect(on.sent.availabilities.count == count)
}

@MainActor @Test func shortcutsMissingThenInstalledSendsAvailability() async {
    let r = rig(runner: FakeRunner(names: []))
    await connect(r)
    #expect(r.model.shortcutsInstalled == false)
    #expect(r.sent.availabilities.last?.applies.reason == .needsSetup)
    r.runner.names = ["Morning", FocusModel.offShortcut, FocusModel.onShortcut]
    await r.model.checkShortcuts()
    #expect(r.model.shortcutsInstalled == true)
    #expect(r.sent.availabilities.last?.applies.enabled == true)
}

@MainActor @Test func focusChangeIsSentWhenPhoneApplies() async {
    let r = rig()
    await connect(r)
    await r.model.message(phoneAvailability(applies: true))
    r.reader.focused = true
    await r.model.poll()
    #expect(r.model.macFocused == true)
    #expect(r.sent.states.count == 2)
    #expect(r.sent.states.last?.on == true)
    #expect(r.sent.states.last?.origin == .user)
    #expect(r.sent.states.last?.snapshot == false)
    // No change, nothing sent.
    await r.model.poll()
    #expect(r.sent.states.count == 2)
    r.reader.focused = false
    await r.model.poll()
    #expect(r.sent.states.last?.on == false)
    #expect(r.sent.states.count == 3)
}

@MainActor @Test func nothingSentWhilePhoneAppliesIsNil() async {
    let r = rig()
    await connect(r)
    let snapshots = r.sent.states.count
    r.reader.focused = true
    await r.model.poll()
    #expect(r.model.macFocused == true)
    #expect(r.sent.states.count == snapshots)
    // The phone says it can't apply: still nothing.
    await r.model.message(phoneAvailability(applies: false, reason: .needsPermission))
    r.reader.focused = false
    await r.model.poll()
    #expect(r.sent.states.count == snapshots)
}

@MainActor @Test func appliedPhoneStateIsNotEchoed() async {
    let r = rig()
    await connect(r)
    await r.model.message(phoneAvailability(applies: true))
    let before = r.sent.states.count
    await receive(r, phoneState(true))
    #expect(r.runner.runs == [FocusModel.onShortcut])
    #expect(r.model.phoneOn == true)
    // The Mac's Focus turns on 3 s later: that is the echo.
    r.clock.advance(3)
    r.reader.focused = true
    await r.model.poll()
    #expect(r.sent.states.count == before)
    // The user turns it off: their own change goes to the phone.
    r.clock.advance(1)
    r.reader.focused = false
    await r.model.poll()
    #expect(r.sent.states.count == before + 1)
    #expect(r.sent.states.last?.origin == .user)
}

@MainActor @Test func focusSeenBeforeTheShortcutReturnsIsNotEchoed() async {
    let runner = FakeRunner()
    runner.hold = true
    let r = rig(runner: runner)
    await connect(r)
    await r.model.message(phoneAvailability(applies: true))
    let before = r.sent.states.count
    await r.model.message(phoneState(true))
    for _ in 0..<200 where r.runner.runs.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
    // The shortcut has turned Focus on but not returned yet.
    r.reader.focused = true
    await r.model.poll()
    #expect(r.sent.states.count == before)
    r.runner.release()
    await r.model.runTask?.value
    #expect(r.model.lastRunFailed == false)
}

@MainActor @Test func lateEchoIsSentAsSync() async {
    let r = rig()
    await connect(r)
    await r.model.message(phoneAvailability(applies: true))
    await receive(r, phoneState(true))
    r.clock.advance(11)
    r.reader.focused = true
    await r.model.poll()
    #expect(r.sent.states.last?.on == true)
    #expect(r.sent.states.last?.origin == .sync)
}

/// Ruling R28: a local transition in between clears the applied match, so the user's off then on
/// after an applied "on" goes out as USER, not SYNC.
@MainActor @Test func userOffThenOnAfterApplyIsSentAsUser() async {
    let r = rig()
    await connect(r)
    await r.model.message(phoneAvailability(applies: true))
    await receive(r, phoneState(true))
    // The echo within the window: nothing sent.
    r.clock.advance(2)
    r.reader.focused = true
    await r.model.poll()
    let before = r.sent.states.count
    // Later, the user turns Focus off and on again.
    r.clock.advance(20)
    r.reader.focused = false
    await r.model.poll()
    r.clock.advance(5)
    r.reader.focused = true
    await r.model.poll()
    #expect(r.sent.states.count == before + 2)
    #expect(r.sent.states.suffix(2).map(\.on) == [false, true])
    #expect(r.sent.states.suffix(2).map(\.origin) == [.user, .user])
}

@MainActor @Test func syncOriginIsNotApplied() async {
    let r = rig()
    await connect(r)
    await receive(r, phoneState(true, origin: .sync))
    #expect(r.runner.runs.isEmpty)
    #expect(r.model.phoneOn == true)
    await receive(r, phoneState(true, origin: .unspecified))
    #expect(r.runner.runs.isEmpty)
}

@MainActor @Test func snapshotIsNotApplied() async {
    let r = rig()
    await connect(r)
    await receive(r, phoneState(true, snapshot: true))
    #expect(r.runner.runs.isEmpty)
    #expect(r.model.phoneOn == true)
}

@MainActor @Test func alreadyFocusedIsNotReapplied() async {
    let r = rig(reader: FakeReader(focused: true))
    await connect(r)
    await receive(r, phoneState(true))
    #expect(r.runner.runs.isEmpty)
    await receive(r, phoneState(false))
    #expect(r.runner.runs == [FocusModel.offShortcut])
}

@MainActor @Test func missingShortcutsTurnsPhoneToMacOff() async {
    let r = rig(runner: FakeRunner(names: [FocusModel.onShortcut]))
    await connect(r)
    #expect(r.model.shortcutsInstalled == false)
    #expect(r.sent.availabilities.last?.applies.enabled == false)
    #expect(r.sent.availabilities.last?.applies.reason == .needsSetup)
    await receive(r, phoneState(true))
    #expect(r.runner.runs.isEmpty)
}

@MainActor @Test func disabledDoesNotApply() async {
    let r = rig(enabled: false)
    await connect(r)
    await receive(r, phoneState(true))
    #expect(r.runner.runs.isEmpty)
    #expect(r.reader.reads == 0)
}

@MainActor @Test func applyingDoesNotWaitForShortcut() async {
    let runner = FakeRunner()
    runner.hold = true
    let r = rig(runner: runner)
    await connect(r)
    // A shortcut that never returns.
    await r.model.message(phoneState(true))
    // The next message on the queue is handled anyway.
    await r.model.message(phoneAvailability(applies: true))
    #expect(r.model.phoneAvailability?.applies.enabled == true)
    for _ in 0..<200 where r.runner.runs.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
    #expect(r.runner.runs == [FocusModel.onShortcut])
    r.runner.release()
    await r.model.runTask?.value
}

@MainActor @Test func failedRunIsReported() async {
    let runner = FakeRunner()
    runner.result = .failed(1)
    let r = rig(runner: runner)
    await connect(r)
    await r.model.message(phoneAvailability(applies: true))
    await receive(r, phoneState(true))
    #expect(r.model.lastRunFailed)
    // Nothing was applied, so the Mac's next "on" is the user's own.
    r.clock.advance(2)
    r.reader.focused = true
    await r.model.poll()
    #expect(r.sent.states.last?.on == true)
    #expect(r.sent.states.last?.origin == .user)
    // A run that times out is a failure too; one that works clears it.
    runner.result = .timedOut
    await receive(r, phoneState(false))
    #expect(r.model.lastRunFailed)
    runner.result = .ok
    await receive(r, phoneState(false))
    #expect(r.model.lastRunFailed == false)
}

@MainActor @Test func authorizationIsRequestedOnlyWhenEnabled() async {
    let reader = FakeReader(.notDetermined)
    let r = rig(enabled: true, reader: reader)
    await connect(r)
    await r.model.poll()
    await r.model.checkShortcuts()
    #expect(reader.requests == 0)
    await r.model.setEnabled(false)
    #expect(reader.requests == 0)
    await r.model.setEnabled(true)
    #expect(reader.requests == 1)
    #expect(r.model.authorization == .authorized)
    #expect(r.sent.availabilities.last?.sends.enabled == true)

    // Once authorized, turning it on again asks nothing.
    await r.model.setEnabled(false)
    await r.model.setEnabled(true)
    #expect(reader.requests == 1)

    // Unavailable in this build: never asked.
    let none = rig(enabled: false, reader: FakeReader(.unavailable))
    await none.model.setEnabled(true)
    #expect(none.reader.requests == 0)
}

@MainActor @Test func disabledStopsPolling() async {
    let r = rig(pollInterval: .milliseconds(10))
    await connect(r)
    #expect(r.model.isPolling)
    for _ in 0..<400 where r.reader.reads < 4 { try? await Task.sleep(for: .milliseconds(5)) }
    #expect(r.reader.reads >= 4)
    await r.model.setEnabled(false)
    #expect(r.model.isPolling == false)
    let reads = r.reader.reads
    try? await Task.sleep(for: .milliseconds(100))
    #expect(r.reader.reads == reads)
}

@MainActor @Test func pollingNeedsConnectionDndAndAuthorization() async {
    let r = rig(pollInterval: .milliseconds(10))
    #expect(r.model.isPolling == false)
    await r.model.connected(phoneID: "phone-1", phoneName: "Pixel", shared: ["status.v1"])
    #expect(r.model.isPolling == false)
    #expect(r.sent.availabilities.isEmpty)
    await connect(r)
    #expect(r.model.isPolling)
    r.model.disconnected()
    #expect(r.model.isPolling == false)

    let denied = rig(reader: FakeReader(.denied), pollInterval: .milliseconds(10))
    await connect(denied)
    #expect(denied.model.isPolling == false)
    #expect(denied.reader.reads == 0)
}

@MainActor @Test func revokedAuthorizationStopsPollingAndIsReported() async {
    let r = rig()
    await connect(r)
    #expect(r.model.isPolling)
    r.reader.authorization = .denied
    await r.model.poll()
    #expect(r.model.isPolling == false)
    #expect(r.sent.availabilities.last?.sends.reason == .needsPermission)
}

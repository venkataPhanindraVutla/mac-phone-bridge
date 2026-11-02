import AMProtocol
import AMTestSupport
import AppKit
import ConnectionCore
import FeatureClipboard
import Foundation
import SwiftProtobuf
import Testing
@testable import FeatureMirror

/// The control link's bytes as messages, without the RESET_VIDEOs the decoder may ask for.
func controlMessages(_ data: Data) -> [Data] {
    var out: [Data] = []
    var i = data.startIndex
    func u32(_ at: Int) -> Int { data[at..<(at + 4)].reduce(0) { $0 << 8 | Int($1) } }
    while i < data.endIndex {
        let length: Int
        switch data[i] {
        case 0: length = 14
        case 1: length = 5 + u32(i + 1)
        case 2: length = 32
        case 3: length = 21
        case 4, 8, 10: length = 2
        case 9: length = 14 + u32(i + 10)
        default: length = 1
        }
        let end = min(i + length, data.endIndex)
        if !(length == 1 && data[i] == 17) { out.append(Data(data[i..<end])) }
        i = end
    }
    return out
}

let screenOffBytes = ScrcpyControl.setDisplayPower(on: false)
let screenOnBytes = ScrcpyControl.setDisplayPower(on: true)

/// A pasteboard the acceptance test reads and writes by hand.
@MainActor
final class TestPasteboard: PasteboardAccess {
    var changeCount = 0
    var types: [String] = []
    var string: String?
    var writes: [String] = []

    func readString() -> String? { string }

    func writeString(_ s: String) {
        writes.append(s)
        string = s
        types = ["public.utf8-plain-text"]
        changeCount += 1
    }

    func copy(_ text: String) {
        string = text
        types = ["public.utf8-plain-text"]
        changeCount += 1
    }
}

/// A model whose `send` records the order of what goes out, with a running session on the sample.
@MainActor
private final class ExtrasRig {
    let bulk = FakeBulk()
    let sent = SentLog()
    let model: MirrorModel
    /// What each `send` saw: its type, and how many bytes the current control link had written then.
    var log: [(type: MessageType, controlBytes: UInt64)] = []
    var control: (mac: MemoryPipe, phone: MemoryPipe)?

    /// With `clock`, the sessions' deadlines (the control flush and drain) run on it.
    init(clock: FakeResetClock? = nil, startDeadline: Duration = .seconds(20)) {
        let sent = sent
        var record: ((MessageType) -> Void)?
        model = MirrorModel(bulk: bulk, send: { type, message in
            sent.all.append((type, message))
            record?(type)
        }, makeSink: { CountingSink() }, startDeadline: startDeadline)
        model.linkGrace = .milliseconds(100)
        model.qualityInterval = .seconds(3600)
        if let clock { model.sessionClock = clock.clock }
        // Weak: the model can outlive the rig (a session's deadline task holds it), and a send after
        // the test has ended must not touch a freed rig.
        record = { [weak self] type in
            guard let self else { return }
            log.append((type, control?.mac.bytesSent ?? 0))
        }
    }

    func ready(shared: Set<String> = ["mirror.v1"]) async {
        await model.connected(phoneID: phoneHex, phoneName: "Pixel", shared: shared)
        var a = AMFeatureAvailability()
        a.enabled = true
        await model.message(envelope(.mirror, .mirrorAvailability, a))
    }

    /// Started, with video and control links, RUNNING from the phone and the first frames decoded.
    @discardableResult
    func running(shared: Set<String> = ["mirror.v1"], ready: Bool = true) async throws -> (video: MemoryPipe, control: MemoryPipe) {
        if ready { await self.ready(shared: shared) }
        await model.start()
        let id = model.sessionID
        let (videoMac, videoPhone) = MemoryPipe.pair()
        model.link(videoMac, grant: BulkGrant(role: .mirrorVideo, context: "mirror-\(id)"))
        let (controlMac, controlPhone) = MemoryPipe.pair()
        model.link(controlMac, grant: BulkGrant(role: .mirrorControl, context: "mirror-\(id)"))
        control = (controlMac, controlPhone)
        var s = AMMirrorState()
        s.session = id
        s.phase = .running
        await model.message(envelope(.mirror, .mirrorState, s))
        try await videoPhone.send(sampleWithDummyByte)
        try await until("running") { [model] in model.phase == .running(width: 320, height: 640) }
        return (videoPhone, controlPhone)
    }

    /// Running like `running()`, but with a control link that never takes a byte (a stalled phone).
    func runningStalled() async throws -> (video: MemoryPipe, control: StalledPipe) {
        await ready()
        await model.start()
        let id = model.sessionID
        let (videoMac, videoPhone) = MemoryPipe.pair()
        model.link(videoMac, grant: BulkGrant(role: .mirrorVideo, context: "mirror-\(id)"))
        let stalled = StalledPipe()
        model.link(stalled, grant: BulkGrant(role: .mirrorControl, context: "mirror-\(id)"))
        var s = AMMirrorState()
        s.session = id
        s.phase = .running
        await model.message(envelope(.mirror, .mirrorState, s))
        try await videoPhone.send(sampleWithDummyByte)
        try await until("running") { [model] in model.phase == .running(width: 320, height: 640) }
        return (videoPhone, stalled)
    }

    var starts: Int { sent.of(.mirrorStart, AMMirrorStart.self).count }
    var stops: Int { sent.of(.mirrorStop, AMMirrorStop.self).count }

    /// The control messages the phone end has, until the Mac closes the link.
    func controlUntilClosed(_ phone: MemoryPipe) async throws -> [Data] {
        controlMessages(try await readAll(phone, 1 << 20))
    }

    /// The next `count` control messages (past RESET_VIDEOs).
    func nextControl(_ phone: MemoryPipe, _ count: Int) async throws -> [Data] {
        var bytes = Data()
        while controlMessages(bytes).count < count {
            let more = try await readAll(phone, 1)
            guard !more.isEmpty else { break }
            bytes += more
        }
        return controlMessages(bytes)
    }
}

@MainActor
@Suite struct MirrorExtrasTests {
    // MARK: screen off

    @Test func screenOffSettingAppliedAfterFirstFrame() async throws {
        let rig = ExtrasRig()
        rig.model.screenOffByDefault = true
        await rig.ready()
        await rig.model.start()
        let id = rig.model.sessionID
        let (videoMac, videoPhone) = MemoryPipe.pair()
        rig.model.link(videoMac, grant: BulkGrant(role: .mirrorVideo, context: "mirror-\(id)"))
        let (controlMac, controlPhone) = MemoryPipe.pair()
        rig.model.link(controlMac, grant: BulkGrant(role: .mirrorControl, context: "mirror-\(id)"))
        // Nothing before the first frame: everything queued so far has been written, and it is nothing.
        await rig.model.session?.flushControl()
        #expect(controlMac.bytesSent == 0)
        #expect(!rig.model.screenOff)
        try await videoPhone.send(sampleWithDummyByte)
        try await until("screen off") { rig.model.screenOff }
        #expect(try await rig.nextControl(controlPhone, 1) == [screenOffBytes])

        // Every session: the next one turns it off again (the old one's screen first back on).
        let second = try await rig.running(ready: false)
        #expect(rig.model.screenOff)
        #expect(try await rig.nextControl(second.control, 1) == [screenOffBytes])
    }

    /// The control link may come after the first frame: the screen goes off once it is there.
    @Test func screenOffSettingWaitsForTheControlLink() async throws {
        let rig = ExtrasRig()
        rig.model.screenOffByDefault = true
        await rig.ready()
        await rig.model.start()
        let id = rig.model.sessionID
        let (videoMac, videoPhone) = MemoryPipe.pair()
        rig.model.link(videoMac, grant: BulkGrant(role: .mirrorVideo, context: "mirror-\(id)"))
        try await videoPhone.send(sampleWithDummyByte)
        try await until("first frame") { rig.model.firstFrameSeen }
        #expect(!rig.model.screenOff)
        let (controlMac, controlPhone) = MemoryPipe.pair()
        rig.model.link(controlMac, grant: BulkGrant(role: .mirrorControl, context: "mirror-\(id)"))
        #expect(rig.model.screenOff)
        #expect(try await rig.nextControl(controlPhone, 1) == [screenOffBytes])
    }

    @Test func screenStaysOnWithoutTheSetting() async throws {
        let rig = ExtrasRig()
        let links = try await rig.running()
        // Decided with the first frame, before the session ran.
        #expect(!rig.model.screenOff)
        await rig.model.stop()
        // Nothing but what the decoder asked for.
        #expect(try await rig.controlUntilClosed(links.control).isEmpty)
    }

    @Test func toggleSendsDisplayPower() async throws {
        let rig = ExtrasRig()
        let links = try await rig.running()
        rig.model.setScreenOff(true)
        #expect(rig.model.screenOff)
        rig.model.setScreenOff(true) // already off: nothing more
        rig.model.setScreenOff(false)
        #expect(!rig.model.screenOff)
        #expect(try await rig.nextControl(links.control, 2) == [screenOffBytes, screenOnBytes])
        // The toggle is the window's: it doesn't change the setting.
        #expect(!rig.model.screenOffByDefault)
    }

    @Test func toggleWithoutSessionDoesNothing() async throws {
        let rig = ExtrasRig()
        await rig.ready()
        rig.model.setScreenOff(true)
        #expect(!rig.model.screenOff)
    }

    /// The user's stop with the screen off: SET_DISPLAY_POWER(on) is written first, then
    /// `mirror.stop` goes; a held touch's UP follows on the link, which then closes (R45).
    @Test func stopTurnsScreenBackOnFirst() async throws {
        let rig = ExtrasRig()
        let links = try await rig.running()
        let view = MirrorView(frame: NSRect(x: 0, y: 0, width: 160, height: 320))
        view.bind(rig.model, closeWindow: {})
        rig.model.setScreenOff(true)
        view.input?.mouseDown(at: CGPoint(x: 80, y: 160), viewSize: view.bounds.size)
        let down = touchDown(160, 320, 320, 640), up = touchUp(160, 320, 320, 640)
        #expect(try await rig.nextControl(links.control, 2) == [screenOffBytes, down])

        await rig.model.stop()
        #expect(!rig.model.screenOff)
        // Display power on, then the release's UP, then the Mac closes the link.
        #expect(try await rig.controlUntilClosed(links.control) == [screenOnBytes, up])
        // mirror.stop went once SET_DISPLAY_POWER(on) had been written.
        let stop = try #require(rig.log.first { $0.type == .mirrorStop })
        #expect(stop.controlBytes >= UInt64(screenOffBytes.count + down.count + screenOnBytes.count))
        #expect(rig.model.phase == .ended(.user))
    }

    /// Closing the window is `stop()`; a quality change and "Show Again" are a new `start()`: the old
    /// session's screen comes back on before the new start goes.
    @Test func restartTurnsScreenBackOnFirst() async throws {
        let rig = ExtrasRig()
        let links = try await rig.running()
        rig.model.setScreenOff(true)
        #expect(try await rig.nextControl(links.control, 1) == [screenOffBytes])
        let before = rig.control?.mac.bytesSent ?? 0
        rig.model.preset = .low
        await rig.model.start()
        #expect(rig.model.sessionID == 2)
        #expect(!rig.model.screenOff)
        #expect(try await rig.controlUntilClosed(links.control) == [screenOnBytes])
        let start = try #require(rig.log.last { $0.type == .mirrorStart })
        #expect(start.controlBytes >= before + UInt64(screenOnBytes.count))
        // The phone ends the old session itself (REPLACED).
        #expect(rig.sent.of(.mirrorStop, AMMirrorStop.self).isEmpty)
    }

    /// A quality restart keeps the screen-off state: the old session's screen comes back on before
    /// the new start, and the new session turns it off again after its first frame.
    @Test func qualityRestartKeepsTheScreenOff() async throws {
        let rig = ExtrasRig()
        let links = try await rig.running()
        rig.model.setScreenOff(true)
        #expect(try await rig.nextControl(links.control, 1) == [screenOffBytes])
        await rig.model.choosePreset(.balanced)
        #expect(rig.model.sessionID == 2)
        #expect(try await rig.controlUntilClosed(links.control) == [screenOnBytes])
        let (videoMac, videoPhone) = MemoryPipe.pair()
        rig.model.link(videoMac, grant: BulkGrant(role: .mirrorVideo, context: "mirror-2"))
        let (controlMac, controlPhone) = MemoryPipe.pair()
        rig.model.link(controlMac, grant: BulkGrant(role: .mirrorControl, context: "mirror-2"))
        var s = AMMirrorState()
        s.session = 2
        s.phase = .running
        await rig.model.message(envelope(.mirror, .mirrorState, s))
        try await videoPhone.send(sampleWithDummyByte)
        try await until("running") { rig.model.phase == .running(width: 320, height: 640) }
        #expect(try await rig.nextControl(controlPhone, 1) == [screenOffBytes])
        #expect(rig.model.screenOff)
    }

    /// A screen the user turned back on stays on after a quality restart, even with the setting on.
    @Test func qualityRestartKeepsTheScreenOn() async throws {
        let rig = ExtrasRig()
        rig.model.screenOffByDefault = true
        let links = try await rig.running()
        #expect(try await rig.nextControl(links.control, 1) == [screenOffBytes])
        rig.model.setScreenOff(false)
        #expect(try await rig.nextControl(links.control, 1) == [screenOnBytes])
        await rig.model.choosePreset(.low)
        let (videoMac, videoPhone) = MemoryPipe.pair()
        rig.model.link(videoMac, grant: BulkGrant(role: .mirrorVideo, context: "mirror-2"))
        let (controlMac, controlPhone) = MemoryPipe.pair()
        rig.model.link(controlMac, grant: BulkGrant(role: .mirrorControl, context: "mirror-2"))
        var s = AMMirrorState()
        s.session = 2
        s.phase = .running
        await rig.model.message(envelope(.mirror, .mirrorState, s))
        try await videoPhone.send(sampleWithDummyByte)
        try await until("running") { rig.model.phase == .running(width: 320, height: 640) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(!rig.model.screenOff)
        controlMac.close()
        #expect(try await rig.controlUntilClosed(controlPhone).isEmpty)
    }

    /// Going to sleep can't wait: SET_DISPLAY_POWER(on) is queued before the release, and both go
    /// out before the control link closes.
    @Test func sleepTurnsScreenBackOnFirst() async throws {
        let rig = ExtrasRig()
        let links = try await rig.running()
        let view = MirrorView(frame: NSRect(x: 0, y: 0, width: 160, height: 320))
        view.bind(rig.model, closeWindow: {})
        rig.model.setScreenOff(true)
        view.input?.mouseDown(at: CGPoint(x: 80, y: 160), viewSize: view.bounds.size)
        #expect(try await rig.nextControl(links.control, 2) == [screenOffBytes, touchDown(160, 320, 320, 640)])
        rig.model.macWillSleepNow()
        #expect(!rig.model.screenOff)
        #expect(try await rig.controlUntilClosed(links.control) == [screenOnBytes, touchUp(160, 320, 320, 640)])
    }

    /// An end from the phone (or a lost connection) needs nothing: the helper's cleanup restores it.
    @Test func phoneEndSendsNoScreenOn() async throws {
        let rig = ExtrasRig()
        let links = try await rig.running()
        rig.model.setScreenOff(true)
        #expect(try await rig.nextControl(links.control, 1) == [screenOffBytes])
        var s = AMMirrorState()
        s.session = 1
        s.phase = .stopped
        s.reason = .turnedOff
        await rig.model.message(envelope(.mirror, .mirrorState, s))
        #expect(!rig.model.screenOff)
        #expect(try await rig.controlUntilClosed(links.control).isEmpty)
    }

    // MARK: fix round 1: ends that race, close order, dead links

    /// I1: a restart waits for the old screen to come back on; a stop that comes meanwhile wins,
    /// whichever resumes first, and no session starts.
    @Test func stopDuringRestartFlushStartsNothing() async throws {
        let fake = FakeResetClock()
        let rig = ExtrasRig(clock: fake)
        _ = try await rig.runningStalled()
        rig.model.setScreenOff(true)
        let session = try #require(rig.model.session)
        let restart = Task { await rig.model.start() }
        // The restart has queued the screen-on and waits for it (the link takes nothing).
        try await until("restart waiting") { session.flushesWaitingOrDone == 1 }
        let generation = rig.model.stopGeneration
        let stop = Task { await rig.model.stop() }
        // The stop has begun and waits for the same screen-on, with the session still current.
        try await until("stop begun") { rig.model.stopGeneration == generation + 1 && session.flushesWaitingOrDone == 2 }
        #expect(rig.model.session === session)
        #expect(rig.starts == 1)
        fake.advance(by: .milliseconds(200))
        await restart.value
        await stop.value
        #expect(rig.starts == 1, "no new session")
        #expect(rig.stops == 1)
        #expect(rig.model.phase == .ended(.user))
        #expect(rig.model.session == nil)
        #expect(rig.model.sessionID == 1)
    }

    /// I1: the same for the Mac going to sleep while a restart waits.
    @Test func sleepDuringRestartFlushStartsNothing() async throws {
        let fake = FakeResetClock()
        let rig = ExtrasRig(clock: fake)
        _ = try await rig.runningStalled()
        rig.model.setScreenOff(true)
        let session = try #require(rig.model.session)
        let restart = Task { await rig.model.start() }
        try await until("restart waiting") { session.flushesWaitingOrDone == 1 }
        rig.model.macWillSleepNow()
        #expect(rig.model.phase == .ended(.macSleep))
        fake.advance(by: .milliseconds(200))
        await restart.value
        #expect(rig.starts == 1, "no session across sleep")
        #expect(rig.model.phase == .ended(.macSleep))
        #expect(rig.model.session == nil)
        try await until("stop sent") { rig.stops == 1 }
    }

    /// M1: closing the window, the view releases held input on `willClose` and the window's stop
    /// follows: the screen still comes back on before the release's UP.
    @Test func windowCloseTurnsScreenOnBeforeTheRelease() async throws {
        let rig = ExtrasRig()
        let links = try await rig.running()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 160, height: 320), styleMask: [.titled, .closable],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let view = MirrorView(frame: NSRect(x: 0, y: 0, width: 160, height: 320))
        window.contentView = view
        view.bind(rig.model, closeWindow: {})
        rig.model.setScreenOff(true)
        view.input?.mouseDown(at: CGPoint(x: 80, y: 160), viewSize: view.bounds.size)
        let down = touchDown(160, 320, 320, 640), up = touchUp(160, 320, 320, 640)
        #expect(try await rig.nextControl(links.control, 2) == [screenOffBytes, down])

        window.close() // willClose: the view's observers
        await rig.model.stop() // what MirrorWindowController.windowWillClose does
        #expect(try await rig.controlUntilClosed(links.control) == [screenOnBytes, up])
        let stop = try #require(rig.log.first { $0.type == .mirrorStop })
        #expect(stop.controlBytes >= UInt64(screenOffBytes.count + down.count + screenOnBytes.count))
    }

    /// M1: the window's `windowShouldClose` calls `screenOnBeforeClose()` before the window
    /// resigns key, whose release may come before `willClose`.
    @Test func screenOnBeforeCloseComesBeforeAResignKeyRelease() async throws {
        let rig = ExtrasRig()
        let links = try await rig.running()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 160, height: 320), styleMask: [.titled, .closable],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let view = MirrorView(frame: NSRect(x: 0, y: 0, width: 160, height: 320))
        window.contentView = view
        view.bind(rig.model, closeWindow: {})
        rig.model.setScreenOff(true)
        view.input?.mouseDown(at: CGPoint(x: 80, y: 160), viewSize: view.bounds.size)
        #expect(try await rig.nextControl(links.control, 2).count == 2)

        rig.model.screenOnBeforeClose()
        #expect(!rig.model.screenOff)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        window.close()
        await rig.model.stop()
        // On once, then the UP, then the link closes.
        #expect(try await rig.controlUntilClosed(links.control) == [screenOnBytes, touchUp(160, 320, 320, 640)])
    }

    /// M2: link failed with the screen off and the control link already dead: the screen-on
    /// can't go, and the stop doesn't wait for the drain deadline (the clock never moves).
    @Test func linkFailedWithDeadControlLinkDoesNotWait() async throws {
        let fake = FakeResetClock()
        let rig = ExtrasRig(clock: fake)
        let links = try await rig.running()
        rig.model.setScreenOff(true)
        #expect(try await rig.nextControl(links.control, 1) == [screenOffBytes])
        links.control.close()
        try await until("link failed") { rig.model.phase == .ended(.phone(.linkFailed)) && rig.stops == 1 }
        #expect(fake.elapsed == .zero)
        #expect(!rig.model.screenOff)
    }

    /// M2: the start deadline with the screen off and a control link that takes nothing: the stop
    /// goes at the 200 ms drain deadline, not before and not later.
    @Test func timeoutWithStalledControlLinkWaitsAtMostTheDeadline() async throws {
        let fake = FakeResetClock()
        let rig = ExtrasRig(clock: fake, startDeadline: .seconds(2))
        // The start deadline passes when the test says, after the first frame has turned the
        // screen off: a busy runner cannot reorder the two.
        let sleeps = ManualSleeps()
        rig.model.startSleep = sleeps.sleep
        rig.model.screenOffByDefault = true
        await rig.ready()
        await rig.model.start()
        let (videoMac, videoPhone) = MemoryPipe.pair()
        rig.model.link(videoMac, grant: BulkGrant(role: .mirrorVideo, context: "mirror-1"))
        rig.model.link(StalledPipe(), grant: BulkGrant(role: .mirrorControl, context: "mirror-1"))
        // Frames, but no RUNNING from the phone: the start deadline will pass.
        try await videoPhone.send(sampleWithDummyByte)
        try await until("screen off") { rig.model.screenOff }
        let session = try #require(rig.model.session)
        try await until("the start deadline") { sleeps.pending == 1 }
        sleeps.fire()
        // The deadline queues the screen-on and waits for it to be written.
        try await until("timed out, waiting") { session.flushesWaitingOrDone == 1 }
        #expect(!rig.model.screenOff)
        fake.advance(by: .milliseconds(199))
        #expect(rig.stops == 0)
        #expect(rig.model.phase == .starting)
        fake.advance(by: .milliseconds(1))
        try await until("stopped") { rig.model.phase == .ended(.timeout) && rig.stops == 1 }
    }

    /// M3: Screen Off / Screen On is offered only with the control link there.
    @Test func canSetScreenOffNeedsTheControlLink() async throws {
        let rig = ExtrasRig()
        await rig.ready()
        await rig.model.start()
        let (videoMac, videoPhone) = MemoryPipe.pair()
        rig.model.link(videoMac, grant: BulkGrant(role: .mirrorVideo, context: "mirror-1"))
        var s = AMMirrorState()
        s.session = 1
        s.phase = .running
        await rig.model.message(envelope(.mirror, .mirrorState, s))
        try await videoPhone.send(sampleWithDummyByte)
        try await until("running") { rig.model.phase == .running(width: 320, height: 640) }
        #expect(!rig.model.canSetScreenOff)
        rig.model.setScreenOff(true)
        #expect(!rig.model.screenOff)
        let (controlMac, _) = MemoryPipe.pair()
        rig.model.link(controlMac, grant: BulkGrant(role: .mirrorControl, context: "mirror-1"))
        #expect(rig.model.canSetScreenOff)
        await rig.model.stop()
        #expect(!rig.model.canSetScreenOff)
    }

    // MARK: the helper's clipboard

    @Test func deviceClipboardReachesTheHook() async throws {
        let rig = ExtrasRig()
        let links = try await rig.running()
        let got = Recorder<String>()
        rig.model.onPhoneClipboard = { text, explicit in got.append("\(text)|\(explicit)") }
        try await links.control.send(try #require(deviceVector("clipboard_emoji")).bytes)
        try await links.control.send(try #require(deviceVector("ack_clipboard")).bytes)
        try await links.control.send(try #require(deviceVector("uhid_output")).bytes)
        try await links.control.send(try #require(deviceVector("clipboard_ascii")).bytes)
        try await until("clipboards") { got.count == 2 }
        #expect(got.all == ["été 📋✨|false", "copied on the phone|false"])
        #expect(rig.model.phase == .running(width: 320, height: 640))
    }

    /// ⌘C in the mirror sends GET_CLIPBOARD; what the helper sends within 2 s counts as explicit.
    @Test func clipboardAfterCopyIsExplicit() async throws {
        let rig = ExtrasRig()
        let links = try await rig.running()
        let got = Recorder<Bool>()
        rig.model.onPhoneClipboard = { _, explicit in got.append(explicit) }
        let view = MirrorView(frame: NSRect(x: 0, y: 0, width: 160, height: 320))
        view.bind(rig.model, closeWindow: {})
        view.input?.shortcut(.copy)
        #expect(try await rig.nextControl(links.control, 1) == [ScrcpyControl.getClipboard(copyKey: 1)])
        try await links.control.send(deviceClipboardBytes("selected"))
        try await until("clipboard") { got.count == 1 }
        #expect(got.all == [true])
    }

    @Test func explicitWindowIsTwoSeconds() async throws {
        let fake = FakeResetClock()
        let got = Recorder<Bool>()
        let session = MirrorSession(id: 1, sink: CountingSink(), events: { event in
            if case let .clipboard(_, explicit) = event { got.append(explicit) }
        }, clock: fake.clock)
        let (controlMac, controlPhone) = MemoryPipe.pair()
        session.attach(controlMac, role: .mirrorControl)
        // No GET_CLIPBOARD yet: automatic.
        try await controlPhone.send(deviceClipboardBytes("a"))
        try await until("first") { got.count == 1 }
        session.sendControl(ScrcpyControl.getClipboard(copyKey: 2))
        fake.advance(by: .seconds(2))
        try await controlPhone.send(deviceClipboardBytes("b"))
        try await until("second") { got.count == 2 }
        fake.advance(by: .milliseconds(1))
        try await controlPhone.send(deviceClipboardBytes("c"))
        try await until("third") { got.count == 3 }
        #expect(got.all == [false, true, false])
        session.close()
    }

    /// Bytes the Mac can't read end the device messages, not the session: nothing more is
    /// reported from the link, it is still drained, and it doesn't count as ended.
    @Test func unreadableDeviceMessagesKeepTheSession() async throws {
        let events = Recorder<String>()
        let session = MirrorSession(id: 1, sink: CountingSink(), events: { event in
            switch event {
            case let .clipboard(text, _): events.append("clipboard \(text)")
            case let .linkEnded(role): events.append("linkEnded \(role)")
            default: break
            }
        })
        let (controlMac, controlPhone) = MemoryPipe.pair()
        session.attach(controlMac, role: .mirrorControl)
        try await controlPhone.send(deviceClipboardBytes("before"))
        try await until("first chunk") { session.deviceChunksRead == 1 }
        try await controlPhone.send(Data([9, 9, 9]) + deviceClipboardBytes("after garbage"))
        try await until("second chunk") { session.deviceChunksRead == 2 }
        #expect(session.deviceMessagesUnreadable)
        try await controlPhone.send(deviceClipboardBytes("later"))
        try await until("third chunk") { session.deviceChunksRead == 3 }
        // Events are reported from the read loop itself, before the next chunk is read.
        #expect(events.all == ["clipboard before"])
        #expect(!controlMac.isClosed)
        // Its end is still reported.
        controlPhone.close()
        try await until("ended") { events.all == ["clipboard before", "linkEnded mirrorControl"] }
        session.close()
    }

    /// The Task 6 review's acceptance test, wired as `AppModel` wires it: emoji and other scripts
    /// the user types go as SET_CLIPBOARD + paste (`onPasteSent`), the phone's clipboard then holds
    /// them and the helper echoes it back; the echo must not replace the Mac's pasteboard.
    @Test func typedTextEchoLeavesTheMacPasteboard() async throws {
        let board = TestPasteboard()
        let clipboard = ClipboardModel(pasteboard: board, sendEnabled: true, send: { _, _ in }, interval: .seconds(3600))
        await clipboard.connected(phoneID: phoneHex, phoneName: "Pixel", shared: ["clipboard.v1", "mirror.v1"])
        var on = AMFeatureAvailability()
        on.enabled = true
        var e = AMEnvelope()
        e.channel = .clipboard
        e.type = MessageType.clipboardAvailability.rawValue
        e.payload = try on.serializedData()
        await clipboard.message(e)
        board.copy("the user's own clipboard")
        await clipboard.poll()

        let rig = ExtrasRig()
        let links = try await rig.running(shared: ["clipboard.v1", "mirror.v1"])
        rig.model.onPasteSent = { [weak clipboard] text in clipboard?.noteSentToPhone(text) }
        rig.model.onPhoneClipboard = { [weak clipboard] text, explicit in clipboard?.acceptFromHelper(text, explicit: explicit) }
        let view = MirrorView(frame: NSRect(x: 0, y: 0, width: 160, height: 320))
        view.bind(rig.model, closeWindow: {})

        for typed in ["😀", "привет", "日本語"] {
            view.insertText(typed, replacementRange: NSRange(location: NSNotFound, length: 0))
            let sentToPhone = try await rig.nextControl(links.control, 1)
            #expect(sentToPhone.first?.first == 9, "\(typed) goes as SET_CLIPBOARD")
            #expect(sentToPhone.first.map { String(decoding: $0.dropFirst(14), as: UTF8.self) } == typed)
            // The phone's clipboard now holds it; the helper reports that.
            try await links.control.send(deviceClipboardBytes(typed))
        }
        // Something copied on the phone afterwards still comes, so the echoes have all been handled.
        try await links.control.send(deviceClipboardBytes("copied on the phone"))
        try await until("phone copy") { board.writes == ["copied on the phone"] }
        #expect(board.writes == ["copied on the phone"], "no echo of typed text reached the pasteboard")
    }

    // MARK: files dropped on the mirror

    @Test func dropSendsFilesWhenFilesShared() async throws {
        let rig = ExtrasRig()
        try await rig.running(shared: ["mirror.v1", "files.v1"])
        var dropped: [[URL]] = []
        rig.model.onDropFiles = { dropped.append($0) }
        let urls = [URL(fileURLWithPath: "/tmp/a.txt"), URL(fileURLWithPath: "/tmp/b.png")]
        #expect(rig.model.canDropFiles)
        #expect(rig.model.dropFiles(urls))
        #expect(dropped == [urls])
        // Nothing to send: not taken.
        #expect(!rig.model.dropFiles([]))
        #expect(dropped.count == 1)
    }

    @Test func dropWithoutFilesSharedSendsNothing() async throws {
        let rig = ExtrasRig()
        try await rig.running(shared: ["mirror.v1"])
        var dropped: [[URL]] = []
        rig.model.onDropFiles = { dropped.append($0) }
        #expect(!rig.model.canDropFiles)
        #expect(!rig.model.dropFiles([URL(fileURLWithPath: "/tmp/a.txt")]))
        #expect(dropped.isEmpty)
    }

    @Test func dropIgnoredWhileNotRunning() async throws {
        let rig = ExtrasRig()
        var dropped: [[URL]] = []
        rig.model.onDropFiles = { dropped.append($0) }
        let urls = [URL(fileURLWithPath: "/tmp/a.txt")]
        await rig.ready(shared: ["mirror.v1", "files.v1"])
        #expect(!rig.model.dropFiles(urls)) // idle
        await rig.model.start()
        #expect(!rig.model.canDropFiles)
        #expect(!rig.model.dropFiles(urls)) // starting
        await rig.model.stop()
        #expect(!rig.model.dropFiles(urls)) // ended
        #expect(dropped.isEmpty)
        // The view takes file drags only while the model would take them.
        let view = MirrorView(frame: NSRect(x: 0, y: 0, width: 160, height: 320))
        view.bind(rig.model, closeWindow: {})
        #expect(view.registeredDraggedTypes.contains(.fileURL))
        #expect(!view.acceptsFileDrop)
        try await rig.running(ready: false)
        #expect(view.acceptsFileDrop)
    }

    // MARK: the view's drag path (M4, M5)

    /// A file dragged from the Finder while running with files.v1: copy, then the drop goes to
    /// `onDropFiles` as the file URLs.
    @Test func dragOfFilesIsTakenAndDropped() async throws {
        let files = try DragFiles()
        defer { files.remove() }
        let rig = ExtrasRig()
        try await rig.running(shared: ["mirror.v1", "files.v1"])
        var dropped: [[URL]] = []
        rig.model.onDropFiles = { dropped.append($0) }
        let view = MirrorView(frame: NSRect(x: 0, y: 0, width: 160, height: 320))
        view.bind(rig.model, closeWindow: {})
        let drag = FakeDrag([files.file, files.folder])
        #expect(view.draggingEntered(drag) == .copy)
        #expect(view.draggingUpdated(drag) == .copy)
        #expect(view.prepareForDragOperation(drag))
        #expect(view.performDragOperation(drag))
        // Folders among files go to the app, which skips them and says so.
        #expect(dropped.map { $0.map(\.lastPathComponent) } == [["a.txt", "folder"]])
    }

    /// M4: only folders: no copy cursor, and nothing dropped.
    @Test func folderOnlyDragIsNotTaken() async throws {
        let files = try DragFiles()
        defer { files.remove() }
        let rig = ExtrasRig()
        try await rig.running(shared: ["mirror.v1", "files.v1"])
        var dropped: [[URL]] = []
        rig.model.onDropFiles = { dropped.append($0) }
        let view = MirrorView(frame: NSRect(x: 0, y: 0, width: 160, height: 320))
        view.bind(rig.model, closeWindow: {})
        let drag = FakeDrag([files.folder])
        #expect(view.draggingEntered(drag) == [])
        #expect(!view.prepareForDragOperation(drag))
        #expect(!view.performDragOperation(drag))
        #expect(dropped.isEmpty)
    }

    /// A web link is not a file: not taken.
    @Test func webURLDragIsNotTaken() async throws {
        let rig = ExtrasRig()
        try await rig.running(shared: ["mirror.v1", "files.v1"])
        var dropped: [[URL]] = []
        rig.model.onDropFiles = { dropped.append($0) }
        let view = MirrorView(frame: NSRect(x: 0, y: 0, width: 160, height: 320))
        view.bind(rig.model, closeWindow: {})
        let drag = FakeDrag([try #require(URL(string: "https://example.com/a.txt"))])
        #expect(view.draggingEntered(drag) == [])
        #expect(!view.performDragOperation(drag))
        #expect(dropped.isEmpty)
    }

    /// Files, but not running or without files.v1: not taken.
    @Test func fileDragNotTakenWhenTheModelWouldNot() async throws {
        let files = try DragFiles()
        defer { files.remove() }
        let drag = FakeDrag([files.file])
        for shared: Set<String> in [["mirror.v1"], ["mirror.v1", "files.v1"]] {
            let rig = ExtrasRig()
            var dropped: [[URL]] = []
            rig.model.onDropFiles = { dropped.append($0) }
            let view = MirrorView(frame: NSRect(x: 0, y: 0, width: 160, height: 320))
            view.bind(rig.model, closeWindow: {})
            await rig.ready(shared: shared)
            #expect(view.draggingEntered(drag) == [], "idle, \(shared)")
            #expect(!view.performDragOperation(drag))
            try await rig.running(shared: shared, ready: false)
            let running = view.draggingEntered(drag)
            #expect(running == (shared.contains("files.v1") ? .copy : []), "running, \(shared)")
            #expect(view.performDragOperation(drag) == shared.contains("files.v1"))
            #expect(dropped.count == (shared.contains("files.v1") ? 1 : 0))
        }
    }
}

/// A file and a folder in a temporary folder of their own.
struct DragFiles {
    let root: URL
    var file: URL { root.appendingPathComponent("a.txt") }
    var folder: URL { root.appendingPathComponent("folder", isDirectory: true) }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("am-drag-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("folder"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: root.appendingPathComponent("a.txt"))
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

/// A drag whose pasteboard (a private one) holds `urls`. AppKit calls drag destinations on the
/// main thread only; `@preconcurrency` checks that at run time.
@MainActor
final class FakeDrag: NSObject, @preconcurrency NSDraggingInfo {
    let draggingPasteboard = NSPasteboard(name: NSPasteboard.Name("am-test-drag-\(UUID().uuidString)"))

    init(_ urls: [URL]) {
        super.init()
        draggingPasteboard.clearContents()
        draggingPasteboard.writeObjects(urls.map { $0 as NSURL })
    }

    deinit { MainActor.assumeIsolated { draggingPasteboard.releaseGlobally() } }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}

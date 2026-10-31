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

    init() {
        let sent = sent
        var record: ((MessageType) -> Void)?
        model = MirrorModel(bulk: bulk, send: { type, message in
            sent.all.append((type, message))
            record?(type)
        }, makeSink: { CountingSink() })
        model.linkGrace = .milliseconds(100)
        record = { [unowned self] type in log.append((type, control?.mac.bytesSent ?? 0)) }
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
        // Nothing before the first frame.
        try await Task.sleep(for: .milliseconds(50))
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
        try await Task.sleep(for: .milliseconds(50))
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

    /// Bytes the Mac can't read end the device messages, not the session: video goes on and the
    /// link is still drained.
    @Test func unreadableDeviceMessagesKeepTheSession() async throws {
        let rig = ExtrasRig()
        let links = try await rig.running()
        let got = Recorder<String>()
        rig.model.onPhoneClipboard = { text, _ in got.append(text) }
        try await links.control.send(Data([9, 9, 9]) + deviceClipboardBytes("after garbage"))
        try await Task.sleep(for: .milliseconds(250)) // past the link grace
        #expect(got.count == 0)
        #expect(rig.model.phase == .running(width: 320, height: 640))
        #expect(!rig.model.linkEndPending)
        #expect(rig.control?.mac.isClosed == false)
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
}

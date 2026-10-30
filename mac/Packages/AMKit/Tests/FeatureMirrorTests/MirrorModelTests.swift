import AMProtocol
import AMTestSupport
import AppKit
import ConnectionCore
import Foundation
import SwiftProtobuf
import Testing
@testable import FeatureMirror

/// A model with a fake bulk listener, a recording `send` and counting sinks.
@MainActor
private final class Rig {
    let bulk = FakeBulk()
    let sent = SentLog()
    let model: MirrorModel

    init(startDeadline: Duration = .seconds(20)) {
        let sent = sent
        model = MirrorModel(
            bulk: bulk,
            send: { type, message in sent.all.append((type, message)) },
            makeSink: { CountingSink() },
            startDeadline: startDeadline
        )
        model.linkGrace = .milliseconds(100)
    }

    /// Connected, sharing `mirror.v1`, with the phone's availability enabled.
    func ready(shared: Set<String> = ["mirror.v1"]) async {
        await model.connected(phoneID: phoneHex, phoneName: "Pixel", shared: shared)
        await availability(true)
    }

    func availability(_ enabled: Bool, _ reason: AMAvailabilityReason = .unspecified) async {
        var a = AMFeatureAvailability()
        a.enabled = enabled
        a.reason = reason
        await model.message(envelope(.mirror, .mirrorAvailability, a))
    }

    func state(_ session: UInt32, _ phase: AMMirrorPhase, _ reason: AMMirrorReason = .unspecified) async {
        var s = AMMirrorState()
        s.session = session
        s.phase = phase
        s.reason = reason
        await model.message(envelope(.mirror, .mirrorState, s))
    }

    func phoneStop(_ session: UInt32, _ reason: AMMirrorReason) async {
        var s = AMMirrorStop()
        s.session = session
        s.reason = reason
        await model.message(envelope(.mirror, .mirrorStop, s))
    }

    var starts: [AMMirrorStart] { sent.of(.mirrorStart, AMMirrorStart.self) }
    var stops: [AMMirrorStop] { sent.of(.mirrorStop, AMMirrorStop.self) }

    /// A redeemed link for `role` in `session`'s context; returns the phone's end.
    @discardableResult
    func link(_ role: AMBulkRole, session: UInt32) -> (mac: MemoryPipe, phone: MemoryPipe) {
        let (mac, phone) = MemoryPipe.pair()
        model.link(mac, grant: BulkGrant(role: role, context: "mirror-\(session)"))
        return (mac, phone)
    }

    /// Started, RUNNING from the phone, the sample's first frames decoded.
    func running() async throws -> (video: (mac: MemoryPipe, phone: MemoryPipe), control: (mac: MemoryPipe, phone: MemoryPipe)) {
        await ready()
        await model.start()
        let id = model.sessionID
        let video = link(.mirrorVideo, session: id)
        let control = link(.mirrorControl, session: id)
        await state(id, .running)
        try await video.phone.send(sampleWithDummyByte)
        try await until("running") { model.phase == .running(width: 320, height: 640) }
        return (video, control)
    }
}

@MainActor
@Suite struct MirrorModelTests {
    @Test func startIssuesTokensAndSendsStart() async throws {
        let rig = Rig()
        await rig.ready()
        #expect(rig.model.canStart)
        await rig.model.start()
        #expect(rig.model.sessionID == 1)
        #expect(rig.model.phase == .starting)
        #expect(rig.model.session != nil)
        #expect(rig.bulk.issued.map(\.role) == [.mirrorVideo, .mirrorControl])
        #expect(rig.bulk.issued.map(\.context) == ["mirror-1", "mirror-1"])
        let start = try #require(rig.starts.first)
        #expect(rig.sent.types == [.mirrorStart])
        #expect(start.session == 1)
        #expect(start.port == 4242)
        #expect(start.tokens.video == rig.bulk.issued[0].token)
        #expect(start.tokens.control == rig.bulk.issued[1].token)
        #expect(start.tokens.audio.isEmpty)
        #expect(!start.audio)
        #expect(start.maxSize == 1920 && start.videoBitRate == 8_000_000 && start.maxFps == 60)
        #expect(start.videoCodec == .h264)
    }

    @Test func startCarriesThePresetAndCodec() async throws {
        let rig = Rig()
        await rig.ready()
        rig.model.preset = .low
        rig.model.codec = .h265
        await rig.model.start()
        let start = try #require(rig.starts.first)
        #expect(start.maxSize == 960 && start.videoBitRate == 2_000_000 && start.maxFps == 30)
        #expect(start.videoCodec == .h265)
        // Unspecified means H.264, and is sent as H.264.
        rig.model.codec = .unspecified
        await rig.model.start()
        #expect(rig.starts.last?.videoCodec == .h264)
    }

    @Test func startWithoutAvailabilitySendsNothing() async throws {
        let rig = Rig()
        // Not connected.
        await rig.model.start()
        // Connected, no availability yet.
        await rig.model.connected(phoneID: phoneHex, phoneName: "Pixel", shared: ["mirror.v1"])
        await rig.model.start()
        // Availability off.
        await rig.availability(false, .needsSetup)
        #expect(!rig.model.canStart)
        await rig.model.start()
        // Enabled, but no bulk port.
        await rig.availability(true)
        rig.bulk.port = nil
        #expect(!rig.model.canStart)
        await rig.model.start()
        // Enabled, but the phone doesn't share mirror.v1.
        rig.bulk.port = 4242
        await rig.model.connected(phoneID: phoneHex, phoneName: "Pixel", shared: ["files.v1"])
        await rig.availability(true)
        #expect(!rig.model.canStart)
        await rig.model.start()
        #expect(rig.sent.all.isEmpty)
        #expect(rig.bulk.issued.isEmpty)
        #expect(rig.model.phase == .idle)
        #expect(rig.model.sessionID == 0)
    }

    @Test func staleStateFromOldSessionIgnored() async throws {
        let rig = Rig()
        await rig.ready()
        await rig.model.start()
        await rig.model.start()
        #expect(rig.model.sessionID == 2)
        await rig.state(1, .failed, .helperFailed)
        await rig.state(1, .stopped, .replaced)
        await rig.phoneStop(1, .linkFailed)
        #expect(rig.model.phase == .starting)
        #expect(rig.model.session != nil)
        await rig.state(3, .failed, .helperFailed)
        #expect(rig.model.phase == .starting)
    }

    @Test func runningWaitsForFirstFrame() async throws {
        let rig = Rig()
        await rig.ready()
        await rig.model.start()
        let video = rig.link(.mirrorVideo, session: 1)
        await rig.state(1, .starting)
        await rig.state(1, .running)
        #expect(rig.model.phase == .starting)
        try await video.phone.send(sampleWithDummyByte)
        try await until("running") { rig.model.phase == .running(width: 320, height: 640) }
        #expect(rig.model.session?.videoSize?.width == 320)
    }

    @Test func firstFrameBeforeRunningWaitsForTheState() async throws {
        let rig = Rig()
        await rig.ready()
        await rig.model.start()
        let video = rig.link(.mirrorVideo, session: 1)
        try await video.phone.send(sampleWithDummyByte)
        try await until("frames decoded") { rig.model.firstFrameSeen }
        #expect(rig.model.phase == .starting)
        await rig.state(1, .running)
        #expect(rig.model.phase == .running(width: 320, height: 640))
    }

    @Test func failedStateEndsWithReason() async throws {
        let rig = Rig()
        await rig.ready()
        await rig.model.start()
        let video = rig.link(.mirrorVideo, session: 1)
        await rig.state(1, .failed, .helperFailed)
        #expect(rig.model.phase == .ended(.phone(.helperFailed)))
        #expect(rig.model.session == nil)
        #expect(rig.bulk.revoked == ["mirror-1"])
        #expect(video.mac.isClosed)
        // The phone already stopped: no stop goes back.
        #expect(rig.stops.isEmpty)
    }

    @Test func phoneStopForCurrentSessionEnds() async throws {
        let rig = Rig()
        _ = try await rig.running()
        await rig.phoneStop(1, .turnedOff)
        #expect(rig.model.phase == .ended(.phone(.turnedOff)))
        #expect(rig.bulk.revoked == ["mirror-1"])
        #expect(rig.stops.isEmpty)
    }

    @Test func stopSendsStopAndRevokesTokens() async throws {
        let rig = Rig()
        let links = try await rig.running()
        await rig.model.stop()
        let stop = try #require(rig.stops.first)
        #expect(stop.session == 1)
        #expect(stop.reason == .user)
        #expect(rig.bulk.revoked == ["mirror-1"])
        #expect(rig.model.phase == .ended(.user))
        #expect(rig.model.session == nil)
        #expect(links.video.mac.isClosed && links.control.mac.isClosed)
        // A second stop, or the phone's STOPPED answer, changes nothing.
        await rig.model.stop()
        await rig.state(1, .stopped, .user)
        #expect(rig.stops.count == 1)
        #expect(rig.model.phase == .ended(.user))
    }

    @Test func disconnectClosesSessionAndRevokes() async throws {
        let rig = Rig()
        let links = try await rig.running()
        rig.model.disconnected()
        #expect(rig.model.phase == .ended(.disconnected))
        #expect(rig.model.session == nil)
        #expect(rig.model.phoneAvailability == nil)
        #expect(!rig.model.canStart)
        #expect(rig.bulk.revoked == ["mirror-1"])
        #expect(links.video.mac.isClosed && links.control.mac.isClosed)
        #expect(rig.stops.isEmpty)
    }

    @Test func forgetEndsLikeDisconnect() async throws {
        let rig = Rig()
        await rig.ready()
        await rig.model.start()
        await rig.model.forget(phoneID: phoneHex)
        #expect(rig.model.phase == .ended(.disconnected))
        #expect(rig.model.phoneAvailability == nil)
        #expect(rig.bulk.revoked == ["mirror-1"])
    }

    @Test func forgettingAnotherPhoneLeavesTheSessionAlone() async throws {
        let rig = Rig()
        let links = try await rig.running()
        await rig.model.forget(phoneID: String(repeating: "ab", count: 32))
        #expect(rig.model.phase == .running(width: 320, height: 640))
        #expect(rig.model.session != nil)
        #expect(rig.model.phoneAvailability?.enabled == true)
        #expect(rig.model.canStart)
        #expect(rig.bulk.revoked.isEmpty)
        #expect(!links.video.mac.isClosed)
    }

    @Test func sleepNowClosesBeforeReturning() async throws {
        let rig = Rig()
        let links = try await rig.running()
        rig.model.macWillSleepNow()
        // Everything local is done before the call returns.
        #expect(rig.model.phase == .ended(.macSleep))
        #expect(rig.model.session == nil)
        #expect(rig.bulk.revoked == ["mirror-1"])
        #expect(links.video.mac.isClosed && links.control.mac.isClosed)
        try await until("stop sent") { rig.stops.count == 1 }
        #expect(rig.stops.first?.reason == .user)
        #expect(rig.stops.first?.session == 1)
    }

    @Test func sleepStopsSession() async throws {
        let rig = Rig()
        _ = try await rig.running()
        await rig.model.macWillSleep()
        #expect(rig.model.phase == .ended(.macSleep))
        #expect(rig.stops.map(\.reason) == [.user])
        #expect(rig.stops.first?.session == 1)
        #expect(rig.bulk.revoked == ["mirror-1"])
        // Asleep with nothing running: nothing is sent.
        await rig.model.macWillSleep()
        #expect(rig.stops.count == 1)
    }

    @Test func startTimesOutAfter20s() async throws {
        #expect(MirrorModel.defaultStartDeadline == .seconds(20))
        let rig = Rig(startDeadline: .milliseconds(100))
        await rig.ready()
        await rig.model.start()
        // RUNNING without a frame does not count.
        await rig.state(1, .running)
        try await until("timed out") { rig.model.phase == .ended(.timeout) }
        #expect(rig.stops.map(\.session) == [1])
        #expect(rig.stops.map(\.reason) == [.user])
        #expect(rig.bulk.revoked == ["mirror-1"])
        #expect(rig.model.session == nil)
    }

    @Test func runningSessionDoesNotTimeOut() async throws {
        let rig = Rig(startDeadline: .milliseconds(300))
        _ = try await rig.running()
        try await Task.sleep(for: .milliseconds(450))
        #expect(rig.model.phase == .running(width: 320, height: 640))
        #expect(rig.stops.isEmpty)
    }

    @Test func linkForOldSessionIsClosed() async throws {
        let rig = Rig()
        await rig.ready()
        await rig.model.start()
        await rig.model.start()
        let old = rig.link(.mirrorVideo, session: 1)
        #expect(old.mac.isClosed)
        let other = MemoryPipe.pair()
        rig.model.link(other.0, grant: BulkGrant(role: .mirrorVideo, context: "thumbs"))
        #expect(other.0.isClosed)
        let current = rig.link(.mirrorVideo, session: 2)
        #expect(!current.mac.isClosed)
        // After the session ends, its own context is closed too.
        await rig.model.stop()
        let late = rig.link(.mirrorControl, session: 2)
        #expect(late.mac.isClosed)
    }

    @Test func newStartReplacesSession() async throws {
        let rig = Rig()
        let links = try await rig.running()
        let first = rig.model.session
        await rig.model.start()
        #expect(rig.model.sessionID == 2)
        #expect(rig.model.session !== first)
        #expect(rig.model.phase == .starting)
        #expect(links.video.mac.isClosed && links.control.mac.isClosed)
        #expect(rig.bulk.revoked == ["mirror-1"])
        // The phone ends the old one itself (REPLACED); the Mac sends no stop.
        #expect(rig.stops.isEmpty)
        #expect(rig.starts.map(\.session) == [1, 2])
        #expect(rig.bulk.issued.map(\.context) == ["mirror-1", "mirror-1", "mirror-2", "mirror-2"])
    }

    @Test func linkEndedWhileRunningEndsWithLinkFailed() async throws {
        let rig = Rig()
        let links = try await rig.running()
        links.video.phone.close()
        try await until("link failed") { rig.model.phase == .ended(.phone(.linkFailed)) }
        #expect(rig.stops.map(\.reason) == [.user])
        #expect(rig.bulk.revoked == ["mirror-1"])
        #expect(links.control.mac.isClosed)
    }

    @Test func linkEndedThenStateWithinGraceUsesTheState() async throws {
        let rig = Rig()
        rig.model.linkGrace = .milliseconds(300)
        let links = try await rig.running()
        links.video.phone.close()
        try await until("link end seen") { rig.model.linkEndPending }
        await rig.state(1, .failed, .helperFailed)
        #expect(rig.model.phase == .ended(.phone(.helperFailed)))
        #expect(!rig.model.linkEndPending) // the grace timer is cancelled
        // Well past the grace: still the phone's reason, and no stop went out.
        try await Task.sleep(for: .milliseconds(500))
        #expect(rig.model.phase == .ended(.phone(.helperFailed)))
        #expect(rig.stops.isEmpty)
    }

    @Test func oversizedPacketEndsWithLinkFailed() async throws {
        let rig = Rig()
        let links = try await rig.running()
        var header = Data(count: 8)
        withUnsafeBytes(of: UInt32((16 << 20) + 1).bigEndian) { header.append(contentsOf: $0) }
        try await links.video.phone.send(header)
        try await until("link failed") { rig.model.phase == .ended(.phone(.linkFailed)) }
        #expect(links.video.mac.isClosed)
    }

    @Test func needsResetSendsResetVideoOnTheControlLink() async throws {
        let rig = Rig()
        await rig.ready()
        await rig.model.start()
        let control = rig.link(.mirrorControl, session: 1)
        rig.model.handle(.needsReset, session: 1)
        let bytes = try await readAll(control.phone, 1)
        #expect(bytes == Data([17]))
        // An event for another session does nothing.
        rig.model.handle(.needsReset, session: 7)
        rig.model.handle(.linkEnded(.mirrorVideo), session: 7)
        #expect(!rig.model.linkEndPending)
    }

    @Test func sessionEventFromBackgroundThreadReachesModel() async throws {
        let rig = Rig()
        await rig.ready()
        await rig.model.start()
        await rig.state(1, .running)
        let handler = MirrorModel.eventHandler(for: rig.model, session: 1)
        DispatchQueue.global().async {
            handler(.size(width: 640, height: 320))
            handler(.firstFrame)
        }
        try await until("running") { rig.model.phase == .running(width: 640, height: 320) }
    }

    @Test func sizeChangeWhileRunningUpdatesThePhase() async throws {
        let rig = Rig()
        _ = try await rig.running()
        rig.model.handle(.size(width: 640, height: 320), session: 1)
        #expect(rig.model.phase == .running(width: 640, height: 320))
    }

    @Test func availabilityOffWhileRunningWaitsForThePhonesState() async throws {
        let rig = Rig()
        _ = try await rig.running()
        await rig.availability(false, .offByUser)
        #expect(rig.model.phase == .running(width: 320, height: 640))
        #expect(!rig.model.canStart)
        await rig.state(1, .stopped, .turnedOff)
        #expect(rig.model.phase == .ended(.phone(.turnedOff)))
    }

    @Test func sleepObserverDeliveredOffMainReachesTheMainActor() async throws {
        let calls = Recorder<Bool>()
        let center = NotificationCenter()
        let token = MacSleepObserver.install(center: center) {
            MainActor.assertIsolated()
            calls.append(true)
        }
        defer { center.removeObserver(token) }
        DispatchQueue.global().async {
            center.post(name: NSWorkspace.willSleepNotification, object: nil)
        }
        try await until("sleep seen") { calls.count == 1 }
    }
}

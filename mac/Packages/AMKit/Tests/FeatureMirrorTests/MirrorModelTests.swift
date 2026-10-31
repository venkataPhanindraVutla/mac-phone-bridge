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
        // Auto quality is evaluated by hand here (`evaluateQuality`); the 1 s ticker stays out of the way.
        model.qualityInterval = .seconds(3600)
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
        // Audio is on by default ("Play phone audio on this Mac").
        #expect(rig.bulk.issued.map(\.role) == [.mirrorVideo, .mirrorAudio, .mirrorControl])
        #expect(rig.bulk.issued.map(\.context) == ["mirror-1", "mirror-1", "mirror-1"])
        let start = try #require(rig.starts.first)
        #expect(rig.sent.types == [.mirrorStart])
        #expect(start.session == 1)
        #expect(start.port == 4242)
        #expect(start.tokens.video == rig.bulk.issued[0].token)
        #expect(start.tokens.audio == rig.bulk.issued[1].token)
        #expect(start.tokens.control == rig.bulk.issued[2].token)
        #expect(start.audio)
        #expect(start.audioCodec == (AudioDecoder.supports(.opus) ? .opus : .aac))
        #expect(rig.model.audioActive)
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
        // Video closes at once; control once its queue has gone out (at most 200 ms).
        #expect(links.video.mac.isClosed)
        try await until("control closed") { links.control.mac.isClosed }
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
        // Video closes at once; control once its queue has gone out (at most 200 ms).
        #expect(links.video.mac.isClosed)
        try await until("control closed") { links.control.mac.isClosed }
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
        // Video closes at once; control once its queue has gone out (at most 200 ms).
        #expect(links.video.mac.isClosed)
        try await until("control closed") { links.control.mac.isClosed }
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
        // Video closes at once; control once its queue has gone out (at most 200 ms).
        #expect(links.video.mac.isClosed)
        try await until("control closed") { links.control.mac.isClosed }
        #expect(rig.bulk.revoked == ["mirror-1"])
        // The phone ends the old one itself (REPLACED); the Mac sends no stop.
        #expect(rig.stops.isEmpty)
        #expect(rig.starts.map(\.session) == [1, 2])
        #expect(rig.bulk.issued.map(\.context) == ["mirror-1", "mirror-1", "mirror-1", "mirror-2", "mirror-2", "mirror-2"])
    }

    @Test func linkEndedWhileRunningEndsWithLinkFailed() async throws {
        let rig = Rig()
        let links = try await rig.running()
        links.video.phone.close()
        try await until("link failed") { rig.model.phase == .ended(.phone(.linkFailed)) }
        #expect(rig.stops.map(\.reason) == [.user])
        #expect(rig.bulk.revoked == ["mirror-1"])
        try await until("control closed") { links.control.mac.isClosed }
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
    // MARK: audio

    @Test func audioSettingOffSendsAudioFalse() async throws {
        let rig = Rig()
        await rig.ready()
        rig.model.audioEnabled = false
        await rig.model.start()
        let start = try #require(rig.starts.first)
        #expect(!start.audio)
        #expect(start.tokens.audio.isEmpty)
        #expect(rig.bulk.issued.map(\.role) == [.mirrorVideo, .mirrorControl])
        #expect(!rig.model.audioActive)
        // Turning it back on applies at the next start.
        rig.model.audioEnabled = true
        #expect(rig.starts.count == 1)
        await rig.model.start()
        let next = try #require(rig.starts.last)
        #expect(next.audio)
        #expect(!next.tokens.audio.isEmpty)
        #expect(rig.model.audioActive)
    }

    @Test func opusUnsupportedChoosesAac() async throws {
        let rig = Rig()
        await rig.ready()
        rig.model.opusSupported = { false }
        await rig.model.start()
        #expect(rig.starts.last?.audioCodec == .aac)
        rig.model.opusSupported = { true }
        await rig.model.start()
        #expect(rig.starts.last?.audioCodec == .opus)
    }

    /// The phone can't capture (codec 0) or failed to (codec 1): only the audio path ends.
    @Test func audioUnavailableKeepsVideo() async throws {
        for prelude in ["audio_prelude_disabled", "audio_prelude_error"] {
            let rig = Rig()
            let links = try await rig.running()
            let audio = rig.link(.mirrorAudio, session: 1)
            #expect(rig.model.audioActive)
            try await audio.phone.send(try #require(streamVector(prelude)).bytes)
            try await until("audio ended") { !rig.model.audioActive }
            // The phone then closes its end: still only audio.
            audio.phone.close()
            try await until("audio link closed") { audio.mac.isClosed }
            try await Task.sleep(for: .milliseconds(250)) // past the link grace
            #expect(rig.model.phase == .running(width: 320, height: 640))
            #expect(rig.model.session != nil)
            #expect(!rig.model.linkEndPending)
            #expect(!links.video.mac.isClosed && !links.control.mac.isClosed)
            #expect(rig.stops.isEmpty)
        }
    }

    @Test func audioLinkEndingKeepsVideo() async throws {
        let rig = Rig()
        let links = try await rig.running()
        let audio = rig.link(.mirrorAudio, session: 1)
        audio.phone.close()
        try await until("audio ended") { !rig.model.audioActive }
        try await Task.sleep(for: .milliseconds(250))
        #expect(rig.model.phase == .running(width: 320, height: 640))
        #expect(!links.video.mac.isClosed)
    }

    /// Muted, the session keeps reading and decoding; the output drops it and the link stays up.
    @Test func muteKeepsLink() async throws {
        let rig = Rig()
        _ = try await rig.running()
        let audio = rig.link(.mirrorAudio, session: 1)
        rig.model.muted = true
        let session = try #require(rig.model.session)
        #expect(session.audioMuted)
        let packets = try #require(TestAudioEncoder.encode(.aac, sine: Array(repeating: 0.25, count: 9_600)))
        var stream = try #require(streamVector("audio_prelude_aac")).bytes
        stream += packetBytes(config: true, pts: 0, payload: TestAudioEncoder.aacConfig)
        for (i, packet) in packets.enumerated() { stream += packetBytes(pts: UInt64(i) * 21_333, payload: packet) }
        try await audio.phone.send(stream)
        try await until("decoded") { session.audioBuffersDecoded >= packets.count - 1 }
        #expect(!audio.mac.isClosed)
        #expect(rig.model.audioActive)
        #expect(rig.model.phase == .running(width: 320, height: 640))
        #expect(session.audioBuffersAccepted == 0) // muted: the output took nothing to play
        rig.model.muted = false
        #expect(!session.audioMuted)
    }

    /// 50 packets in a row that decode to nothing end the audio path like `audioEnded`: Mute is
    /// disabled, video goes on, the link stays up.
    @Test func repeatedDecodeFailuresEndTheAudioPath() async throws {
        let rig = Rig()
        let links = try await rig.running()
        let audio = rig.link(.mirrorAudio, session: 1)
        var stream = try #require(streamVector("audio_prelude_aac")).bytes
        stream += packetBytes(config: true, pts: 0, payload: TestAudioEncoder.aacConfig)
        for i in 0..<49 { stream += packetBytes(pts: UInt64(i) * 21_333, payload: Data([0xFF, 0xFF, 0xFF, UInt8(i)])) }
        try await audio.phone.send(stream)
        try await Task.sleep(for: .milliseconds(100))
        #expect(rig.model.audioActive) // 49 is not yet enough
        try await audio.phone.send(packetBytes(pts: 49 * 21_333, payload: Data([0xFF, 0xFF, 0xFF, 49])))
        try await until("audio ended") { !rig.model.audioActive }
        #expect(!audio.mac.isClosed)
        #expect(rig.model.phase == .running(width: 320, height: 640))
        #expect(!links.video.mac.isClosed)
    }

    @Test func muteCarriesToTheNextSession() async throws {
        let rig = Rig()
        await rig.ready()
        rig.model.muted = true
        await rig.model.start()
        #expect(rig.model.session?.audioMuted == true)
    }

    // MARK: quality

    /// Five late seconds under Auto: a new session at Balanced replaces the running one. The window
    /// is kept (the phase goes from running to starting, never ended) and the Mac sends no stop.
    @Test func autoSwitchRestartsAndKeepsWindow() async throws {
        let rig = Rig()
        _ = try await rig.running()
        #expect(rig.model.autoQuality)
        let t0 = ContinuousClock.now
        for s in 1...4 {
            await rig.model.evaluateQuality(medianMs: 200, backlog: 0, now: t0 + .seconds(s))
            #expect(rig.model.phase == .running(width: 320, height: 640))
        }
        #expect(rig.starts.count == 1)
        await rig.model.evaluateQuality(medianMs: 200, backlog: 0, now: t0 + .seconds(5))
        #expect(rig.model.sessionID == 2)
        #expect(rig.model.phase == .starting)
        #expect(rig.model.preset == .balanced)
        #expect(rig.model.autoQuality)
        let start = try #require(rig.starts.last)
        #expect(start.session == 2)
        #expect(start.maxSize == 1280 && start.videoBitRate == 4_000_000 && start.maxFps == 60)
        #expect(rig.stops.isEmpty)
        #expect(rig.bulk.revoked == ["mirror-1"])
        // The new session runs like any other.
        let video = rig.link(.mirrorVideo, session: 2)
        await rig.state(2, .running)
        try await video.phone.send(sampleWithDummyByte)
        try await until("running again") { rig.model.phase == .running(width: 320, height: 640) }
        #expect(rig.model.sessionID == 2)
    }

    /// R22: a restart is an automatic `mirror.start`, so it needs the phone's availability.
    @Test func autoRestartNeedsAvailability() async throws {
        let rig = Rig()
        _ = try await rig.running()
        await rig.availability(false, .offByUser)
        let t0 = ContinuousClock.now
        for s in 1...8 { await rig.model.evaluateQuality(medianMs: 200, backlog: 0, now: t0 + .seconds(s)) }
        #expect(rig.starts.count == 1)
        #expect(rig.model.sessionID == 1)
        #expect(rig.model.preset == .high)
        #expect(rig.model.phase == .running(width: 320, height: 640))
        await rig.availability(true)
        for s in 9...13 { await rig.model.evaluateQuality(medianMs: 200, backlog: 0, now: t0 + .seconds(s)) }
        #expect(rig.starts.count == 2)
        #expect(rig.model.preset == .balanced)
    }

    /// Nothing is evaluated while not running, or with Auto off.
    @Test func autoNeedsARunningSessionAndAuto() async throws {
        let rig = Rig()
        await rig.ready()
        await rig.model.start()
        let t0 = ContinuousClock.now
        for s in 1...6 { await rig.model.evaluateQuality(medianMs: 200, backlog: 0, now: t0 + .seconds(s)) }
        #expect(rig.starts.count == 1)
        #expect(rig.model.preset == .high)
        let rig2 = Rig()
        _ = try await rig2.running()
        rig2.model.autoQuality = false
        for s in 1...6 { await rig2.model.evaluateQuality(medianMs: 200, backlog: 0, now: t0 + .seconds(s)) }
        #expect(rig2.starts.count == 1)
    }

    /// The 1 s ticker feeds the session's lateness and backlog to Auto while a session runs.
    @Test func tickerEvaluatesWhileRunning() async throws {
        let fake = FakeResetClock()
        let rig = Rig()
        rig.model.sessionClock = fake.clock
        rig.model.qualityInterval = .milliseconds(5)
        rig.model.qualityInputForTesting = { (200, 0) }
        _ = try await rig.running()
        for _ in 0..<10 where rig.model.sessionID == 1 {
            let ticks = rig.model.qualityTicks
            fake.advance(by: .seconds(1))
            try await until("a tick") { rig.model.qualityTicks > ticks || rig.model.sessionID == 2 }
        }
        #expect(rig.model.sessionID == 2)
        #expect(rig.starts.last?.maxSize == 1280)
        // Not running yet: the ticker has stopped.
        let ticks = rig.model.qualityTicks
        fake.advance(by: .seconds(1))
        try await Task.sleep(for: .milliseconds(50))
        #expect(rig.model.qualityTicks == ticks)
    }

    /// A preset picked by hand turns Auto off and restarts a running session at once.
    @Test func manualPresetRestartsAndTurnsAutoOff() async throws {
        let rig = Rig()
        _ = try await rig.running()
        await rig.model.choosePreset(.low)
        #expect(!rig.model.autoQuality)
        #expect(rig.model.preset == .low)
        #expect(rig.model.sessionID == 2)
        #expect(rig.model.phase == .starting)
        #expect(rig.starts.last?.maxSize == 960)
        // The same preset again changes nothing.
        await rig.model.choosePreset(.low)
        #expect(rig.starts.count == 2)
        // Auto back on: no restart, Auto goes on from Low.
        rig.model.autoQuality = true
        #expect(rig.starts.count == 2)
        #expect(rig.model.preset == .low)
        // Not running: the choice applies at the next start.
        await rig.model.stop()
        await rig.model.choosePreset(.high)
        #expect(rig.starts.count == 2)
        await rig.model.start()
        #expect(rig.starts.last?.maxSize == 1920)
    }

    /// LINK_SLOW (the phone ended it): the copy says so, and under Auto the next start is one preset lower.
    @Test func linkSlowEndsAndStartsLowerNextTime() async throws {
        let rig = Rig()
        _ = try await rig.running()
        await rig.state(1, .failed, .linkSlow)
        #expect(rig.model.phase == .ended(.phone(.linkSlow)))
        #expect(MirrorCopy.failure(.phone(.linkSlow)) == "The connection was too slow to show the phone screen.")
        #expect(rig.starts.count == 1) // no automatic restart
        #expect(rig.model.preset == .balanced)
        await rig.model.start()
        #expect(rig.starts.last?.maxSize == 1280)
        // A preset picked by hand stays.
        await rig.model.choosePreset(.high)
        await rig.state(rig.model.sessionID, .failed, .linkSlow)
        #expect(rig.model.preset == .high)
    }

    // MARK: H.265

    @Test func h265FailureFallsBackToH264Once() async throws {
        let rig = Rig()
        await rig.ready()
        await rig.model.setH265(true)
        #expect(rig.starts.isEmpty) // nothing running: applies at the next start
        await rig.model.start()
        #expect(rig.starts.last?.videoCodec == .h265)
        await rig.state(1, .failed, .helperFailed)
        // Started again with H.264, the window kept; the toggle is off and the note shows.
        #expect(rig.starts.count == 2)
        #expect(rig.starts.last?.videoCodec == .h264)
        #expect(rig.model.sessionID == 2)
        #expect(rig.model.phase == .starting)
        #expect(rig.model.codec == .h264)
        #expect(rig.model.h265Refused)
        #expect(rig.stops.isEmpty)
        // H.264 fails too: that is the end, once.
        await rig.state(2, .failed, .helperFailed)
        #expect(rig.model.phase == .ended(.phone(.helperFailed)))
        #expect(rig.starts.count == 2)
        #expect(MirrorCopy.h265Note == "This phone can't send H.265. Using H.264.")
        // Turning H.265 on again clears the note.
        await rig.model.setH265(true)
        #expect(!rig.model.h265Refused)
    }

    /// Only a failure before RUNNING falls back; other reasons, or H.264, just end.
    @Test func h265FallbackOnlyForHelperFailedBeforeRunning() async throws {
        let rig = Rig()
        await rig.ready()
        await rig.model.setH265(true)
        await rig.model.start()
        await rig.state(1, .failed, .adbFailed)
        #expect(rig.model.phase == .ended(.phone(.adbFailed)))
        #expect(rig.starts.count == 1)
        // Running on H.265, then HELPER_FAILED: an ordinary end.
        let rig2 = Rig()
        await rig2.ready()
        await rig2.model.setH265(true)
        _ = try await rig2.running()
        await rig2.state(rig2.model.sessionID, .failed, .helperFailed)
        #expect(rig2.model.phase == .ended(.phone(.helperFailed)))
        #expect(rig2.model.codec == .h265)
        #expect(!rig2.model.h265Refused)
    }

    /// "Use H.265" restarts a running session with it.
    @Test func useH265RestartsARunningSession() async throws {
        let rig = Rig()
        _ = try await rig.running()
        await rig.model.setH265(true)
        #expect(rig.model.sessionID == 2)
        #expect(rig.starts.last?.videoCodec == .h265)
        await rig.model.setH265(false)
        #expect(rig.model.sessionID == 3)
        #expect(rig.starts.last?.videoCodec == .h264)
    }

    // MARK: Measure Delay

    /// The phone's DELAY test screen played by the test: white while the finger is down, black
    /// otherwise, shown through the session as decoded pictures.
    @Test func measureDelayRunsThePatternsAndTaps() async throws {
        let rig = Rig()
        let links = try await rig.running()
        rig.model.delayHarness = DelayHarness(trials: 3, timeout: .seconds(2), pause: .zero,
                                              firstBlack: .seconds(2), fpsDuration: .milliseconds(200))
        let session = try #require(rig.model.session)
        let black = try #require(nv12Picture(outer: 16))
        let touches = Recorder<Data>()
        let phone = playDelayScreen(control: links.control.phone, session: session, touches: touches)
        defer { phone.cancel() }
        #expect(rig.model.canMeasureDelay)
        let measuring = Task { await rig.model.measureDelay() }
        try await until("DELAY sent") { rig.sent.of(.mirrorTestPattern, AMMirrorTestPattern.self).count == 1 }
        #expect(rig.model.measuringDelay)
        #expect(!rig.model.canMeasureDelay)
        session.frameShown(black)
        // The frame-rate pattern: a few frames while it is counted.
        try await until("FPS sent") { rig.sent.of(.mirrorTestPattern, AMMirrorTestPattern.self).count == 2 }
        for _ in 0..<4 { session.frameShown(black) }
        let result = try #require(await measuring.value)
        #expect(result.trials == 3)
        #expect(result.misses == 0)
        #expect(result.medianMs >= 0 && result.medianMs < 1_000)
        #expect(result.fpsMean > 0)
        let patterns = rig.sent.of(.mirrorTestPattern, AMMirrorTestPattern.self)
        #expect(patterns.map(\.mode) == [.delay, .fps, .off])
        #expect(patterns.allSatisfy { $0.session == 1 })
        // DOWN and UP at the centre, at the video size, three times.
        try await until("six touches") { touches.count == 6 }
        #expect(touches.all == Array(repeating: [touchDown(160, 320, 320, 640), touchUp(160, 320, 320, 640)], count: 3).flatMap { $0 })
        #expect(!rig.model.measuringDelay)
        #expect(rig.model.phase == .running(width: 320, height: 640))
    }

    /// No black centre within the first wait: every tap counts as missed, no frame count, OFF sent.
    @Test func measureDelayWithoutTheTestScreen() async throws {
        let rig = Rig()
        _ = try await rig.running()
        rig.model.delayHarness = DelayHarness(trials: 5, timeout: .milliseconds(50), pause: .zero,
                                              firstBlack: .milliseconds(100), fpsDuration: .seconds(30))
        let result = try #require(await rig.model.measureDelay())
        #expect(result.trials == 5 && result.misses == 5)
        #expect(result.fpsMean == 0)
        #expect(rig.sent.of(.mirrorTestPattern, AMMirrorTestPattern.self).map(\.mode) == [.delay, .off])
    }

    /// The session ends while measuring: no result, and it returns promptly.
    @Test func measureDelayStopsWhenTheSessionEnds() async throws {
        let rig = Rig()
        _ = try await rig.running()
        rig.model.delayHarness = DelayHarness(trials: 50, timeout: .seconds(3), pause: .milliseconds(500),
                                              firstBlack: .seconds(5), fpsDuration: .seconds(30))
        let started = ContinuousClock.now
        let measuring = Task { await rig.model.measureDelay() }
        try await until("DELAY sent") { rig.sent.of(.mirrorTestPattern, AMMirrorTestPattern.self).count == 1 }
        await rig.phoneStop(1, .user)
        #expect(await measuring.value == nil)
        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(!rig.model.measuringDelay)
    }

    @Test func measureDelayNeedsARunningSession() async throws {
        let rig = Rig()
        await rig.ready()
        await rig.model.start()
        #expect(!rig.model.canMeasureDelay)
        #expect(await rig.model.measureDelay() == nil)
        #expect(rig.sent.of(.mirrorTestPattern, AMMirrorTestPattern.self).isEmpty)
    }

    @Test func delayCopy() {
        let r = DelayResult(medianMs: 61.4, p95Ms: 88.6, minMs: 40, trials: 50, misses: 2, fpsMean: 58.25)
        #expect(MirrorCopy.delayTitle == "Delay")
        #expect(MirrorCopy.delayRoundTrip(r) == "Round trip: median 61 ms, 95th percentile 89 ms, 50 taps (2 missed).")
        #expect(MirrorCopy.delayFrameRate(r).hasPrefix("Frame rate: 58"))
        #expect(MirrorCopy.delayFrameRate(r).hasSuffix(" fps."))
    }
}

/// The phone's DELAY screen behind a control link: each touch DOWN shows a white picture through
/// `session`, each UP a black one. The touches are recorded.
private func playDelayScreen(control: MemoryPipe, session: MirrorSession, touches: Recorder<Data>) -> Task<Void, Never> {
    Task.detached {
        guard let black = nv12Picture(outer: 16), let white = nv12Picture(outer: 235) else { return }
        var bytes = Data()
        var seen = 0
        while let chunk = try? await control.receive(maximum: 1 << 16) {
            bytes += chunk
            let messages = controlMessages(bytes)
            for m in messages.dropFirst(seen) where m.first == 2 {
                touches.append(m)
                session.frameShown(m[1] == 0 ? white : black)
            }
            seen = messages.count
        }
    }
}

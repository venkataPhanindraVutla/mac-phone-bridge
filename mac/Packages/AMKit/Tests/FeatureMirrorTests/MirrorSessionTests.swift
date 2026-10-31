import AMTestSupport
import ConnectionCore
import Foundation
import Testing
@testable import FeatureMirror

/// A link whose sends never complete until it is closed (a stalled phone).
final class StalledPipe: BulkPipe, @unchecked Sendable {
    private let lock = NSLock()
    private var closedFlag = false
    private var waiters: [CheckedContinuation<Void, Error>] = []

    var isClosed: Bool { lock.withLock { closedFlag } }

    func receive(maximum: Int) async throws -> Data? {
        try await park()
        return nil
    }

    func send(_ data: Data) async throws { try await park() }

    func close() {
        let parked: [CheckedContinuation<Void, Error>] = lock.withLock {
            closedFlag = true
            defer { waiters = [] }
            return waiters
        }
        for w in parked { w.resume(throwing: CancellationError()) }
    }

    private func park() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let closed: Bool = lock.withLock {
                if !closedFlag { waiters.append(c) }
                return closedFlag
            }
            if closed { c.resume(throwing: CancellationError()) }
        }
    }
}

@Suite struct MirrorSessionTests {
    /// R45: what was queued before close() is written, then the control link closes; video closes at once.
    @Test func closeDeliversQueuedControlBytesThenCloses() async throws {
        let session = MirrorSession(id: 1, sink: CountingSink(), events: { _ in })
        let (videoMac, _) = MemoryPipe.pair()
        let (controlMac, controlPhone) = MemoryPipe.pair()
        let (audioMac, _) = MemoryPipe.pair()
        session.attach(videoMac, role: .mirrorVideo)
        session.attach(audioMac, role: .mirrorAudio)
        session.attach(controlMac, role: .mirrorControl)
        let up = ScrcpyControl.touch(action: 1, x: 1, y: 2, width: 320, height: 640, pressure: 0)
        session.sendControl(up)
        session.close()
        // Video and audio close at once; only control drains.
        #expect(videoMac.isClosed)
        #expect(audioMac.isClosed)
        // Nothing queued after close() goes out.
        session.sendControl(Data([0xEE]))
        let bytes = try await readAll(controlPhone, 1 << 20)
        #expect(bytes == up)
        #expect(controlMac.isClosed)
    }

    /// A control link that cannot take the bytes is closed at the drain deadline, 200 ms; close()
    /// itself returns at once.
    @Test func stalledControlLinkClosesAtTheDeadline() async throws {
        let fake = FakeResetClock()
        let session = MirrorSession(id: 1, sink: CountingSink(), events: { _ in }, clock: fake.clock)
        let stalled = StalledPipe()
        session.attach(stalled, role: .mirrorControl)
        session.sendControl(Data([2]))
        session.close()
        #expect(!stalled.isClosed)
        #expect(fake.scheduled == 1)
        fake.advance(by: .milliseconds(199))
        #expect(!stalled.isClosed)
        fake.advance(by: .milliseconds(1))
        #expect(stalled.isClosed)
    }

    /// With nothing queued the control link closes as soon as the writer sees the end, not at the deadline.
    @Test func idleControlLinkClosesWithoutWaitingForTheDeadline() async throws {
        let fake = FakeResetClock()
        let session = MirrorSession(id: 1, sink: CountingSink(), events: { _ in }, clock: fake.clock)
        let (controlMac, _) = MemoryPipe.pair()
        session.attach(controlMac, role: .mirrorControl)
        session.close()
        try await until("closed") { controlMac.isClosed }
        #expect(fake.elapsed == .zero)
    }

    /// The lateness half of the backlog rule: a packet more than 500 ms late (LatenessMeter) drops
    /// everything queued up to the next key frame and asks for RESET_VIDEO, once.
    @Test func latePacketDropsToNextKeyFrameAndRequestsReset() async throws {
        let fake = FakeResetClock()
        let events = Recorder<String>()
        let session = MirrorSession(id: 1, sink: CountingSink(), events: { event in
            if case .needsReset = event { events.append("needsReset") }
        }, clock: fake.clock)
        defer { session.close() }
        let pts = Recorder<UInt64>()
        session.onFrameForTesting = { pts.append($0) }
        session.decoder.hold()
        let (mac, phone) = MemoryPipe.pair()
        session.attach(mac, role: .mirrorVideo)
        // The prelude, the size, the config and frames 0...9, all at once (a burst is not late).
        let head = Data([0]) + sampleStream.prefix(68) + sessionBytes(width: 320, height: 640)
        let packets = samplePackets.map { packetBytes(config: $0.config, key: $0.key, pts: $0.pts, payload: $0.payload) }
        try await phone.send(head + packets[0...10].reduce(Data(), +))
        try await until("ten frames parsed") { session.packetsParsed == 11 }
        #expect(events.count == 0)
        #expect(session.decoder.backlog == 10)
        // A second later frames 10...29 arrive (frame 10 was made at 167 ms: about 1 s late).
        // Without the lateness rule they would just queue (20 + 10, not over the backlog of 30).
        fake.advance(by: .seconds(1))
        try await phone.send(packets[11...30].reduce(Data(), +))
        try await until("frames 10...29 parsed") { session.packetsParsed == 31 }
        #expect(events.all == ["needsReset"])
        // Everything queued went, and frames wait for the next key frame.
        #expect(session.decoder.backlog == 0)
        // The key frame at 30 and what follows stay, without another reset.
        try await phone.send(packets[31...].reduce(Data(), +))
        try await until("the stream parsed") { session.packetsParsed == 61 }
        #expect(events.all == ["needsReset"])
        #expect(session.decoder.backlog == 30)
        let sample = session.qualitySample()
        #expect(sample.backlog == 30)
        #expect((sample.medianMs ?? 0) > 400) // ten on-time frames, then 983 ms falling to 167 ms
        session.decoder.release()
        try await until("30 frames") { pts.count == 30 }
        #expect(pts.all.first == 30 * 16_667)
    }

    /// M3: after a lateness drop the bar moves up to that lateness: a link that stays late drops
    /// again only once it is another 500 ms later.
    @Test func lateLinkDropsAgainOnlyAfterAnother500ms() async throws {
        let fake = FakeResetClock()
        let session = MirrorSession(id: 1, sink: CountingSink(), events: { _ in }, clock: fake.clock)
        defer { session.close() }
        session.decoder.hold()
        let (mac, phone) = MemoryPipe.pair()
        session.attach(mac, role: .mirrorVideo)
        try await phone.send(Data([0]) + preludeBytes(name: "x", codec: .h264) + sessionBytes(width: 320, height: 640))
        var parsed = 0
        func frame(_ i: Int, lateMs: Int64, key: Bool = true) async throws {
            let pts = UInt64(i) * 16_667
            let target = Duration.microseconds(Int64(pts) + lateMs * 1_000)
            if target > fake.elapsed { fake.advance(by: target - fake.elapsed) }
            try await phone.send(packetBytes(key: key, pts: pts, payload: Data([0, 0, 0, 1, 0x65])))
            parsed += 1
            try await until("frame \(i)") { session.packetsParsed == parsed }
        }
        for i in 0..<10 { try await frame(i, lateMs: 0, key: i == 0) }
        #expect(session.decoder.backlog == 10)
        // 600 ms late: everything queued is dropped (the bar is now 600).
        try await frame(10, lateMs: 600, key: false)
        #expect(session.decoder.backlog == 0)
        // 900 ms late, all key frames: 300 over the bar, so nothing more is dropped.
        for i in 11...20 { try await frame(i, lateMs: 900) }
        #expect(session.decoder.backlog == 10)
        // 1200 ms: 600 over the bar, dropped again (to the newest key frame, 20).
        try await frame(21, lateMs: 1_200, key: false)
        #expect(session.decoder.backlog == 2)
    }

    /// I1: RESET_VIDEO restarts the phone's encoder, which sends a session packet; its PTS go on.
    /// The lateness is not forgotten there: on a link that stays late, the 5 s median stays over
    /// 150 ms across the session packets, and Auto steps down after five late seconds.
    @Test func latenessSurvivesTheSessionPacketAfterAReset() async throws {
        let fake = FakeResetClock()
        let resets = Recorder<Duration>()
        let session = MirrorSession(id: 1, sink: CountingSink(), events: { event in
            if case .needsReset = event { resets.append(fake.elapsed) }
        }, clock: fake.clock)
        defer { session.close() }
        let (mac, phone) = MemoryPipe.pair()
        session.attach(mac, role: .mirrorVideo)
        try await phone.send(Data([0]) + preludeBytes(name: "x", codec: .h264) + sessionBytes(width: 320, height: 640))
        var controller = QualityController()
        var medians: [Double?] = []
        var stepDownAt: Int?
        var sessionPackets = 0
        var firstSessionPacketTick: Int?
        var resetsAnswered = 0
        var nextTick = 1
        for i in 0..<900 where stepDownAt == nil {
            // Frames arrive 35% slower than they are made: 350 ms later every second.
            let pts = UInt64(i) * 16_667
            let arrival = Duration.microseconds(Int64(Double(pts) * 1.35))
            while .seconds(nextTick) <= arrival, stepDownAt == nil {
                fake.advance(by: .seconds(nextTick) - fake.elapsed)
                let sample = session.qualitySample()
                medians.append(sample.medianMs)
                if controller.tick(medianMs: sample.medianMs, backlog: sample.backlog, now: fake.clock.now()) == .switchTo(.balanced) {
                    stepDownAt = nextTick
                }
                nextTick += 1
            }
            guard stepDownAt == nil else { break }
            fake.advance(by: arrival - fake.elapsed)
            var bytes = Data()
            var key = i == 0
            if resets.count > resetsAnswered {
                // The phone's encoder restarted: a session packet, then a key frame.
                resetsAnswered = resets.count
                bytes += sessionBytes(width: 320, height: 640)
                sessionPackets += 1
                firstSessionPacketTick = firstSessionPacketTick ?? nextTick
                key = true
            }
            bytes += packetBytes(key: key, pts: pts, payload: Data([0, 0, 0, 1, 0x65]))
            try await phone.send(bytes)
            try await until("frame \(i)") { session.packetsParsed == i + 1 }
        }
        #expect(sessionPackets >= 1)
        let after = try #require(firstSessionPacketTick)
        #expect(after < (stepDownAt ?? 0))
        // Over 150 ms from the second tick on, through every session packet.
        #expect(medians.dropFirst(1).allSatisfy { ($0 ?? 0) > 150 }, "\(medians)")
        #expect(stepDownAt == 6, "\(medians)")
    }

    /// I1 with a link model: High (8 Mbit/s, 60 fps, a key frame of 5 frames' size after each
    /// RESET_VIDEO, the encoder restart taking 70 ms) through a FIFO link of 6 or 7 Mbit/s. Auto
    /// steps down while less than R54's 4 MB is queued on the way, so LINK_SLOW doesn't end it first.
    @Test(arguments: [6_000_000.0, 7_000_000.0])
    func autoStepsDownBeforeTheLinkSlowBacklog(capacity: Double) async throws {
        let run = try await LinkModel(capacityBitsPerSecond: capacity).run(seconds: 20)
        let at = try #require(run.stepDownAt, "no step down in 20 s; medians \(run.medians)")
        #expect(at <= 10, "\(run.medians)")
        #expect(run.queuedBytesAtStepDown < 4 * 1_048_576)
        #expect(run.resets >= 1)
    }


    /// A link attached after close() is closed at once.
    @Test func linkAfterCloseIsClosed() {
        let session = MirrorSession(id: 1, sink: CountingSink(), events: { _ in })
        session.close()
        let (controlMac, _) = MemoryPipe.pair()
        session.attach(controlMac, role: .mirrorControl)
        #expect(controlMac.isClosed)
    }
    /// A failing decoder ends the audio path after 50 packets in a row with no sound.
    @Test func decodeFailuresEndTheAudioPathOnly() async throws {
        let ended = Recorder<Bool>()
        let session = MirrorSession(id: 1, sink: CountingSink(), events: { event in
            if case .audioEnded = event { ended.append(true) }
        })
        let (audioMac, audioPhone) = MemoryPipe.pair()
        session.attach(audioMac, role: .mirrorAudio)
        var stream = try #require(streamVector("audio_prelude_aac")).bytes
        stream += packetBytes(config: true, pts: 0, payload: TestAudioEncoder.aacConfig)
        for i in 0..<MirrorSession.maxAudioDecodeFailures {
            stream += packetBytes(pts: UInt64(i), payload: Data([0xFF, 0xFF, 0xFF, UInt8(i)]))
        }
        try await audioPhone.send(stream)
        try await until("audio ended") { ended.count == 1 }
        #expect(session.audioBuffersDecoded == 0)
        #expect(!audioMac.isClosed)
        session.close()
    }

    /// An audio stream the Mac can't play (here a video codec ID) ends the audio path only: the
    /// session says so and keeps the link open, drained, so the phone sees no failure.
    @Test func unsupportedAudioCodecEndsTheAudioPathOnly() async throws {
        let events = Recorder<String>()
        let session = MirrorSession(id: 1, sink: CountingSink(), events: { event in
            if case .audioEnded = event { events.append("audioEnded") }
            if case let .linkEnded(role) = event { events.append("linkEnded \(role)") }
        })
        let (audioMac, audioPhone) = MemoryPipe.pair()
        session.attach(audioMac, role: .mirrorAudio)
        try await audioPhone.send(Data([0x68, 0x32, 0x36, 0x34]) + packetBytes(pts: 0, payload: Data([1, 2, 3])))
        try await until("audio ended") { events.all == ["audioEnded"] }
        #expect(!audioMac.isClosed)
        // More bytes are drained; the end of the link is still reported.
        try await audioPhone.send(Data(repeating: 7, count: 100))
        audioPhone.close()
        try await until("link ended") { events.all == ["audioEnded", "linkEnded mirrorAudio"] }
        session.close()
    }
}

/// A phone encoder at High through a FIFO link into a real session on a fake clock, with Auto
/// evaluated every simulated second from the session's quality sample (Task 9 review I1).
private struct LinkModel {
    var capacityBitsPerSecond: Double
    var bitRate = 8_000_000.0
    var fps = 60.0
    /// A key frame is this many frames' size.
    var keyFactor = 5
    /// RESET_VIDEO reaches the phone after this; the encoder is back this much after that.
    var controlDelay: Duration = .milliseconds(10)
    var restart: Duration = .milliseconds(60)

    struct Result {
        var stepDownAt: Int?
        var queuedBytesAtStepDown = 0
        var resets = 0
        var medians: [Double?] = []
    }

    private struct InFlight {
        var arrival: Duration
        var bytes: Data
        var size: Int
    }

    func run(seconds: Int) async throws -> Result {
        let fake = FakeResetClock()
        let resets = Recorder<Duration>()
        let session = MirrorSession(id: 1, sink: CountingSink(), events: { event in
            if case .needsReset = event { resets.append(fake.elapsed) }
        }, clock: fake.clock)
        defer { session.close() }
        let (mac, phone) = MemoryPipe.pair()
        session.attach(mac, role: .mirrorVideo)
        try await phone.send(Data([0]) + preludeBytes(name: "x", codec: .h264) + sessionBytes(width: 1080, height: 1920))

        var result = Result()
        var controller = QualityController()
        var queue: [InFlight] = []
        var linkFree = Duration.zero
        var frame = 0
        var parsed = 0
        var resetsApplied = 0
        var restartAt: Duration?
        var nextTick = Duration.seconds(1)
        let frameBytes = Int(bitRate / fps / 8)
        let end = Duration.seconds(seconds)
        func ms(_ d: Duration) -> Double { LatenessMeter.ms(d) }

        while result.stepDownAt == nil, nextTick <= end {
            let generate = Duration.microseconds(Int64(Double(frame) * 1_000_000 / fps))
            let arrive = queue.first?.arrival ?? .seconds(10_000)
            if nextTick <= generate, nextTick <= arrive {
                fake.advance(by: nextTick - fake.elapsed)
                let sample = session.qualitySample()
                result.medians.append(sample.medianMs)
                if case .switchTo = controller.tick(medianMs: sample.medianMs, backlog: sample.backlog, now: fake.clock.now()) {
                    result.stepDownAt = Int(nextTick.components.seconds)
                    result.queuedBytesAtStepDown = queue.reduce(0) { $0 + $1.size }
                }
                nextTick += .seconds(1)
            } else if generate <= arrive {
                // A RESET_VIDEO the phone has had by now restarts the encoder.
                let heard = resets.all.filter { $0 + controlDelay <= generate }.count
                if heard > resetsApplied {
                    resetsApplied = heard
                    restartAt = resets.all[heard - 1] + controlDelay + restart
                }
                defer { frame += 1 }
                if let at = restartAt, generate < at { continue } // the encoder is restarting
                var bytes = Data()
                var size = frameBytes
                var key = frame == 0
                if restartAt != nil {
                    restartAt = nil
                    bytes += sessionBytes(width: 1080, height: 1920)
                    key = true
                }
                if key { size *= keyFactor }
                bytes += packetBytes(key: key, pts: UInt64(ms(generate) * 1_000), payload: Data(count: size))
                let start = max(generate, linkFree)
                linkFree = start + .microseconds(Int64(Double(bytes.count) * 8 / capacityBitsPerSecond * 1_000_000))
                queue.append(InFlight(arrival: linkFree, bytes: bytes, size: bytes.count))
            } else {
                let next = queue.removeFirst()
                if next.arrival > fake.elapsed { fake.advance(by: next.arrival - fake.elapsed) }
                try await phone.send(next.bytes)
                parsed += 1
                let want = parsed
                try await until("packet \(want)") { session.packetsParsed == want }
            }
        }
        result.resets = resets.count
        return result
    }
}

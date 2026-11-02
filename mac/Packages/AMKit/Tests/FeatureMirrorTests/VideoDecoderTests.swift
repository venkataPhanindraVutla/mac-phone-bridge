import AMProtocol
import AMTestSupport
import CoreMedia
import Foundation
import Testing
@testable import FeatureMirror

@MainActor
@Suite struct VideoDecoderTests {
    @Test func sampleDecodesSixtyFrames() async throws {
        let sink = CountingSink()
        let pts = Recorder<UInt64>()
        let decoder = VideoDecoder(sink: sink, onFrame: { pts.append($0) })
        defer { decoder.invalidate() }
        for p in samplePackets { decoder.decode(p, codec: .h264) }
        try await until("60 frames") { pts.count == 60 }
        #expect(pts.all == (0..<60).map { UInt64($0) * 16_667 })
        #expect(sink.shown == 60)
        #expect(sink.lastSize?.width == 320 && sink.lastSize?.height == 640)
        // Frames reach the sink on the decoder's side, never on the main thread.
        #expect(sink.allOffMain)
        try await until("backlog drained") { decoder.backlog == 0 }
        #expect(decoder.decodeErrors == 0)
    }

    @Test func framesBeforeAnyConfigAreDropped() async throws {
        let sink = CountingSink()
        let decoder = VideoDecoder(sink: sink, onFrame: { _ in })
        defer { decoder.invalidate() }
        for p in samplePackets.dropFirst() { decoder.decode(p, codec: .h264) }
        try await until("backlog drained") { decoder.backlog == 0 }
        #expect(sink.shown == 0)
        #expect(decoder.sessionsCreated == 0)
    }

    @Test func parameterSetChangeRebuildsDecoder() async throws {
        let sink = CountingSink()
        let pts = Recorder<UInt64>()
        let decoder = VideoDecoder(sink: sink, onFrame: { pts.append($0) })
        defer { decoder.invalidate() }
        // The sample twice, the second with its own (identical) config: one decoder serves both.
        for p in samplePackets + samplePackets { decoder.decode(p, codec: .h264) }
        try await until("120 frames") { pts.count == 120 }
        #expect(decoder.sessionsCreated == 1)
        #expect(sink.lastSize?.width == 320 && sink.lastSize?.height == 640)

        // A stream with other parameter sets (another size) rebuilds it.
        let other = try #require(TestEncoder.encode(kCMVideoCodecType_H264, width: 160, height: 320, count: 10))
        for p in other { decoder.decode(p, codec: .h264) }
        try await until("130 frames") { pts.count == 130 }
        #expect(decoder.sessionsCreated == 2)
        #expect(sink.lastSize?.width == 160 && sink.lastSize?.height == 320)
        #expect(decoder.decodeErrors == 0)
    }

    @Test func dropUntilKeyFrameKeepsTheNewestQueuedKeyFrame() async throws {
        let sink = CountingSink()
        let pts = Recorder<UInt64>()
        let decoder = VideoDecoder(sink: sink, onFrame: { pts.append($0) })
        defer { decoder.invalidate() }
        decoder.hold()
        for p in samplePackets.prefix(42) { decoder.decode(p, codec: .h264) } // config + frames 0...40
        #expect(decoder.backlog == 41)
        decoder.dropUntilKeyFrame()
        #expect(decoder.backlog == 11) // frames 30...40
        decoder.release()
        try await until("11 frames") { pts.count == 11 }
        #expect(pts.all.first == 30 * 16_667)
    }

    @Test func dropUntilKeyFrameWithNoKeyQueuedWaitsForTheNextOne() async throws {
        let sink = CountingSink()
        let pts = Recorder<UInt64>()
        let decoder = VideoDecoder(sink: sink, onFrame: { pts.append($0) })
        defer { decoder.invalidate() }
        decoder.hold()
        for p in samplePackets.prefix(21) { decoder.decode(p, codec: .h264) } // config + frames 0...19
        // Frame 0, the only key frame queued, is the oldest: dropping before it would drop nothing,
        // so everything goes and frames are dropped as they come until the next key frame.
        decoder.dropUntilKeyFrame()
        #expect(decoder.backlog == 0)
        for p in samplePackets[21...60] { decoder.decode(p, codec: .h264) } // frames 20...59
        #expect(decoder.backlog == 30) // frames 30...59
        decoder.release()
        try await until("30 frames") { pts.count == 30 }
        #expect(pts.all == (30..<60).map { UInt64($0) * 16_667 })
    }

    /// The session's backlog rule: decoder held, more than 30 packets queued → drop to the next key
    /// frame and ask for a reset, once.
    @Test func backlogDropsToNextKeyframeAndRequestsReset() async throws {
        let sink = CountingSink()
        let events = Recorder<String>()
        let session = MirrorSession(id: 1, sink: sink, events: { events.append(Self.name($0)) })
        defer { session.close() }
        let pts = Recorder<UInt64>()
        session.onFrameForTesting = { pts.append($0) }
        session.decoder.hold()
        let (mac, phone) = MemoryPipe.pair()
        session.attach(mac, role: .mirrorVideo)
        try await phone.send(sampleWithDummyByte)
        // Everything parsed: frames 30...59 are left once the drop has happened.
        try await until("the stream parsed") { session.packetsParsed == 61 }
        #expect(session.decoder.backlog == 30)
        #expect(events.all.filter { $0 == "needsReset" }.count == 1)
        session.decoder.release()
        try await until("30 frames") { pts.count == 30 }
        #expect(pts.all.first == 30 * 16_667)
        #expect(events.all.filter { $0 == "needsReset" }.count == 1)
        #expect(events.all.contains("firstFrame"))
    }

    @Test func throttledResetRequestIsDeferredToTheWindowsEnd() {
        let fake = FakeResetClock()
        let resets = Recorder<Duration>()
        let session = MirrorSession(id: 1, sink: CountingSink(), events: { event in
            if case .needsReset = event { resets.append(fake.elapsed) }
        }, clock: fake.clock)
        defer { session.close() }
        session.requestReset()
        #expect(resets.all == [.zero])
        fake.advance(by: .milliseconds(100))
        session.requestReset()
        // Not dropped: one reset is scheduled for the end of the 1 s window.
        #expect(resets.count == 1)
        #expect(fake.scheduled == 1)
        fake.advance(by: .milliseconds(899))
        #expect(resets.count == 1)
        fake.advance(by: .milliseconds(1))
        #expect(resets.all == [.zero, .seconds(1)])
    }

    @Test func requestsInsideTheWindowJoinOneDeferredReset() {
        let fake = FakeResetClock()
        let resets = Recorder<Duration>()
        let session = MirrorSession(id: 1, sink: CountingSink(), events: { event in
            if case .needsReset = event { resets.append(fake.elapsed) }
        }, clock: fake.clock)
        defer { session.close() }
        session.requestReset()
        for _ in 0..<3 {
            fake.advance(by: .milliseconds(100))
            session.requestReset()
        }
        #expect(fake.scheduled == 1)
        fake.advance(by: .milliseconds(700)) // t = 1 s: the one deferred reset
        #expect(resets.all == [.zero, .seconds(1)])
        // The deferred reset opened a new window: a request right after it waits for that window's end.
        session.requestReset()
        #expect(resets.count == 2)
        fake.advance(by: .seconds(1))
        #expect(resets.all == [.zero, .seconds(1), .seconds(2)])
        // Long after, a request goes at once.
        fake.advance(by: .seconds(5))
        session.requestReset()
        #expect(resets.all == [.zero, .seconds(1), .seconds(2), .seconds(7)])
    }

    @Test func resetsAfterCloseAreNotReported() {
        let fake = FakeResetClock()
        let resets = Recorder<Duration>()
        let session = MirrorSession(id: 1, sink: CountingSink(), events: { event in
            if case .needsReset = event { resets.append(fake.elapsed) }
        }, clock: fake.clock)
        session.requestReset()
        session.requestReset()
        session.close()
        fake.advance(by: .seconds(2))
        #expect(resets.count == 1)
    }

    /// A frame VideoToolbox can't decode: counted, the key frame hook fires, and frames are
    /// skipped until the next key frame.
    ///
    /// On a loaded machine (every suite in one process) VideoToolbox has once failed a good frame
    /// too; the decoder then rightly skips again, to a key frame this sample does not have. Such a
    /// run proves nothing either way, so it is tried again, at most three times.
    @Test func decodeErrorSkipsToTheNextKeyFrameAndAsksForOne() async throws {
        for attempt in 1...3 {
            let sink = CountingSink()
            let pts = Recorder<UInt64>()
            let needed = Recorder<Bool>()
            let decoder = VideoDecoder(sink: sink, onFrame: { pts.append($0) })
            decoder.onKeyFrameNeeded = { needed.append(true) }
            defer { decoder.invalidate() }
            // Config and key frame 0, then a frame whose slice data is garbage.
            decoder.decode(samplePackets[0], codec: .h264)
            decoder.decode(samplePackets[1], codec: .h264)
            try await until("frame 0") { pts.count == 1 }
            var garbage = Data([0, 0, 0, 1, 0x41])
            garbage.append(Data(repeating: 0xFF, count: 64))
            decoder.decode(MediaPacket(config: false, key: false, pts: 1, payload: garbage), codec: .h264)
            try await until("the error") { decoder.decodeErrors == 1 }
            #expect(needed.count == 1)
            // Frames 1...29 are skipped; key frame 30 and the rest decode.
            for p in samplePackets[2...60] { decoder.decode(p, codec: .h264) }
            try await until("backlog drained") { decoder.backlog == 0 }
            try await until("frames 30...59, or another error") { pts.count == 31 || decoder.decodeErrors > 1 }
            if decoder.decodeErrors > 1, attempt < 3 { continue }
            #expect(Array(pts.all.dropFirst()) == (30..<60).map { UInt64($0) * 16_667 })
            #expect(decoder.decodeErrors == 1)
            return
        }
    }

    nonisolated private static func name(_ e: MirrorSessionEvent) -> String {
        switch e {
        case .firstFrame: "firstFrame"
        case let .size(w, h): "size \(w)x\(h)"
        case let .linkEnded(role): "linkEnded \(role)"
        case .needsReset: "needsReset"
        case .audioEnded: "audioEnded"
        case .clipboard: "clipboard"
        }
    }
}

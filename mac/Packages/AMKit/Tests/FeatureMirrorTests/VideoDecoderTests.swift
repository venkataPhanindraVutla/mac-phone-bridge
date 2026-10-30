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

    nonisolated private static func name(_ e: MirrorSessionEvent) -> String {
        switch e {
        case .firstFrame: "firstFrame"
        case let .size(w, h): "size \(w)x\(h)"
        case let .linkEnded(role): "linkEnded \(role)"
        case .needsReset: "needsReset"
        }
    }
}

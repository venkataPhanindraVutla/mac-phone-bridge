import AMTestSupport
import Foundation
import Testing
@testable import FeatureMirror

@Suite struct VideoStreamParserTests {
    /// Pins the committed sample: its prelude, its size, 60 frames, key frames 0 and 30, PTS i × 16,667 µs.
    @Test func sampleParsesToSixtyPacketsAndOneSession() throws {
        var parser = VideoStreamParser(expectDummyByte: false)
        let events = try parser.push(sampleStream)
        #expect(events.first == .deviceName("phone-sim"))
        #expect(events.dropFirst().first == .codec(ScrcpyCodec.h264.rawValue))
        let sessions = events.filter { if case .session = $0 { true } else { false } }
        #expect(sessions == [.session(width: 320, height: 640)])
        let packets = events.compactMap { if case let .packet(p) = $0 { p } else { nil } }
        let configs = packets.filter(\.config)
        let frames = packets.filter { !$0.config }
        #expect(configs.count == 1)
        #expect(packets.first?.config == true)
        #expect(frames.count == 60)
        #expect(frames.indices.filter { frames[$0].key } == [0, 30])
        for (i, frame) in frames.enumerated() {
            #expect(frame.pts == UInt64(i) * 16_667)
        }
        // The config packet holds the SPS and the PPS, in Annex B.
        let nals = ParameterSets.splitAnnexB(try #require(configs.first).payload)
        #expect(nals.map { $0[0] & 0x1F } == [7, 8])
    }

    @Test func oneByteChunksGiveSameEvents() throws {
        var whole = VideoStreamParser()
        let expected = try whole.push(sampleWithDummyByte)
        var parser = VideoStreamParser()
        var events: [VideoEvent] = []
        for byte in sampleWithDummyByte { events += try parser.push(Data([byte])) }
        #expect(events == expected)
        #expect(events.count == 3 + 61)

        // And chunks of odd sizes across every boundary.
        var odd = VideoStreamParser()
        var oddEvents: [VideoEvent] = []
        var i = 0, step = 1
        while i < sampleWithDummyByte.count {
            let end = min(i + step, sampleWithDummyByte.count)
            oddEvents += try odd.push(sampleWithDummyByte.subdata(in: i..<end))
            i = end
            step = step % 97 + 13
        }
        #expect(oddEvents == expected)
    }

    @Test func dummyByteIsSkippedWhenExpected() throws {
        var parser = VideoStreamParser()
        let events = try parser.push(Data([0]) + preludeBytes(name: "Ana’s phone 📱", codec: .h265))
        #expect(events == [.deviceName("Ana’s phone 📱"), .codec(ScrcpyCodec.h265.rawValue)])
    }

    @Test func configAndKeyFlagsAndPts() throws {
        var parser = VideoStreamParser(expectDummyByte: false)
        var stream = preludeBytes(name: "p", codec: .h264)
        stream += sessionBytes(width: 1080, height: 2400)
        stream += packetBytes(config: true, pts: 0, payload: Data([0, 0, 0, 1, 0x67]))
        stream += packetBytes(key: true, pts: 16_667, payload: Data([0, 0, 0, 1, 0x65, 1]))
        stream += packetBytes(pts: 5_000_000_000, payload: Data([0, 0, 1, 0x41, 2, 3]))
        let events = try parser.push(stream)
        #expect(events == [
            .deviceName("p"), .codec(ScrcpyCodec.h264.rawValue), .session(width: 1080, height: 2400),
            .packet(MediaPacket(config: true, key: false, pts: 0, payload: Data([0, 0, 0, 1, 0x67]))),
            .packet(MediaPacket(config: false, key: true, pts: 16_667, payload: Data([0, 0, 0, 1, 0x65, 1]))),
            .packet(MediaPacket(config: false, key: false, pts: 5_000_000_000, payload: Data([0, 0, 1, 0x41, 2, 3]))),
        ])
    }

    /// The headers in `scrcpy.json`'s `stream` fixtures.
    @Test func fixtureHeadersParse() throws {
        var parser = VideoStreamParser()
        let prelude = Data(hexString: "0070686f6e652d73696d" + String(repeating: "00", count: 55) + "68323634")
        var events = try parser.push(prelude)
        #expect(events == [.deviceName("phone-sim"), .codec(0x6832_3634)])
        events = try parser.push(Data(hexString: "800000000000043800000960"))
        #expect(events == [.session(width: 1080, height: 2400)])
        events = try parser.push(Data(hexString: "200000000000411b000005dc") + Data(count: 1500))
        #expect(events == [.packet(MediaPacket(config: false, key: true, pts: 16_667, payload: Data(count: 1500)))])
        events = try parser.push(Data(hexString: "000000012a05f2000000012c") + Data(count: 300))
        #expect(events == [.packet(MediaPacket(config: false, key: false, pts: 5_000_000_000, payload: Data(count: 300)))])
    }

    @Test func oversizedPacketThrows() throws {
        var parser = VideoStreamParser(expectDummyByte: false)
        _ = try parser.push(preludeBytes(name: "p", codec: .h264))
        // Exactly 16 MiB is allowed (its header alone gives nothing yet); one byte more throws.
        var ok = VideoStreamParser(expectDummyByte: false)
        _ = try ok.push(preludeBytes(name: "p", codec: .h264))
        #expect(try ok.push(header(size: 16 << 20)).isEmpty)
        #expect(throws: ScrcpyStreamError.packetTooLarge((16 << 20) + 1)) {
            try parser.push(header(size: (16 << 20) + 1))
        }
    }

    private func header(size: UInt32) -> Data {
        var d = Data(count: 8)
        withUnsafeBytes(of: size.bigEndian) { d.append(contentsOf: $0) }
        return d
    }
}

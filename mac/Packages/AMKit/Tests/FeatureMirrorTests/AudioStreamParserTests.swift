import Foundation
import Testing
@testable import FeatureMirror

/// The `stream` entries in `scrcpy.json`.
nonisolated(unsafe) let streamVectors: [[String: Any]] = scrcpyVectors["stream"] as? [[String: Any]] ?? []

/// The named stream entry's fields and bytes.
func streamVector(_ name: String) -> (fields: [String: Any], bytes: Data)? {
    guard let entry = streamVectors.first(where: { $0["name"] as? String == name }),
          let fields = entry["fields"] as? [String: Any], let hex = entry["hex"] as? String else { return nil }
    return (fields, Data(hex: hex))
}

/// An OpusHead (RFC 7845): what scrcpy sends as the Opus config packet. 48 kHz, stereo.
let opusHead = Data("OpusHead".utf8) + Data([1, 2, 0x38, 0x01, 0x80, 0xBB, 0, 0, 0, 0, 0])

@Suite struct AudioStreamParserTests {
    /// The audio preludes in `scrcpy.json`, then a config packet and a frame.
    @Test func audioCodecHeaderParsed() throws {
        for (name, codec) in [("audio_prelude_opus", ScrcpyCodec.opus), ("audio_prelude_aac", .aac)] {
            let vector = try #require(streamVector(name), "missing \(name)")
            #expect(vector.fields["codec_id"] as? Int == Int(codec.rawValue))
            var parser = AudioStreamParser()
            #expect(try parser.push(vector.bytes) == [.codec(codec.rawValue)])
        }

        // The fixtures' packet headers carry audio packets too (scrcpy uses one header for both).
        let config = try #require(streamVector("config_packet_header"))
        let plain = try #require(streamVector("plain_packet_header"))
        let configPayload = Data((0..<27).map { UInt8($0) })
        let framePayload = Data(repeating: 0xA5, count: 300)
        var parser = AudioStreamParser()
        let events = try parser.push(try #require(streamVector("audio_prelude_opus")).bytes
            + config.bytes + configPayload + plain.bytes + framePayload)
        #expect(events == [
            .codec(ScrcpyCodec.opus.rawValue),
            .packet(MediaPacket(config: true, key: false, pts: 0, payload: configPayload)),
            .packet(MediaPacket(config: false, key: false, pts: 5_000_000_000, payload: framePayload)),
        ])
    }

    @Test func codecZeroIsUnavailable() throws {
        let vector = try #require(streamVector("audio_prelude_disabled"))
        #expect(vector.fields["codec_id"] as? Int == 0)
        var parser = AudioStreamParser()
        #expect(try parser.push(vector.bytes) == [.unavailable])
        // Nothing follows an unavailable stream; stray bytes are ignored.
        #expect(try parser.push(packetBytes(pts: 1, payload: Data([1, 2, 3]))) == [])
    }

    @Test func codecOneIsFailed() throws {
        let vector = try #require(streamVector("audio_prelude_error"))
        #expect(vector.fields["codec_id"] as? Int == 1)
        var parser = AudioStreamParser()
        #expect(try parser.push(vector.bytes) == [.failed])
        #expect(try parser.push(Data(repeating: 0, count: 40)) == [])
    }

    @Test func audioPacketsSplitAcrossChunks() throws {
        var stream = try #require(streamVector("audio_prelude_aac")).bytes
        stream += packetBytes(config: true, pts: 0, payload: Data([0x11, 0x90]))
        for i in 0..<20 {
            stream += packetBytes(pts: UInt64(i) * 21_333, payload: Data((0..<(100 + i * 7)).map { UInt8(($0 + i) % 256) }))
        }
        var whole = AudioStreamParser()
        let expected = try whole.push(stream)
        #expect(expected.count == 1 + 1 + 20)
        #expect(expected.first == .codec(ScrcpyCodec.aac.rawValue))

        var bytewise = AudioStreamParser()
        var events: [AudioEvent] = []
        for byte in stream { events += try bytewise.push(Data([byte])) }
        #expect(events == expected)

        var odd = AudioStreamParser()
        var oddEvents: [AudioEvent] = []
        var i = 0, step = 1
        while i < stream.count {
            let end = min(i + step, stream.count)
            oddEvents += try odd.push(stream.subdata(in: i..<end))
            i = end
            step = step % 89 + 11
        }
        #expect(oddEvents == expected)
    }

    @Test func oversizedAudioPacketThrows() throws {
        var parser = AudioStreamParser()
        var stream = try #require(streamVector("audio_prelude_opus")).bytes
        var head = Data(count: 8)
        withUnsafeBytes(of: UInt32(VideoStreamParser.maxPayloadBytes + 1).bigEndian) { head.append(contentsOf: $0) }
        stream += head
        #expect(throws: ScrcpyStreamError.packetTooLarge(VideoStreamParser.maxPayloadBytes + 1)) { try parser.push(stream) }
    }

    /// The audio socket has no session packets: one there is a broken stream.
    @Test func sessionPacketOnAudioThrows() throws {
        var parser = AudioStreamParser()
        let stream = try #require(streamVector("audio_prelude_opus")).bytes + sessionBytes(width: 1080, height: 2400)
        #expect(throws: ScrcpyStreamError.unexpectedSessionPacket) { try parser.push(stream) }
    }
}

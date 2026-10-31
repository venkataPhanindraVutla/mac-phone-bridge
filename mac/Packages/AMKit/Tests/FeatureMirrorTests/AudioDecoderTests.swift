import AudioToolbox
import AVFoundation
import Foundation
import Testing
@testable import FeatureMirror

@Suite struct AudioDecoderTests {
    @Test func supportsOnlyAudioCodecs() {
        #expect(!AudioDecoder.supports(.h264))
        #expect(!AudioDecoder.supports(.h265))
        // AAC is the fallback: every Mac decodes it.
        #expect(AudioDecoder.supports(.aac))
    }

    /// 100 ms of a 1 kHz sine, encoded to AAC at test time, decodes with the AudioSpecificConfig
    /// the phone sends as its config packet; the RMS of the sound is within 20%.
    @Test func aacRoundTripDecodes() throws {
        let packets = try #require(TestAudioEncoder.encode(.aac, sine: sine1kHz))
        let decoder = try AudioDecoder(codec: .aac, config: TestAudioEncoder.aacConfig)
        let decoded = decodeAll(decoder, packets)
        try checkSine(decoded)
    }

    @Test(.enabled(if: AudioDecoder.supports(.opus)))
    func opusRoundTripDecodesWhenSupported() throws {
        let packets = try #require(TestAudioEncoder.encode(.opus, sine: sine1kHz))
        let decoder = try AudioDecoder(codec: .opus, config: opusHead)
        let decoded = decodeAll(decoder, packets)
        try checkSine(decoded)
    }

    @Test func decodedBuffersAreFloat48kStereo() throws {
        let packets = try #require(TestAudioEncoder.encode(.aac, sine: sine1kHz))
        let decoder = try AudioDecoder(codec: .aac, config: TestAudioEncoder.aacConfig)
        let buffers = packets.compactMap { decoder.decode($0) }
        #expect(!buffers.isEmpty)
        for buffer in buffers {
            #expect(buffer.format.commonFormat == .pcmFormatFloat32)
            #expect(buffer.format.sampleRate == 48_000)
            #expect(buffer.format.channelCount == 2)
            #expect(buffer.frameLength > 0)
        }
    }

    @Test func garbageDoesNotCrash() throws {
        let decoder = try AudioDecoder(codec: .aac, config: TestAudioEncoder.aacConfig)
        _ = decoder.decode(Data())
        _ = decoder.decode(Data(repeating: 0xFF, count: 7))
        _ = decoder.decode(Data((0..<400).map { UInt8($0 % 251) }))
        // Still decodes real packets afterwards.
        let packets = try #require(TestAudioEncoder.encode(.aac, sine: sine1kHz))
        #expect(packets.contains { decoder.decode($0) != nil })
    }

    /// The AAC cookie: the AudioSpecificConfig inside an MPEG-4 ES descriptor.
    @Test func aacConfigIsWrappedInAnEsDescriptor() {
        #expect(AudioDecoder.esds(audioSpecificConfig: Data([0x11, 0x90])).hex
            == "031900000004114015000000000000000000000005021190060102")
        #expect(AudioDecoder.esds(audioSpecificConfig: Data()).isEmpty)
        let already = Data([0x03, 0x01, 0x00])
        #expect(AudioDecoder.esds(audioSpecificConfig: already) == already)
    }

    /// The config the phone sends is taken as the cookie; a refused one is reported, and the
    /// format alone still decodes.
    @Test func cookieStatusIsReported() throws {
        let good = try AudioDecoder(codec: .aac, config: TestAudioEncoder.aacConfig)
        #expect(good.cookieStatus == noErr)
        #expect(try AudioDecoder(codec: .aac, config: Data()).cookieStatus == noErr)
        #expect(try AudioDecoder(codec: .opus, config: opusHead).cookieStatus == noErr || !AudioDecoder.supports(.opus))
        let refused = try AudioDecoder(codec: .aac, config: Data([0x03, 0x01, 0x00]))
        #expect(refused.cookieStatus != noErr)
        let packets = try #require(TestAudioEncoder.encode(.aac, sine: sine1kHz))
        #expect(packets.contains { refused.decode($0) != nil })
    }

    /// A healthy stream decodes nearly every packet: the codec's start-up costs a packet or two,
    /// far below the 50 in a row that end the audio path.
    @Test func healthyStreamsRarelyDecodeToNothing() throws {
        var codecs: [ScrcpyCodec] = [.aac]
        if AudioDecoder.supports(.opus) { codecs.append(.opus) }
        for codec in codecs {
            let packets = try #require(TestAudioEncoder.encode(codec, sine: sine1kHz))
            let decoder = try AudioDecoder(codec: codec, config: codec == .aac ? TestAudioEncoder.aacConfig : opusHead)
            let empty = packets.filter { decoder.decode($0) == nil }.count
            #expect(empty <= 2, "\(codec): \(empty) of \(packets.count) decoded to nothing")
        }
    }

    /// Packets that are not audio decode to nothing (and are counted by the session).
    @Test func garbagePacketsDecodeToNothing() throws {
        let decoder = try AudioDecoder(codec: .aac, config: TestAudioEncoder.aacConfig)
        let decoded = (0..<60).filter { decoder.decode(Data([0xFF, 0xFF, 0xFF, UInt8($0)])) != nil }.count
        #expect(decoded == 0)
    }

    @Test func videoCodecIsRefused() {
        #expect(throws: AudioDecoderError.self) { try AudioDecoder(codec: .h264, config: Data()) }
    }

    // MARK: helpers

    /// 100 ms of a 1 kHz sine at amplitude 0.5, 48 kHz, stereo interleaved.
    private var sine1kHz: [Float] {
        (0..<4_800).flatMap { i -> [Float] in
            let v = Float(0.5 * sin(2 * Double.pi * 1_000 * Double(i) / 48_000))
            return [v, v]
        }
    }

    /// Channel 0 of every decoded packet, in order.
    private func decodeAll(_ decoder: AudioDecoder, _ packets: [Data]) -> [Float] {
        var out: [Float] = []
        for packet in packets {
            guard let buffer = decoder.decode(packet), let left = buffer.floatChannelData?[0] else { continue }
            out += UnsafeBufferPointer(start: left, count: Int(buffer.frameLength))
        }
        return out
    }

    /// The decoded sound, without the codec's leading and trailing silence (priming, padding) and
    /// 5 ms at each edge of what is left, has an RMS within 20% of the sine's (0.5 / √2).
    private func checkSine(_ samples: [Float]) throws {
        let first = try #require(samples.firstIndex { abs($0) > 0.05 }, "no sound decoded")
        let last = try #require(samples.lastIndex { abs($0) > 0.05 })
        let body = samples[(first + 240)..<max(first + 240, last - 240)]
        #expect(body.count >= 2_400, "only \(body.count) frames of sound")
        let rms = (body.reduce(0) { $0 + Double($1) * Double($1) } / Double(max(body.count, 1))).squareRoot()
        let expected = 0.5 / 2.0.squareRoot()
        #expect(abs(rms - expected) / expected <= 0.2, "rms \(rms), expected \(expected)")
    }
}

/// Encodes PCM to AAC or Opus packets with AudioConverter, as the phone's encoder would.
enum TestAudioEncoder {
    /// AAC-LC, 48 kHz, stereo: the AudioSpecificConfig Android's encoder gives as its config.
    static let aacConfig = Data([0x11, 0x90])

    /// `interleaved` stereo Float32 at 48 kHz as raw packets; nil when there is no encoder.
    static func encode(_ codec: ScrcpyCodec, sine interleaved: [Float]) -> [Data]? {
        var pcm = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var out = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: codec == .opus ? kAudioFormatOpus : kAudioFormatMPEG4AAC,
            mFormatFlags: codec == .opus ? 0 : UInt32(MPEG4ObjectID.AAC_LC.rawValue),
            mBytesPerPacket: 0, mFramesPerPacket: codec == .opus ? 960 : 1_024, mBytesPerFrame: 0,
            mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
        var made: AudioConverterRef?
        guard AudioConverterNew(&pcm, &out, &made) == noErr, let converter = made else { return nil }
        defer { AudioConverterDispose(converter) }
        if codec == .aac {
            var rate: UInt32 = 128_000
            AudioConverterSetProperty(converter, kAudioConverterEncodeBitRate, 4, &rate)
        }
        var maxPacket: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioConverterGetProperty(converter, kAudioConverterPropertyMaximumOutputPacketSize, &size, &maxPacket)
        maxPacket = max(maxPacket, 2_048)

        /// The PCM, at a stable address for the converter's input callback.
        final class Source {
            let samples: UnsafeMutableBufferPointer<Float>
            var done = false
            init(_ values: [Float]) {
                samples = .allocate(capacity: values.count)
                _ = samples.initialize(from: values)
            }
            deinit { samples.deallocate() }
        }
        let source = Source(interleaved)
        var packets: [Data] = []
        var bytes = [UInt8](repeating: 0, count: Int(maxPacket))
        while true {
            var count: UInt32 = 1
            var description = AudioStreamPacketDescription()
            let status: OSStatus = bytes.withUnsafeMutableBytes { raw in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: 2, mDataByteSize: maxPacket, mData: raw.baseAddress))
                return AudioConverterFillComplexBuffer(converter, { _, ioPackets, ioData, _, user in
                    let source = Unmanaged<Source>.fromOpaque(user!).takeUnretainedValue()
                    guard !source.done else {
                        // End of stream: the encoder flushes what it holds.
                        ioPackets.pointee = 0
                        ioData.pointee.mBuffers.mDataByteSize = 0
                        ioData.pointee.mBuffers.mData = nil
                        return noErr
                    }
                    source.done = true
                    ioPackets.pointee = UInt32(source.samples.count / 2)
                    ioData.pointee.mNumberBuffers = 1
                    ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(source.samples.baseAddress)
                    ioData.pointee.mBuffers.mDataByteSize = UInt32(source.samples.count * MemoryLayout<Float>.size)
                    ioData.pointee.mBuffers.mNumberChannels = 2
                    return noErr
                }, Unmanaged.passUnretained(source).toOpaque(), &count, &list, &description)
            }
            guard status == noErr else { return nil }
            guard count > 0 else { break }
            packets.append(Data(bytes.prefix(Int(description.mDataByteSize))))
        }
        return packets.isEmpty ? nil : packets
    }
}

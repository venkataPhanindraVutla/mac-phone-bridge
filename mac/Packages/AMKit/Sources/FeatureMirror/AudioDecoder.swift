import AudioToolbox
import AVFoundation
import Foundation

public enum AudioDecoderError: Error, Equatable {
    /// Not an audio codec the Mac decodes (`AudioDecoder.supports` is false).
    case unsupported(UInt32)
    /// `AudioConverterNew` failed.
    case converter(OSStatus)
}

/// Decodes the phone's Opus or AAC packets to PCM with an `AudioConverter`: Float32, 48 kHz,
/// stereo, non-interleaved (`outputFormat`, what `AudioOutput` plays). scrcpy always captures
/// 48 kHz stereo. The stream's first config packet is the decoder's magic cookie: an OpusHead for
/// Opus, an AudioSpecificConfig for AAC (wrapped in the ES descriptor AudioToolbox expects).
///
/// One thread decodes at a time (the session's audio read loop); the lock makes it safe anyway.
/// The converter's input callback is a C function that only reads the packet it is given.
public final class AudioDecoder: @unchecked Sendable {
    public static let sampleRate = 48_000.0
    public static let channels: AVAudioChannelCount = 2
    /// What `decode` returns: Float32, 48 kHz, 2 channels, non-interleaved.
    public static let outputFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
    /// The status of setting the config packet as the converter's magic cookie: `noErr`, or why
    /// the converter refused it (then the format alone is used). `noErr` when there was no config.
    public let cookieStatus: OSStatus

    private let converter: AudioConverterRef
    /// Frames one `decode` returns at most: twice the codec's packet (Opus 20 ms, AAC 1024 frames).
    /// A longer packet's remainder stays in the converter and comes out with the next one.
    private let capacity: AVAudioFrameCount
    private let lock = NSLock()

    /// Whether this Mac decodes `codec`. Probes `AudioConverterNew` once per codec.
    public static func supports(_ codec: ScrcpyCodec) -> Bool {
        switch codec {
        case .opus: opusSupported
        case .aac: aacSupported
        case .h264, .h265: false
        }
    }

    private static let opusSupported = probe(.opus)
    private static let aacSupported = probe(.aac)

    private static func probe(_ codec: ScrcpyCodec) -> Bool {
        guard let made = try? makeConverter(codec) else { return false }
        AudioConverterDispose(made.0)
        return true
    }

    /// `config` is the stream's config packet (empty when it sent none). A cookie the converter
    /// refuses is left out (`cookieStatus` says why): the format alone decodes 48 kHz stereo.
    public init(codec: ScrcpyCodec, config: Data) throws {
        let (converter, framesPerPacket) = try Self.makeConverter(codec)
        self.converter = converter
        capacity = framesPerPacket * 2
        let cookie = codec == .aac ? Self.esds(audioSpecificConfig: config) : config
        cookieStatus = cookie.isEmpty ? noErr : cookie.withUnsafeBytes { raw in
            AudioConverterSetProperty(converter, kAudioConverterDecompressionMagicCookie, UInt32(raw.count), raw.baseAddress!)
        }
    }

    deinit {
        AudioConverterDispose(converter)
    }

    /// One packet's PCM; nil when it decodes to nothing (an empty or broken packet, or the codec's
    /// start-up delay).
    public func decode(_ packet: Data) -> AVAudioPCMBuffer? {
        guard !packet.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: Self.outputFormat, frameCapacity: capacity) else { return nil }
        buffer.frameLength = buffer.frameCapacity // so the buffer list carries the full capacity
        var frames = UInt32(capacity)
        let status: OSStatus = lock.withLock {
            packet.withUnsafeBytes { raw in
                var input = PacketInput(bytes: raw.baseAddress!, count: UInt32(raw.count))
                return withUnsafeMutablePointer(to: &input) { pointer in
                    AudioConverterFillComplexBuffer(converter, { _, ioPackets, ioData, outDescription, user in
                        let input = user!.assumingMemoryBound(to: PacketInput.self)
                        guard !input.pointee.used else {
                            // One packet per call: "no more for now", so the converter returns what it has.
                            ioPackets.pointee = 0
                            return PacketInput.drained
                        }
                        input.pointee.used = true
                        ioPackets.pointee = 1
                        ioData.pointee.mNumberBuffers = 1
                        ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(mutating: input.pointee.bytes)
                        ioData.pointee.mBuffers.mDataByteSize = input.pointee.count
                        ioData.pointee.mBuffers.mNumberChannels = AudioDecoder.channels
                        outDescription?.pointee = input.pointer(to: \.description)
                        return noErr
                    }, pointer, &frames, buffer.mutableAudioBufferList, nil)
                }
            }
        }
        guard status == noErr || status == PacketInput.drained, frames > 0 else { return nil }
        buffer.frameLength = frames
        return buffer
    }

    // MARK: private

    /// The converter and the codec's frames per packet.
    private static func makeConverter(_ codec: ScrcpyCodec) throws -> (AudioConverterRef, AVAudioFrameCount) {
        var input = AudioStreamBasicDescription()
        input.mSampleRate = sampleRate
        input.mChannelsPerFrame = channels
        switch codec {
        case .opus:
            input.mFormatID = kAudioFormatOpus
            input.mFramesPerPacket = 960 // 20 ms, Android's Opus frame
        case .aac:
            input.mFormatID = kAudioFormatMPEG4AAC
            input.mFormatFlags = UInt32(MPEG4ObjectID.AAC_LC.rawValue)
            input.mFramesPerPacket = 1_024
        case .h264, .h265:
            throw AudioDecoderError.unsupported(codec.rawValue)
        }
        var output = outputFormat.streamDescription.pointee
        var made: AudioConverterRef?
        let status = AudioConverterNew(&input, &output, &made)
        guard status == noErr, let made else { throw AudioDecoderError.converter(status) }
        return (made, input.mFramesPerPacket)
    }

    /// The MPEG-4 ES descriptor (ISO 14496-1) around an AudioSpecificConfig: AudioToolbox's AAC
    /// cookie. Empty for an empty config; a config that already is a descriptor is kept.
    static func esds(audioSpecificConfig asc: Data) -> Data {
        guard !asc.isEmpty, asc.count < 100 else { return Data() }
        if asc.first == 0x03 { return asc }
        let specific = Data([0x05, UInt8(asc.count)]) + asc
        // Object type 0x40 (MPEG-4 audio), stream type 0x15 (audio), buffer size and bit rates unset.
        let decoderConfig = Data([0x04, UInt8(13 + specific.count), 0x40, 0x15]) + Data(count: 11) + specific
        let sl = Data([0x06, 0x01, 0x02])
        let body = Data([0x00, 0x00, 0x00]) + decoderConfig + sl // ES_ID 0, no flags
        return Data([0x03, UInt8(body.count)]) + body
    }
}

/// The one packet a `decode` call hands the converter.
private struct PacketInput {
    /// The input callback's "no more for now" status ('drnd').
    static let drained: OSStatus = 0x6472_6E64

    let bytes: UnsafeRawPointer
    let count: UInt32
    var used = false
    var description: AudioStreamPacketDescription

    init(bytes: UnsafeRawPointer, count: UInt32) {
        self.bytes = bytes
        self.count = count
        description = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: count)
    }
}

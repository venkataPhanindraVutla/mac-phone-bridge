import CoreMedia
import CoreVideo
@testable import FeatureMirror
import Foundation
import VideoToolbox

// The shared doubles (FakeBulk, MemoryPipe, SentLog, until, ...) are in AMTestSupport.

/// The repository's `protocol/` folder, found from this file like `VectorTests` finds `protocol/vectors`.
let protocolDir = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("protocol")

/// The canned stream: the video socket's bytes after the dummy byte (SPEC section 24).
let sampleStream: Data = {
    let url = protocolDir.appendingPathComponent("testdata/mirror/sample-h264-320x640.scrcpy")
    do { return try Data(contentsOf: url) } catch { fatalError("cannot load the sample from \(url.path): \(error)") }
}()

/// The sample as the helper sends it: the dummy byte first.
let sampleWithDummyByte = Data([0]) + sampleStream

/// The sample's media packets (the config packet first), parsed once.
let samplePackets: [MediaPacket] = {
    var parser = VideoStreamParser(expectDummyByte: false)
    let events = (try? parser.push(sampleStream)) ?? []
    return events.compactMap { if case let .packet(p) = $0 { p } else { nil } }
}()

/// Counts what reaches it and remembers the last picture's size, from any thread.
final class CountingSink: FrameSink, @unchecked Sendable {
    private let lock = NSLock()
    private var shownCount = 0
    private var flushCount = 0
    private var size: (Int, Int)?
    private var offMain = true

    func show(_ image: CVPixelBuffer) {
        let onMain = Thread.isMainThread
        lock.withLock {
            shownCount += 1
            size = (CVPixelBufferGetWidth(image), CVPixelBufferGetHeight(image))
            if onMain { offMain = false }
        }
    }

    func flush() { lock.withLock { flushCount += 1 } }

    var shown: Int { lock.withLock { shownCount } }
    var flushes: Int { lock.withLock { flushCount } }
    var lastSize: (width: Int, height: Int)? { lock.withLock { size.map { (width: $0.0, height: $0.1) } } }
    /// Every frame arrived off the main thread.
    var allOffMain: Bool { lock.withLock { offMain } }
}

/// A thread-safe list, for callbacks that come from any thread.
final class Recorder<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []

    func append(_ item: T) { lock.withLock { items.append(item) } }
    var all: [T] { lock.withLock { items } }
    var count: Int { lock.withLock { items.count } }
}

/// The 12-byte media packet header plus the payload (scrcpy v5.0.1).
func packetBytes(config: Bool = false, key: Bool = false, pts: UInt64, payload: Data) -> Data {
    var head = pts & ((1 << 61) - 1)
    if config { head |= 1 << 62 }
    if key { head |= 1 << 61 }
    var d = Data()
    withUnsafeBytes(of: head.bigEndian) { d.append(contentsOf: $0) }
    withUnsafeBytes(of: UInt32(payload.count).bigEndian) { d.append(contentsOf: $0) }
    return d + payload
}

/// A session packet: bit 63, then the width and height.
func sessionBytes(width: UInt32, height: UInt32) -> Data {
    var d = Data([0x80, 0, 0, 0])
    withUnsafeBytes(of: width.bigEndian) { d.append(contentsOf: $0) }
    withUnsafeBytes(of: height.bigEndian) { d.append(contentsOf: $0) }
    return d
}

/// The prelude after the dummy byte: the 64-byte name and the codec ID.
func preludeBytes(name: String, codec: ScrcpyCodec) -> Data {
    var d = Data(name.utf8.prefix(63))
    d.append(Data(count: 64 - d.count))
    withUnsafeBytes(of: codec.rawValue.bigEndian) { d.append(contentsOf: $0) }
    return d
}

// MARK: encoding at test time

/// Frames encoded with VideoToolbox, as scrcpy packets: one config packet (the parameter sets in
/// Annex B), then the frames in Annex B with their PTS (µs) and key flags.
enum TestEncoder {
    static func available(_ codec: CMVideoCodecType) -> Bool {
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: 320, height: 640, codecType: codec, encoderSpecification: nil,
            imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
            compressionSessionOut: &session)
        if let session { VTCompressionSessionInvalidate(session) }
        return status == noErr && session != nil
    }

    /// `count` frames of `width` × `height`, every `keyEvery`th a key frame. Nil when no encoder.
    static func encode(_ codec: CMVideoCodecType, width: Int, height: Int, count: Int, keyEvery: Int = 30) -> [MediaPacket]? {
        var created: VTCompressionSession?
        guard VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height), codecType: codec, encoderSpecification: nil,
            imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
            compressionSessionOut: &created) == noErr, let session = created else { return nil }
        defer { VTCompressionSessionInvalidate(session) }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: keyEvery as CFNumber)

        let config = Recorder<Data>()
        let frames = Recorder<MediaPacket>()
        let hevc = codec == kCMVideoCodecType_HEVC
        for i in 0..<count {
            guard let pixels = grey(width: width, height: height, level: UInt8((i * 4) % 256)) else { return nil }
            let pts = CMTime(value: CMTimeValue(i) * 16_667, timescale: 1_000_000)
            let props: CFDictionary? = i % keyEvery == 0
                ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary : nil
            let status = VTCompressionSessionEncodeFrame(
                session, imageBuffer: pixels, presentationTimeStamp: pts, duration: .invalid,
                frameProperties: props, infoFlagsOut: nil
            ) { status, _, sample in
                guard status == noErr, let sample, let block = CMSampleBufferGetDataBuffer(sample) else { return }
                if config.count == 0, let format = CMSampleBufferGetFormatDescription(sample) {
                    config.append(annexB(parameterSets(hevc, format)))
                }
                let us = UInt64(CMTimeConvertScale(CMSampleBufferGetPresentationTimeStamp(sample),
                                                   timescale: 1_000_000, method: .roundHalfAwayFromZero).value)
                frames.append(MediaPacket(config: false, key: isKey(sample), pts: us, payload: annexB(lengthPrefixed(block))))
            }
            guard status == noErr else { return nil }
        }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        guard let first = config.all.first, frames.count == count else { return nil }
        return [MediaPacket(config: true, key: false, pts: 0, payload: first)] + frames.all
    }

    private static func grey(width: Int, height: Int, level: UInt8) -> CVPixelBuffer? {
        var created: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &created)
        guard let buffer = created else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
            if let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) {
                memset(base, plane == 0 ? Int32(level) : 128,
                       CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane))
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    private static func isKey(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
              let first = attachments.first else { return true }
        return (first[kCMSampleAttachmentKey_NotSync] as? Bool) != true
    }

    private static func parameterSets(_ hevc: Bool, _ format: CMFormatDescription) -> [Data] {
        var out: [Data] = []
        var count = 0
        func at(_ i: Int) -> Data? {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status = hevc
                ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: i, parameterSetPointerOut: &pointer,
                                                                    parameterSetSizeOut: &size, parameterSetCountOut: &count,
                                                                    nalUnitHeaderLengthOut: nil)
                : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: i, parameterSetPointerOut: &pointer,
                                                                    parameterSetSizeOut: &size, parameterSetCountOut: &count,
                                                                    nalUnitHeaderLengthOut: nil)
            guard status == noErr, let pointer else { return nil }
            return Data(bytes: pointer, count: size)
        }
        if let first = at(0) { out.append(first) }
        if count > 1 { for i in 1..<count { if let d = at(i) { out.append(d) } } }
        return out
    }

    /// The NAL units of a 4-byte length-prefixed buffer.
    private static func lengthPrefixed(_ block: CMBlockBuffer) -> [Data] {
        let length = CMBlockBufferGetDataLength(block)
        var bytes = Data(count: length)
        bytes.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
        var nals: [Data] = []
        var i = 0
        while i + 4 <= bytes.count {
            let n = Int(bytes[i]) << 24 | Int(bytes[i + 1]) << 16 | Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
            i += 4
            guard n > 0, i + n <= bytes.count else { break }
            nals.append(bytes.subdata(in: i..<(i + n)))
            i += n
        }
        return nals
    }

    private static func annexB(_ nals: [Data]) -> Data {
        nals.reduce(into: Data()) { $0.append(contentsOf: [0, 0, 0, 1]); $0.append($1) }
    }
}

/// A manual clock for the RESET_VIDEO throttle: `advance` runs what has come due, in order.
final class FakeResetClock: @unchecked Sendable {
    private let lock = NSLock()
    private let start = ContinuousClock.now
    private var offset: Duration = .zero
    private var timers: [(due: Duration, work: @Sendable () -> Void)] = []

    var clock: ResetClock {
        ResetClock(
            now: { [self] in lock.withLock { start + offset } },
            after: { [self] delay, work in lock.withLock { timers.append((offset + delay, work)) } }
        )
    }

    /// Time since the clock was made.
    var elapsed: Duration { lock.withLock { offset } }
    var scheduled: Int { lock.withLock { timers.count } }

    func advance(by step: Duration) {
        let target = lock.withLock { offset + step }
        while true {
            let next: (due: Duration, work: @Sendable () -> Void)? = lock.withLock {
                guard let i = timers.indices.filter({ timers[$0].due <= target }).min(by: { timers[$0].due < timers[$1].due })
                else { return nil }
                let t = timers.remove(at: i)
                offset = t.due
                return t
            }
            guard let next else { break }
            next.work()
        }
        lock.withLock { offset = target }
    }
}

// Writes the canned mirror stream used by the 0.5 tests and phone-sim's --mirror-relay:
// the scrcpy v5.0.1 video socket bytes after the dummy byte (SPEC section 24,
// protocol/vectors/scrcpy.json `stream`).
//
//   swift scripts/make-mirror-sample.swift protocol/testdata/mirror/sample-h264-320x640.scrcpy
//
// Contents: the 64-byte device name "phone-sim", the codec ID `h264`, one session packet
// 320x640, one config packet (SPS + PPS, Annex B), then 60 media packets (Annex B).
// 60 frames at 60 fps (PTS step 16,667 us), H.264 Constrained Baseline, real time, no frame
// reordering, key frames 0 and 30. The picture is a white bar moving down a black frame.
//
// Run by hand; the output is committed and is the reference. VideoToolbox's software H.264
// encoder has no Constrained Baseline profile, so this uses the default encoder (the hardware
// one on Apple silicon). That encoder adds a private SEI (user data with a counter that changes
// on every run) to key frames; SEI NAL units carry nothing a decoder needs, so they are dropped,
// and re-runs on the same Mac then give the same bytes. Other Macs or macOS versions may still
// encode differently. The script checks the stream's shape (frame count, PTS, no reordering,
// key frames, one SPS/PPS, size) before it writes anything.
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

let width = 320
let height = 640
let frameCount = 60
let ptsStepUs: Int64 = 16_667
let keyFrames: Set<Int> = [0, 30]
let barHeight = 32
let deviceName = "phone-sim"
let codecH264: UInt32 = 0x6832_3634
let sizeLimit = 200 * 1024

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make-mirror-sample: \(message)\n".utf8))
    exit(1)
}

func check(_ status: OSStatus, _ what: String) {
    if status != noErr { fail("\(what) failed: \(status)") }
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: swift scripts/make-mirror-sample.swift <out.scrcpy>\n".utf8))
    exit(2)
}
let outURL = URL(fileURLWithPath: CommandLine.arguments[1])

// MARK: - Encoding

/// Encoded frames in output order; the handler runs on a VideoToolbox thread.
final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [CMSampleBuffer] = []
    private var status: OSStatus = noErr

    func add(_ status: OSStatus, _ sample: CMSampleBuffer?) {
        lock.lock()
        defer { lock.unlock() }
        if status != noErr { self.status = status } else if let sample { samples.append(sample) }
    }

    func result() -> (OSStatus, [CMSampleBuffer]) {
        lock.lock()
        defer { lock.unlock() }
        return (status, samples)
    }
}


func set(_ session: VTCompressionSession, _ key: CFString, _ value: Any) {
    check(VTSessionSetProperty(session, key: key, value: value as CFTypeRef), "set \(key)")
}

/// NV12, video range: black is Y 16, white Y 235, chroma 128. The bar's top moves from 0 to the bottom.
func frame(_ index: Int) -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    check(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                              nil, &buffer), "CVPixelBufferCreate")
    let pb = buffer!
    CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2,
                          .shouldPropagate)
    CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2,
                          .shouldPropagate)
    CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                          .shouldPropagate)
    CVPixelBufferLockBaseAddress(pb, [])
    defer { CVPixelBufferUnlockBaseAddress(pb, []) }
    let barTop = index * (height - barHeight) / (frameCount - 1)
    let luma = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
    let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
    for y in 0..<height {
        let value: UInt8 = (barTop..<barTop + barHeight).contains(y) ? 235 : 16
        memset(luma + y * lumaStride, Int32(value), lumaStride)
    }
    let chroma = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!
    memset(chroma, 128, CVPixelBufferGetBytesPerRowOfPlane(pb, 1) * CVPixelBufferGetHeightOfPlane(pb, 1))
    return pb
}

var maybeSession: VTCompressionSession?
check(VTCompressionSessionCreate(
    allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
    encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
    outputCallback: nil, refcon: nil, compressionSessionOut: &maybeSession), "VTCompressionSessionCreate")
let session = maybeSession!
var encoderID: CFString?
_ = withUnsafeMutablePointer(to: &encoderID) {
    VTSessionCopyProperty(session, key: kVTCompressionPropertyKey_EncoderID, allocator: nil, valueOut: $0)
}
let encoderUsed = (encoderID as String?) ?? "unknown"
set(session, kVTCompressionPropertyKey_RealTime, true)
set(session, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_ConstrainedBaseline_AutoLevel)
set(session, kVTCompressionPropertyKey_AllowFrameReordering, false)
set(session, kVTCompressionPropertyKey_ExpectedFrameRate, 60)
set(session, kVTCompressionPropertyKey_AverageBitRate, 200_000)
// Only the forced key frames: no interval-driven ones within the 60 frames.
set(session, kVTCompressionPropertyKey_MaxKeyFrameInterval, 10_000)
set(session, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 10_000)
set(session, kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2)
set(session, kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2)
set(session, kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
check(VTCompressionSessionPrepareToEncodeFrames(session), "prepare")

let collector = Collector()
for i in 0..<frameCount {
    let props: [CFString: Any] = [kVTEncodeFrameOptionKey_ForceKeyFrame: keyFrames.contains(i)]
    check(VTCompressionSessionEncodeFrame(
        session, imageBuffer: frame(i),
        presentationTimeStamp: CMTime(value: Int64(i) * ptsStepUs, timescale: 1_000_000),
        duration: CMTime(value: ptsStepUs, timescale: 1_000_000),
        frameProperties: props as CFDictionary, infoFlagsOut: nil,
        outputHandler: { status, _, sample in collector.add(status, sample) }), "encode frame \(i)")
}
check(VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid), "complete")
VTCompressionSessionInvalidate(session)
let (encodeStatus, samples) = collector.result()
check(encodeStatus, "encoder output")
guard samples.count == frameCount else { fail("expected \(frameCount) frames, got \(samples.count)") }

// MARK: - Annex B

let startCode: [UInt8] = [0, 0, 0, 1]

/// SPS and PPS of a format description, each behind a start code, and the AVCC length size.
func parameterSets(_ format: CMFormatDescription) -> (bytes: [UInt8], lengthSize: Int) {
    var count = 0
    var lengthSize: Int32 = 0
    check(CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
        format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
        parameterSetCountOut: &count, nalUnitHeaderLengthOut: &lengthSize), "parameter set count")
    var out: [UInt8] = []
    for index in 0..<count {
        var pointer: UnsafePointer<UInt8>?
        var size = 0
        check(CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
            parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil), "parameter set \(index)")
        out += startCode + Array(UnsafeBufferPointer(start: pointer, count: size))
    }
    return (out, Int(lengthSize))
}

let nalTypeSEI: UInt8 = 6

/// The sample's length-prefixed NAL units, rewritten with start codes, without SEI.
func annexB(_ sample: CMSampleBuffer, lengthSize: Int) -> [UInt8] {
    guard let block = CMSampleBufferGetDataBuffer(sample) else { fail("sample without data") }
    var avcc = [UInt8](repeating: 0, count: CMBlockBufferGetDataLength(block))
    check(CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: avcc.count, destination: &avcc), "copy")
    var out: [UInt8] = []
    var offset = 0
    while offset < avcc.count {
        guard offset + lengthSize <= avcc.count else { fail("truncated NAL length") }
        let length = avcc[offset..<offset + lengthSize].reduce(0) { $0 << 8 | Int($1) }
        offset += lengthSize
        guard length > 0, offset + length <= avcc.count else { fail("bad NAL length \(length)") }
        if avcc[offset] & 0x1F != nalTypeSEI { out += startCode + avcc[offset..<offset + length] }
        offset += length
    }
    return out
}

func isKeyFrame(_ sample: CMSampleBuffer) -> Bool {
    guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
        as? [[CFString: Any]], let first = attachments.first else { return true }
    return !(first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
}

// MARK: - The stream

func u32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> (24 - 8 * $0)) } }
func u64(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8(truncatingIfNeeded: v >> (56 - 8 * $0)) } }
let flagSession: UInt64 = 1 << 63
let flagConfig: UInt64 = 1 << 62
let flagKeyFrame: UInt64 = 1 << 61

guard let format = CMSampleBufferGetFormatDescription(samples[0]) else { fail("no format description") }
let (config, lengthSize) = parameterSets(format)
var out: [UInt8] = Array(deviceName.utf8) + [UInt8](repeating: 0, count: 64 - deviceName.utf8.count)
out += u32(codecH264)
out += u64(flagSession | UInt64(width)) + u32(UInt32(height))
out += u64(flagConfig) + u32(UInt32(config.count)) + config
var keys: [Int] = []
for (index, sample) in samples.enumerated() {
    let pts = CMSampleBufferGetPresentationTimeStamp(sample)
    let dts = CMSampleBufferGetDecodeTimeStamp(sample)
    guard pts.timescale == 1_000_000, pts.value == Int64(index) * ptsStepUs else { fail("frame \(index): PTS \(pts)") }
    guard !dts.isValid || dts == pts else { fail("frame \(index): reordered (DTS \(dts))") }
    if let f = CMSampleBufferGetFormatDescription(sample), parameterSets(f).bytes != config {
        fail("frame \(index): SPS/PPS changed")
    }
    let key = isKeyFrame(sample)
    if key { keys.append(index) }
    let payload = annexB(sample, lengthSize: lengthSize)
    out += u64((key ? flagKeyFrame : 0) | UInt64(pts.value)) + u32(UInt32(payload.count)) + payload
}
guard Set(keys) == keyFrames else { fail("key frames \(keys), expected \(keyFrames.sorted())") }
guard out.count <= sizeLimit else { fail("\(out.count) bytes, over \(sizeLimit)") }
do {
    try FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(out).write(to: outURL)
} catch {
    fail("cannot write \(outURL.path): \(error)")
}
print("wrote \(outURL.path): \(out.count) bytes, \(samples.count) frames, key frames \(keys), "
    + "config \(config.count) bytes, encoder \(encoderUsed)")

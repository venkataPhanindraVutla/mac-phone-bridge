import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Decodes scrcpy video packets with VideoToolbox, on its own serial queue, and hands each
/// picture straight to the sink (NV12, IOSurface-backed); nothing waits on the main actor.
///
/// Packets queue in a FIFO that the decoder's queue drains. A config packet's parameter sets
/// (re)build the format description; a changed SPS/PPS (or VPS) rebuilds the decompression
/// session. Parameter sets inside a frame count the same way and are taken out of it. Annex B
/// NAL units become 4-byte length prefixed; access unit delimiters are dropped.
///
/// `backlog` is the frames submitted and not yet decoded (or dropped). `dropUntilKeyFrame()` drops
/// the queued frames before the newest queued key frame; when no key frame is queued, or the
/// newest is the oldest queued frame (nothing would go), it drops every queued frame and every
/// frame after them until the next key frame arrives. A decode error does the same and calls `onKeyFrameNeeded`.
public final class VideoDecoder: @unchecked Sendable {
    private enum Item {
        case config(Data)
        case frame(MediaPacket, ScrcpyCodec, seq: UInt)
    }

    private let sink: any FrameSink
    private let onFrame: @Sendable (UInt64) -> Void
    private let queue = DispatchQueue(label: "io.github.anmirror.mirror-decode", qos: .userInteractive)
    private let lock = NSLock()

    // Guarded by `lock`.
    private var pending: [(item: Item, codec: ScrcpyCodec)] = []
    private var draining = false
    private var outstanding = 0
    private var waitingForKey = false
    private var invalidated = false
    private var held = false
    private var errors = 0
    private var created = 0
    private var nextSeq: UInt = 0
    private var completedSeq: UInt = 0
    private var keyFrameNeeded: (@Sendable () -> Void)?
    /// After a decode error: queued frames are dropped until a key frame.
    private var skipToKey = false

    // Used on `queue` only.
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var parameterSets: [Data] = []
    private var sessionCodec: ScrcpyCodec?

    /// `onFrame` gets each decoded picture's PTS (µs), right after the sink has it.
    public init(sink: any FrameSink, onFrame: @escaping @Sendable (UInt64) -> Void) {
        self.sink = sink
        self.onFrame = onFrame
    }

    deinit {
        if let session { VTDecompressionSessionInvalidate(session) }
    }

    /// Called after a decode error, when frames are dropped until the next key frame.
    public var onKeyFrameNeeded: (@Sendable () -> Void)? {
        get { lock.withLock { keyFrameNeeded } }
        set { lock.withLock { keyFrameNeeded = newValue } }
    }

    /// Queues `p` (from any thread); returns at once.
    public func decode(_ p: MediaPacket, codec: ScrcpyCodec) {
        let schedule: Bool = lock.withLock {
            guard !invalidated else { return false }
            if p.config {
                pending.append((.config(p.payload), codec))
            } else {
                if waitingForKey, !p.key { return false }
                if p.key { waitingForKey = false }
                nextSeq += 1
                pending.append((.frame(p, codec, seq: nextSeq), codec))
                outstanding += 1
            }
            guard !draining else { return false }
            draining = true
            return true
        }
        if schedule { queue.async { self.drain() } }
    }

    /// Frames submitted and not yet decoded or dropped.
    public var backlog: Int { lock.withLock { outstanding } }

    /// Frames VideoToolbox failed to decode, so far.
    public var decodeErrors: Int { lock.withLock { errors } }

    /// Decompression sessions made so far (internal, for tests).
    var sessionsCreated: Int { lock.withLock { created } }

    public func dropUntilKeyFrame() {
        lock.withLock {
            let isFrame: ((item: Item, codec: ScrcpyCodec)) -> Bool = { if case .frame = $0.item { true } else { false } }
            var lastKey = pending.lastIndex { if case let .frame(p, _, _) = $0.item { p.key } else { false } }
            if let k = lastKey, pending[..<k].allSatisfy({ !isFrame($0) }) { lastKey = nil }
            var kept: [(item: Item, codec: ScrcpyCodec)] = []
            for (i, entry) in pending.enumerated() {
                if case .frame = entry.item, lastKey.map({ i < $0 }) ?? true {
                    outstanding -= 1
                } else {
                    kept.append(entry)
                }
            }
            pending = kept
            if lastKey == nil { waitingForKey = true }
        }
    }

    /// Stops for good: queued packets are dropped and the session is torn down on the queue.
    public func invalidate() {
        let resume: Bool = lock.withLock {
            invalidated = true
            pending = []
            outstanding = 0
            defer { held = false }
            return held
        }
        if resume { queue.resume() }
        sink.flush()
        queue.async { self.teardown() }
    }

    /// Test hooks: stop and restart the decoder's queue, so packets pile up.
    func hold() {
        let suspend: Bool = lock.withLock {
            guard !held, !invalidated else { return false }
            held = true
            return true
        }
        if suspend { queue.suspend() }
    }

    func release() {
        let resume: Bool = lock.withLock {
            defer { held = false }
            return held
        }
        if resume { queue.resume() }
    }

    // MARK: the queue

    private func drain() {
        while true {
            let next: (item: Item, codec: ScrcpyCodec)? = lock.withLock {
                if invalidated || pending.isEmpty {
                    draining = false
                    return nil
                }
                return pending.removeFirst()
            }
            guard let next else { return }
            switch next.item {
            case let .config(payload):
                apply(ParameterSets.splitAnnexB(payload), codec: next.codec)
            case let .frame(p, codec, seq):
                decodeFrame(p, codec: codec, seq: seq)
            }
        }
    }

    private func teardown() {
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
        format = nil
        parameterSets = []
    }

    /// New parameter sets: a changed set (or codec) rebuilds the format and the session.
    private func apply(_ nals: [Data], codec: ScrcpyCodec) {
        guard let sets = ParameterSets.ordered(codec: codec, nals: nals) else { return }
        guard sets != parameterSets || codec != sessionCodec || session == nil else { return }
        guard let made = ParameterSets.formatDescription(codec: codec, nals: sets) else { return }
        // Pictures of the old stream still waiting for display go; the one on screen stays.
        if session != nil { sink.flush() }
        teardown()
        format = made
        parameterSets = sets
        sessionCodec = codec
        makeSession()
    }

    private func makeSession() {
        guard let format else { return }
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any]() as CFDictionary,
        ]
        let spec: [CFString: Any] = [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true]
        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: videoDecoderOutput,
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque())
        var made: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: format, decoderSpecification: spec as CFDictionary,
            imageBufferAttributes: attributes as CFDictionary, outputCallback: &callback, decompressionSessionOut: &made)
        guard status == noErr, let made else { return }
        VTSessionSetProperty(made, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = made
        lock.withLock { created += 1 }
    }

    private func decodeFrame(_ p: MediaPacket, codec: ScrcpyCodec, seq: UInt) {
        var nals = ParameterSets.splitAnnexB(p.payload).filter { !ParameterSets.isDelimiter($0, codec) }
        let inline = nals.filter { ParameterSets.isParameterSet($0, codec) }
        if !inline.isEmpty {
            apply(inline, codec: codec)
            nals.removeAll { ParameterSets.isParameterSet($0, codec) }
        }
        let skip: Bool = lock.withLock {
            if skipToKey, p.key { skipToKey = false }
            return skipToKey
        }
        guard !skip, !nals.isEmpty, codec == sessionCodec, let session, let format,
              let sample = Self.sampleBuffer(nals, pts: p.pts, format: format) else {
            finish(seq)
            return
        }
        var info = VTDecodeInfoFlags()
        let status = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sample, flags: [], frameRefcon: UnsafeMutableRawPointer(bitPattern: seq),
            infoFlagsOut: &info)
        if status != noErr {
            // The output callback may not have run for it.
            if lock.withLock({ completedSeq != seq }) { finish(seq, error: true) }
            if status == kVTInvalidSessionErr {
                // After sleep or a GPU change: a fresh session from the same parameter sets.
                teardownSessionOnly()
                makeSession()
            }
        }
    }

    private func teardownSessionOnly() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
    }

    /// From the output callback (VideoToolbox's thread or the queue): any thread.
    fileprivate func output(seq: UInt, status: OSStatus, flags: VTDecodeInfoFlags, image: CVImageBuffer?, pts: CMTime) {
        let alive = lock.withLock { !invalidated }
        if status == noErr, let image, !flags.contains(.frameDropped), alive {
            sink.show(image)
            let us = CMTimeConvertScale(pts, timescale: 1_000_000, method: .roundHalfAwayFromZero).value
            onFrame(UInt64(max(0, us)))
        }
        finish(seq, error: status != noErr)
    }

    private func finish(_ seq: UInt, error: Bool = false) {
        let needed: (@Sendable () -> Void)? = lock.withLock {
            completedSeq = seq
            if outstanding > 0, !invalidated { outstanding -= 1 }
            guard error else { return nil }
            errors += 1
            skipToKey = true
            return keyFrameNeeded
        }
        needed?()
    }

    /// One frame's NAL units as a 4-byte length-prefixed sample, written straight into its block buffer.
    private static func sampleBuffer(_ nals: [Data], pts: UInt64, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        let total = nals.reduce(0) { $0 + $1.count + 4 }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: total, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: total, flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block) == noErr, let block else { return nil }
        var offset = 0
        for nal in nals {
            var prefix = UInt32(nal.count).bigEndian
            guard CMBlockBufferReplaceDataBytes(with: &prefix, blockBuffer: block, offsetIntoDestination: offset,
                                                dataLength: 4) == noErr else { return nil }
            let copied = nal.withUnsafeBytes {
                CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: offset + 4,
                                              dataLength: nal.count)
            }
            guard copied == noErr else { return nil }
            offset += 4 + nal.count
        }
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMTime(value: CMTimeValue(pts), timescale: 1_000_000),
                                        decodeTimeStamp: .invalid)
        var size = total
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size,
            sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }
}

/// VideoToolbox's output callback: a C function, so it carries no actor isolation.
private func videoDecoderOutput(
    _ refcon: UnsafeMutableRawPointer?, _ frameRefcon: UnsafeMutableRawPointer?, _ status: OSStatus,
    _ flags: VTDecodeInfoFlags, _ image: CVImageBuffer?, _ pts: CMTime, _ duration: CMTime
) {
    guard let refcon else { return }
    let decoder = Unmanaged<VideoDecoder>.fromOpaque(refcon).takeUnretainedValue()
    decoder.output(seq: UInt(bitPattern: frameRefcon), status: status, flags: flags, image: image, pts: pts)
}

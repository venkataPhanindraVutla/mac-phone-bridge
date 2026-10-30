import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

/// Where decoded pictures go. Called off the main thread; nothing in it may wait on the main actor.
public protocol FrameSink: AnyObject, Sendable {
    /// Called on the decoder's side (its queue, or VideoToolbox's output thread), once per picture.
    func show(_ image: CVPixelBuffer)
    /// Drops pictures queued for display; the one on screen stays.
    func flush()
}

/// Shows pictures on an `AVSampleBufferDisplayLayer`'s renderer (macOS 14), each as a sample
/// buffer marked `DisplayImmediately`, so nothing waits for a timebase.
public final class LayerFrameSink: FrameSink, @unchecked Sendable {
    private let renderer: AVSampleBufferVideoRenderer
    private let lock = NSLock()
    /// Guarded by `lock`: the description of the last picture, reused while it matches.
    private var format: CMVideoFormatDescription?

    public init(renderer: AVSampleBufferVideoRenderer) {
        self.renderer = renderer
    }

    public func show(_ image: CVPixelBuffer) {
        guard let sample = sampleBuffer(image) else { return }
        // A failed renderer shows nothing until it is flushed.
        if renderer.status == .failed { renderer.flush() }
        renderer.enqueue(sample)
    }

    public func flush() {
        renderer.flush(removingDisplayedImage: false, completionHandler: nil)
    }

    private func sampleBuffer(_ image: CVPixelBuffer) -> CMSampleBuffer? {
        let description: CMVideoFormatDescription? = lock.withLock {
            if let format, CMVideoFormatDescriptionMatchesImageBuffer(format, imageBuffer: image) { return format }
            var made: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image,
                                                         formatDescriptionOut: &made)
            format = made
            return made
        }
        guard let description else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: image, formatDescription: description,
            sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}

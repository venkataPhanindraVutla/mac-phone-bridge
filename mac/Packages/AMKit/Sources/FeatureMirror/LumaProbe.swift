import CoreVideo
import Foundation

/// How bright the middle of a decoded picture is, for "Measure Delay…" (black < 50, white > 200).
public enum LumaProbe {
    /// The side of the centre square that is read.
    static let side = 32

    /// The mean of the centre 32 × 32 samples of plane 0 (the luma of the decoder's NV12, video
    /// range: black 16, white 235); the whole plane when it is smaller. A non-planar buffer is
    /// read as one byte per sample. 0 when the buffer can't be read.
    public static func centerLuma(_ pb: CVPixelBuffer) -> Double {
        guard CVPixelBufferLockBaseAddress(pb, .readOnly) == kCVReturnSuccess else { return 0 }
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let planar = CVPixelBufferIsPlanar(pb)
        let width = planar ? CVPixelBufferGetWidthOfPlane(pb, 0) : CVPixelBufferGetWidth(pb)
        let height = planar ? CVPixelBufferGetHeightOfPlane(pb, 0) : CVPixelBufferGetHeight(pb)
        let rowBytes = planar ? CVPixelBufferGetBytesPerRowOfPlane(pb, 0) : CVPixelBufferGetBytesPerRow(pb)
        guard let base = (planar ? CVPixelBufferGetBaseAddressOfPlane(pb, 0) : CVPixelBufferGetBaseAddress(pb))?
            .assumingMemoryBound(to: UInt8.self), width > 0, height > 0 else { return 0 }
        let w = min(side, width), h = min(side, height)
        let x0 = (width - w) / 2, y0 = (height - h) / 2
        var sum = 0
        for row in y0..<(y0 + h) {
            let line = base + row * rowBytes + x0
            for x in 0..<w { sum += Int(line[x]) }
        }
        return Double(sum) / Double(w * h)
    }
}

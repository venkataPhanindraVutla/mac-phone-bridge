import CoreVideo
import Foundation

/// How bright parts of a decoded picture are, for "Measure Delay…" (black < 50, white > 200), read
/// from plane 0 (the luma of the decoder's NV12, video range: black 16, white 235). A non-planar
/// buffer is read as one byte per sample.
public enum LumaProbe {
    /// The side of the centre square that is read.
    static let side = 32
    /// The test screen's corner squares, as a share of the short side (R56, `DelayTestActivity`).
    static let markerShare = 0.08
    /// The most samples per side read from each marker patch.
    static let markerPatch = 8

    /// The mean of the centre 32 × 32 samples; the whole plane when it is smaller. 0 when the
    /// buffer can't be read.
    public static func centerLuma(_ pb: CVPixelBuffer) -> Double {
        withPlane(pb) { plane in
            let w = min(side, plane.width), h = min(side, plane.height)
            return plane.mean(x0: (plane.width - w) / 2, y0: (plane.height - h) / 2, w: w, h: h)
        } ?? 0
    }

    /// The phone's delay test screen is showing (R56): a white square in each corner (each 8% of
    /// the short side) and black between them, at the middle of each edge. A user's screen, dark or
    /// light, and the test screen while touched (all white) have no marker.
    public static func testScreenMarker(_ pb: CVPixelBuffer) -> Bool {
        withPlane(pb) { plane in
            let square = Int((markerShare * Double(min(plane.width, plane.height))).rounded())
            guard square >= 2 else { return false }
            let patch = max(1, min(markerPatch, square / 2))
            let near = square / 2
            let (w, h) = (plane.width, plane.height)
            let corners = [(near, near), (w - near, near), (near, h - near), (w - near, h - near)]
            let edges = [(w / 2, near), (w / 2, h - near), (near, h / 2), (w - near, h / 2)]
            return corners.allSatisfy { plane.mean(around: $0, patch: patch) > 200 }
                && edges.allSatisfy { plane.mean(around: $0, patch: patch) < 50 }
        } ?? false
    }

    private struct Plane {
        let base: UnsafePointer<UInt8>
        let width, height, rowBytes: Int

        func mean(x0: Int, y0: Int, w: Int, h: Int) -> Double {
            var sum = 0
            for row in y0..<(y0 + h) {
                let line = base + row * rowBytes + x0
                for x in 0..<w { sum += Int(line[x]) }
            }
            return Double(sum) / Double(w * h)
        }

        /// The mean of a `patch` × `patch` square centred on `point`, kept inside the plane.
        func mean(around point: (Int, Int), patch: Int) -> Double {
            let x0 = min(max(point.0 - patch / 2, 0), width - patch)
            let y0 = min(max(point.1 - patch / 2, 0), height - patch)
            return mean(x0: x0, y0: y0, w: patch, h: patch)
        }
    }

    private static func withPlane<T>(_ pb: CVPixelBuffer, _ body: (Plane) -> T) -> T? {
        guard CVPixelBufferLockBaseAddress(pb, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let planar = CVPixelBufferIsPlanar(pb)
        let width = planar ? CVPixelBufferGetWidthOfPlane(pb, 0) : CVPixelBufferGetWidth(pb)
        let height = planar ? CVPixelBufferGetHeightOfPlane(pb, 0) : CVPixelBufferGetHeight(pb)
        let rowBytes = planar ? CVPixelBufferGetBytesPerRowOfPlane(pb, 0) : CVPixelBufferGetBytesPerRow(pb)
        guard let base = (planar ? CVPixelBufferGetBaseAddressOfPlane(pb, 0) : CVPixelBufferGetBaseAddress(pb))?
            .assumingMemoryBound(to: UInt8.self), width > 0, height > 0 else { return nil }
        return body(Plane(base: UnsafePointer(base), width: width, height: height, rowBytes: rowBytes))
    }
}

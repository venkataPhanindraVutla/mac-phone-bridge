import CoreVideo
import Foundation
import Testing
@testable import FeatureMirror

/// An NV12 (video range) picture: `outer` luma everywhere but a centred `square` × `square` of `inner`.
func nv12Picture(width: Int = 320, height: Int = 640, outer: UInt8, inner: UInt8? = nil, square: Int = 32) -> CVPixelBuffer? {
    var created: CVPixelBuffer?
    CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &created)
    guard let buffer = created else { return nil }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
    guard let y = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)?.assumingMemoryBound(to: UInt8.self),
          let uv = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { return nil }
    memset(y, Int32(outer), rowBytes * height)
    memset(uv, 128, CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) * CVPixelBufferGetHeightOfPlane(buffer, 1))
    if let inner {
        let x0 = (width - square) / 2, y0 = (height - square) / 2
        for row in y0..<(y0 + square) { memset(y + row * rowBytes + x0, Int32(inner), square) }
    }
    return buffer
}

@Suite struct LumaProbeTests {
    @Test func centerLumaOfBlackAndWhite() throws {
        let black = try #require(nv12Picture(outer: 16))
        let white = try #require(nv12Picture(outer: 235))
        #expect(LumaProbe.centerLuma(black) == 16)
        #expect(LumaProbe.centerLuma(white) == 235)
        #expect(LumaProbe.centerLuma(black) < 50)
        #expect(LumaProbe.centerLuma(white) > 200)
    }

    /// Only the centre 32 × 32 counts.
    @Test func onlyTheCentreCounts() throws {
        let whiteCentre = try #require(nv12Picture(outer: 16, inner: 235))
        let blackCentre = try #require(nv12Picture(outer: 235, inner: 16))
        #expect(LumaProbe.centerLuma(whiteCentre) == 235)
        #expect(LumaProbe.centerLuma(blackCentre) == 16)
        // A centred 16 × 16 white, a quarter of the centre square: the mean is between.
        let stripe = try #require(nv12Picture(outer: 16, inner: 235, square: 16))
        let mean = LumaProbe.centerLuma(stripe)
        #expect(mean > 50 && mean < 200)
    }

    /// A picture smaller than 32 × 32 is read whole.
    @Test func tinyPicture() throws {
        let tiny = try #require(nv12Picture(width: 16, height: 16, outer: 200))
        #expect(LumaProbe.centerLuma(tiny) == 200)
    }
}

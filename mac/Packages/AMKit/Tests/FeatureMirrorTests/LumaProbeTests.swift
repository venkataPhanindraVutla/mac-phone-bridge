import CoreVideo
import Foundation
import Testing
@testable import FeatureMirror

/// An NV12 (video range) picture: `outer` luma everywhere but a centred `square` × `square` of `inner`,
/// with `corners`, four squares of that luma in the corners, each 8% of the short side (the phone's
/// delay test screen marker, R56).
func nv12Picture(width: Int = 320, height: Int = 640, outer: UInt8, inner: UInt8? = nil, square: Int = 32,
                 corners: UInt8? = nil) -> CVPixelBuffer? {
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
    if let corners {
        let side = Int((0.08 * Double(min(width, height))).rounded())
        for (x0, y0) in [(0, 0), (width - side, 0), (0, height - side), (width - side, height - side)] {
            for row in y0..<(y0 + side) { memset(y + row * rowBytes + x0, Int32(corners), side) }
        }
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

    /// The test screen's marker (R56): white corner squares on black. A dark or light user screen,
    /// or the test screen while touched (all white), has none.
    @Test func testScreenMarker() throws {
        let idle = try #require(nv12Picture(outer: 16, corners: 235))
        #expect(LumaProbe.testScreenMarker(idle))
        #expect(LumaProbe.centerLuma(idle) == 16)
        // Landscape and a small (Low) size too.
        #expect(LumaProbe.testScreenMarker(try #require(nv12Picture(width: 960, height: 432, outer: 16, corners: 235))))
        #expect(LumaProbe.testScreenMarker(try #require(nv12Picture(width: 144, height: 320, outer: 16, corners: 235))))
        // A dark user screen (dark mode, #121212 is about luma 31).
        #expect(!LumaProbe.testScreenMarker(try #require(nv12Picture(outer: 31))))
        // All white: the test screen while touched, or a light app.
        #expect(!LumaProbe.testScreenMarker(try #require(nv12Picture(outer: 235))))
        #expect(!LumaProbe.testScreenMarker(try #require(nv12Picture(outer: 235, corners: 235))))
        // White corners, but a light picture between them.
        #expect(!LumaProbe.testScreenMarker(try #require(nv12Picture(outer: 120, corners: 235))))
        // Only three corners.
        let three = try #require(nv12Picture(outer: 16, corners: 235))
        CVPixelBufferLockBaseAddress(three, [])
        let y = try #require(CVPixelBufferGetBaseAddressOfPlane(three, 0)?.assumingMemoryBound(to: UInt8.self))
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(three, 0)
        for row in 614..<640 { memset(y + row * rowBytes + 294, 16, 26) }
        CVPixelBufferUnlockBaseAddress(three, [])
        #expect(!LumaProbe.testScreenMarker(three))
    }

    /// A picture smaller than 32 × 32 is read whole.
    @Test func tinyPicture() throws {
        let tiny = try #require(nv12Picture(width: 16, height: 16, outer: 200))
        #expect(LumaProbe.centerLuma(tiny) == 200)
    }
}

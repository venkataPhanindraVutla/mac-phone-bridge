import CoreGraphics
import Testing
@testable import FeatureMirror

/// The phone's video in these tests.
let testVideo = CGSize(width: 1080, height: 2400)
/// A view with the picture's own aspect (scale 1/3, no bars).
let exactView = CGSize(width: 360, height: 800)
/// A wider view: the picture is 360 × 800 in the middle, with 70-point bars left and right.
let letterboxView = CGSize(width: 500, height: 800)

@Suite struct MirrorGeometryTests {
    @Test func centreMapsToCentre() {
        let exact = MirrorGeometry.videoPoint(CGPoint(x: 180, y: 400), viewSize: exactView, video: testVideo, clamp: false)
        #expect(exact?.x == 540 && exact?.y == 1200)
        let boxed = MirrorGeometry.videoPoint(CGPoint(x: 250, y: 400), viewSize: letterboxView, video: testVideo, clamp: false)
        #expect(boxed?.x == 540 && boxed?.y == 1200)
    }

    @Test func letterboxOutsideIsNil() {
        #expect(MirrorGeometry.videoPoint(CGPoint(x: 30, y: 400), viewSize: letterboxView, video: testVideo, clamp: false) == nil)
        #expect(MirrorGeometry.videoPoint(CGPoint(x: 431, y: 400), viewSize: letterboxView, video: testVideo, clamp: false) == nil)
        #expect(MirrorGeometry.videoPoint(CGPoint(x: 180, y: -1), viewSize: exactView, video: testVideo, clamp: false) == nil)
        // The bar's inner edge is the picture's first column.
        let edge = MirrorGeometry.videoPoint(CGPoint(x: 70, y: 400), viewSize: letterboxView, video: testVideo, clamp: false)
        #expect(edge?.x == 0 && edge?.y == 1200)
    }

    @Test func clampKeepsEdge() {
        let left = MirrorGeometry.videoPoint(CGPoint(x: 10, y: 400), viewSize: letterboxView, video: testVideo, clamp: true)
        #expect(left?.x == 0 && left?.y == 1200)
        let right = MirrorGeometry.videoPoint(CGPoint(x: 490, y: 400), viewSize: letterboxView, video: testVideo, clamp: true)
        #expect(right?.x == 1079 && right?.y == 1200)
        let corner = MirrorGeometry.videoPoint(CGPoint(x: 900, y: 900), viewSize: exactView, video: testVideo, clamp: true)
        #expect(corner?.x == 1079 && corner?.y == 2399)
        let before = MirrorGeometry.videoPoint(CGPoint(x: -50, y: -50), viewSize: exactView, video: testVideo, clamp: true)
        #expect(before?.x == 0 && before?.y == 0)
    }

    /// The view point's origin is the top left, like the video's.
    @Test func topLeftOrigin() {
        let topLeft = MirrorGeometry.videoPoint(CGPoint(x: 0, y: 0), viewSize: exactView, video: testVideo, clamp: false)
        #expect(topLeft?.x == 0 && topLeft?.y == 0)
        let nearTop = MirrorGeometry.videoPoint(CGPoint(x: 10, y: 20), viewSize: exactView, video: testVideo, clamp: false)
        #expect(nearTop?.x == 30 && nearTop?.y == 60)
        let bottom = MirrorGeometry.videoPoint(CGPoint(x: 359.9, y: 799.9), viewSize: exactView, video: testVideo, clamp: false)
        #expect(bottom?.x == 1079 && bottom?.y == 2399)
    }

    @Test func emptySizesGiveNil() {
        #expect(MirrorGeometry.videoPoint(.zero, viewSize: .zero, video: testVideo, clamp: true) == nil)
        #expect(MirrorGeometry.videoPoint(.zero, viewSize: exactView, video: .zero, clamp: true) == nil)
    }
}

import CoreGraphics

/// Where the picture sits in the mirror view: aspect fit, centred (as the display layer's
/// `.resizeAspect` draws it), with bars on the sides or at the top and bottom.
public enum MirrorGeometry {
    /// View point (top-left origin) → video pixel; nil outside the picture, or clamped to its edge when `clamp`.
    public static func videoPoint(_ p: CGPoint, viewSize: CGSize, video: CGSize, clamp: Bool) -> (x: Int32, y: Int32)? {
        guard video.width >= 1, video.height >= 1, viewSize.width > 0, viewSize.height > 0,
              p.x.isFinite, p.y.isFinite else { return nil }
        let scale = min(viewSize.width / video.width, viewSize.height / video.height)
        let originX = (viewSize.width - video.width * scale) / 2
        let originY = (viewSize.height - video.height * scale) / 2
        let x = ((p.x - originX) / scale).rounded(.down)
        let y = ((p.y - originY) / scale).rounded(.down)
        let inside = x >= 0 && x < video.width && y >= 0 && y < video.height
        guard inside || clamp else { return nil }
        let maxX = video.width.rounded(.down) - 1, maxY = video.height.rounded(.down) - 1
        return (Int32(min(max(x, 0), maxX)), Int32(min(max(y, 0), maxY)))
    }

    /// `point` in a `from`-sized video, at the same place in a `to`-sized one (clamped to it).
    static func rescale(_ point: (x: Int32, y: Int32), from: CGSize, to: CGSize) -> (x: Int32, y: Int32) {
        guard from != to, from.width >= 1, from.height >= 1, to.width >= 1, to.height >= 1 else { return point }
        let x = (CGFloat(point.x) * to.width / from.width).rounded(.down)
        let y = (CGFloat(point.y) * to.height / from.height).rounded(.down)
        return (Int32(min(max(x, 0), to.width - 1)), Int32(min(max(y, 0), to.height - 1)))
    }
}

import CoreGraphics

/// Where the pointer may go: onto a real screen, never into the gap between screens.
public enum PointerMath {
    /// `p` when it is on any screen; else the nearest point of the nearest screen. Coordinates
    /// are CG global (top-left origin). A screen's last column and row are `maxX - 1` and
    /// `maxY - 1`, since its rect is half-open.
    public static func clamp(_ p: CGPoint, to screens: [CGRect]) -> CGPoint {
        guard !screens.isEmpty, !screens.contains(where: { $0.contains(p) }) else { return p }
        var best = p
        var bestDistance = CGFloat.infinity
        for r in screens where !r.isEmpty {
            let q = CGPoint(x: min(max(p.x, r.minX), r.maxX - 1), y: min(max(p.y, r.minY), r.maxY - 1))
            let d = (q.x - p.x) * (q.x - p.x) + (q.y - p.y) * (q.y - p.y)
            if d < bestDistance {
                best = q
                bestDistance = d
            }
        }
        return best
    }
}
